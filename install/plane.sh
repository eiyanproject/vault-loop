#!/usr/bin/env bash
#
# CT plane installer: Docker + Plane Community. Runs INSIDE the container; from
# the Proxmox host use proxmox/create-lxc.sh or proxmox/update-lxc.sh.
#
# Uses Plane's own release files (docker-compose.yml + variables.env) for one
# pinned release, checked against the sha256 recorded below, instead of the
# interactive setup.sh. Re-running this IS the update path: it never overwrites
# a secret already in plane.env; it only rewrites APP_RELEASE to the pin and,
# when LOOP_IP is given, the webhook allowlist.
#
# To upgrade: set PLANE_VERSION_PIN to an exact release at least two weeks old,
# download its two files, put their sha256 below, and re-run with --snapshot
# from update-lxc.sh. Read Plane's release notes first: some releases need a
# manual migration step.
#
# Environment:
#   LOOP_IP     n8n's address; allowlisted as a webhook target (Plane blocks
#               webhooks to private addresses otherwise)
#   PLANE_DIR   install location (default /opt/plane)

set -euo pipefail

PLANE_VERSION_PIN="v1.4.3"
COMPOSE_SHA256="ee03069de6a5fffab1f276ecf27f2294904b62ccb33376db80400a843858d342"
VARIABLES_SHA256="64db1740913f288d6c6af9f4824c020cde139591ac7dd555b02836dca86a1e06"
RELEASE_URL="https://github.com/makeplane/plane/releases/download/${PLANE_VERSION_PIN}"
DIR="${PLANE_DIR:-/opt/plane}"
LOOP_IP="${LOOP_IP:-}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m fail\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
if [ -n "$LOOP_IP" ]; then
  [[ "$LOOP_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "LOOP_IP must be an IPv4 address"
fi

# --- 1. Docker ---------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  say "Installing Docker from the official repository..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl openssl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
else
  say "Docker already present: $(docker --version)"
fi
docker info >/dev/null 2>&1 || die "Docker is installed but not working. In an LXC this is almost always missing features: on the host, pct set <CTID> --features nesting=1,keyctl=1 && pct reboot <CTID>"

# --- 2. Release files, verified ------------------------------------------------
mkdir -p "$DIR"
cd "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {  # fetch <name> <sha256>
  curl -fsSL -m 60 -o "$TMP/$1" "$RELEASE_URL/$1" || die "could not download $RELEASE_URL/$1"
  local got
  got="$(sha256sum "$TMP/$1" | awk '{print $1}')"
  [ "$got" = "$2" ] || die "$1 for $PLANE_VERSION_PIN has sha256 $got, expected $2. Not installing a file that changed under the same tag."
}
say "Downloading Plane ${PLANE_VERSION_PIN} release files..."
fetch docker-compose.yml "$COMPOSE_SHA256"
fetch variables.env      "$VARIABLES_SHA256"
install -m 0644 "$TMP/docker-compose.yml" docker-compose.yml
install -m 0644 "$TMP/variables.env"      variables.env.upstream

# --- 3. plane.env ------------------------------------------------------------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || die "could not determine this container's IP address"

get_kv() { grep -E "^$1=" plane.env | tail -1 | cut -d= -f2- || true; }
set_kv() {
  if grep -qE "^$1=" plane.env; then
    sed -i "s|^$1=.*|$1=$2|" plane.env
  else
    printf '%s=%s\n' "$1" "$2" >> plane.env
  fi
}

if [ ! -f plane.env ]; then
  say "First install: writing plane.env with generated secrets."
  ( umask 077; cp variables.env.upstream plane.env )
  PG_PASS="$(openssl rand -hex 24)"
  MQ_PASS="$(openssl rand -hex 24)"
  S3_KEY="$(openssl rand -hex 12)"
  S3_SECRET="$(openssl rand -hex 24)"
  set_kv APP_DOMAIN "$IP"
  set_kv WEB_URL "http://$IP"
  set_kv CORS_ALLOWED_ORIGINS "http://$IP"
  set_kv SECRET_KEY "$(openssl rand -hex 32)"
  set_kv LIVE_SERVER_SECRET_KEY "$(openssl rand -hex 32)"
  set_kv POSTGRES_PASSWORD "$PG_PASS"
  # The compose file's DATABASE_URL / AMQP_URL defaults hardcode the default
  # passwords, so changing a password means spelling the URL out.
  set_kv DATABASE_URL "postgresql://plane:${PG_PASS}@plane-db/plane"
  set_kv RABBITMQ_PASSWORD "$MQ_PASS"
  set_kv AMQP_URL "amqp://plane:${MQ_PASS}@plane-mq:5672/plane"
  set_kv AWS_ACCESS_KEY_ID "$S3_KEY"
  set_kv AWS_SECRET_ACCESS_KEY "$S3_SECRET"
fi
chmod 600 plane.env

set_kv APP_RELEASE "$PLANE_VERSION_PIN"
if [ -n "$LOOP_IP" ]; then
  set_kv WEBHOOK_ALLOWED_IPS "${LOOP_IP}/32"
fi

# Refuse to run with the upstream placeholder secrets, e.g. after someone
# copied variables.env over plane.env by hand.
for k in SECRET_KEY LIVE_SERVER_SECRET_KEY; do
  [ "$(get_kv "$k")" != "change-this-key-on-deployment" ] || die "$k in $DIR/plane.env is still the upstream placeholder"
done
[ "$(get_kv POSTGRES_PASSWORD)" != "plane" ] || die "POSTGRES_PASSWORD in $DIR/plane.env is still the default"

# --- 4. Start ----------------------------------------------------------------
COMPOSE=(docker compose -p plane --env-file plane.env -f docker-compose.yml)
say "Pulling images (Plane is large; this takes a while on first install)..."
"${COMPOSE[@]}" pull -q
"${COMPOSE[@]}" up -d --remove-orphans

say "Waiting for Plane on :80 (first start runs database migrations)..."
ok=0
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ || true)"
  case "$code" in 200|30[1278]) ok=1; break ;; esac
  sleep 5
done
[ "$ok" = "1" ] || die "Plane did not answer on :80 within 5 minutes. Check: cd $DIR && ${COMPOSE[*]} ps"

cat <<EOF

  Plane ${PLANE_VERSION_PIN} is running.

  1. http://${IP}/god-mode/   create the instance admin (first visit only)
  2. http://${IP}/            create your workspace
  Webhooks     $( [ -n "$(get_kv WEBHOOK_ALLOWED_IPS)" ] && echo "may target $(get_kv WEBHOOK_ALLOWED_IPS)" || echo "none allowlisted yet -- re-run with LOOP_IP=<n8n ip>" )
  Config       $DIR/plane.env   (secrets; never paste it anywhere)
  Status       cd $DIR && ${COMPOSE[*]} ps

EOF
