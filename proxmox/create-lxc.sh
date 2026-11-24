#!/usr/bin/env bash
#
# Create the vault-loop LXC and install its service inside it.
#
#   --role loop    CT "vault-loop": Docker + n8n       2 vCPU / 1 GB / 512 MB swap / 16 GB
#
# Plane is not created here: it runs in its own CT from the Proxmox VE
# community script. docs/PLANE.md covers pointing its webhooks at n8n.
#
# RUN THIS ON THE PROXMOX HOST, as root, on eiyan2 (the memory node) -- from a
# checkout of this repo, because the installer is pushed in from ../install/.
#
#   bash proxmox/create-lxc.sh --role loop                 # asks, shows the plan, asks again
#   CT_IP=192.168.0.40/24 CT_GW=192.168.0.1 bash proxmox/create-lxc.sh --role loop --yes
#
# Without a terminal and without --yes it prints the plan and stops.
#
# Overrides (all optional):
#   CTID           container ID            (default: next free)
#   CT_HOSTNAME    hostname                (default: vault-loop)
#   CT_CORES CT_RAM CT_SWAP CT_DISK        (defaults per role, above)
#   CT_BRIDGE      network bridge          (default: vmbr0)
#   CT_SSHKEY      path to a public key    (default: none, password prompt)
#   ROOT_STORE     rootfs storage          (default: first active rootdir store)
#   TEMPLATE_STORE template storage        (default: first active vztmpl store)
#   EXPECT_NODE    node this should run on (default: eiyan2; warns otherwise)
#   RUN_INSTALLER  install the service too (default: 1)

set -euo pipefail

ROLE=""
CONFIRM="no"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m fail\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --yes)  CONFIRM="yes"; shift ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (settings are environment variables; see --help)" ;;
  esac
done

case "$ROLE" in
  loop)
    D_HOSTNAME=vault-loop; D_CORES=2; D_RAM=1024; D_SWAP=512;  D_DISK=16
    DESC="vault-loop - n8n control panel for the vault-to-PR loop" ;;
  plane) die "Plane is not installed by this repo: it runs from the Proxmox VE community script. See docs/PLANE.md" ;;
  "") die "--role is required: loop" ;;
  *)  die "--role must be loop, got: $ROLE" ;;
esac

CT_HOSTNAME="${CT_HOSTNAME:-$D_HOSTNAME}"
CT_CORES="${CT_CORES:-$D_CORES}"
CT_RAM="${CT_RAM:-$D_RAM}"
CT_SWAP="${CT_SWAP:-$D_SWAP}"
CT_DISK="${CT_DISK:-$D_DISK}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-}"
CT_GW="${CT_GW:-}"
CT_SSHKEY="${CT_SSHKEY:-}"
EXPECT_NODE="${EXPECT_NODE:-eiyan2}"
RUN_INSTALLER="${RUN_INSTALLER:-1}"

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="${INSTALLER:-$HERE/../install/${ROLE}.sh}"

valid_ipv4() {
  case "$1" in
    *[!0-9.]*|"") return 1 ;;
  esac
  local o count=0
  local IFS=.
  for o in $1; do
    count=$((count + 1))
    case "$o" in ""|*[!0-9]*) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
  done
  [ "$count" -eq 4 ]
}

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
command -v pct   >/dev/null 2>&1 || die "pct not found -- run this on the Proxmox HOST, not inside a container"
command -v pvesm >/dev/null 2>&1 || die "pvesm not found -- is this really a Proxmox host?"
if [ "$RUN_INSTALLER" = "1" ]; then
  [ -f "$INSTALLER" ] || die "installer not found at $INSTALLER -- run this from a checkout of the vault-loop repo"
fi

NODE="$(hostname -s 2>/dev/null || hostname)"
if [ "$NODE" != "$EXPECT_NODE" ]; then
  warn "this is node '$NODE', not '$EXPECT_NODE'. pct creates the container on the node you run it on."
  warn "eiyan2 is the memory node; that is where these belong. Set EXPECT_NODE=$NODE to silence this."
fi

# --- Storage ----------------------------------------------------------------
# Column layout of `pvesm status` is: Name Type Status Total Used Available %
ROOT_STORE="${ROOT_STORE:-$(pvesm status --content rootdir | awk 'NR>1 && $3=="active" {print $1; exit}')}"
TEMPLATE_STORE="${TEMPLATE_STORE:-$(pvesm status --content vztmpl | awk 'NR>1 && $3=="active" {print $1; exit}')}"
[ -n "$ROOT_STORE" ]     || die "no active storage with 'rootdir' content -- set ROOT_STORE=..."
[ -n "$TEMPLATE_STORE" ] || die "no active storage with 'vztmpl' content -- set TEMPLATE_STORE=..."
say "rootfs storage:   $ROOT_STORE"
say "template storage: $TEMPLATE_STORE"

HOST_DEB_ARCH="${HOST_DEB_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
[ -n "$HOST_DEB_ARCH" ] || HOST_DEB_ARCH=amd64
say "host architecture: $HOST_DEB_ARCH"

# --- Container ID -----------------------------------------------------------
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
if pct status "$CTID" >/dev/null 2>&1; then
  die "CTID $CTID already exists -- pass CTID=<free id>"
fi
say "container ID: $CTID"

# --- Template ---------------------------------------------------------------
say "Refreshing template list..."
pveam update >/dev/null

# MUST filter by architecture: `pveam available` lists every arch, and "amd64"
# sorts before "arm64", so an unfiltered `sort -V | tail -1` picks arm64 on an
# amd64 host and the container then fails to start. (Same as vnc-gateway.)
pick_template() {
  pveam available --section system \
    | awk '{print $2}' \
    | grep -E "^${1}_.*_${2}\.tar\." \
    | sort -V \
    | tail -1
}

TEMPLATE_NAME=""
for series in debian-13-standard debian-12-standard; do
  TEMPLATE_NAME="$(pick_template "$series" "$HOST_DEB_ARCH" || true)"
  [ -n "$TEMPLATE_NAME" ] && break
done
[ -n "$TEMPLATE_NAME" ] || die "could not find a Debian 12/13 ${HOST_DEB_ARCH} template in 'pveam available'"
case "$TEMPLATE_NAME" in
  *_${HOST_DEB_ARCH}.tar.*) ;;
  *) die "template '$TEMPLATE_NAME' does not match host architecture ${HOST_DEB_ARCH}" ;;
esac
say "Template: $TEMPLATE_NAME"
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_NAME}"

# --- Network ----------------------------------------------------------------
HOST_GW="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}' || true)"

if [ -z "$CT_IP" ] && [ -t 0 ]; then
  echo
  echo "  Address for CT $CT_HOSTNAME. Static is recommended: the PC worker,"
  echo "  Plane's webhook and the monitoring target all point at it."
  while :; do
    printf '  IP address (e.g. 192.168.0.40), or "dhcp": '
    read -r ans || die "no input (end of file) - aborted"
    [ "$ans" = "dhcp" ] && { CT_IP=dhcp; break; }
    case "$ans" in
      */*) ipaddr="${ans%%/*}"; prefix="${ans##*/}" ;;
      *)   ipaddr="$ans"; prefix="24" ;;
    esac
    if valid_ipv4 "$ipaddr"; then
      if ping -c1 -W1 "$ipaddr" >/dev/null 2>&1; then
        warn "$ipaddr already answers ping -- pick another."
        continue
      fi
      printf '  Gateway [%s]: ' "${HOST_GW:-192.168.0.1}"
      read -r gw || gw=""
      gw="${gw:-${HOST_GW:-192.168.0.1}}"
      valid_ipv4 "$gw" || { warn "Not a valid IPv4 address: '$gw'"; continue; }
      CT_IP="${ipaddr}/${prefix}"; CT_GW="$gw"
      break
    fi
    warn "Not a valid IPv4 address: '$ans'"
  done
  echo
fi

CT_IP="${CT_IP:-dhcp}"
if [ "$CT_IP" = "dhcp" ]; then
  warn "Using DHCP. Reserve the address on your router: three other things point at it."
  NET0="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
else
  case "$CT_IP" in
    */*) ;;
    *) die "CT_IP must include a prefix length, e.g. 192.168.0.40/24" ;;
  esac
  [ -n "$CT_GW" ] || die "CT_GW is required when CT_IP is static, e.g. CT_GW=192.168.0.1"
  valid_ipv4 "${CT_IP%%/*}" || die "CT_IP is not a valid IPv4 address: ${CT_IP%%/*}"
  valid_ipv4 "$CT_GW"       || die "CT_GW is not a valid IPv4 address: $CT_GW"
  NET0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW}"
fi

# --- Credentials ------------------------------------------------------------
if [ -n "$CT_SSHKEY" ]; then
  [ -f "$CT_SSHKEY" ] || die "CT_SSHKEY does not exist: $CT_SSHKEY"
  PCT_AUTH=(--ssh-public-keys "$CT_SSHKEY")
else
  PCT_AUTH=(--password)
fi

# --- Plan -------------------------------------------------------------------
if [ "$RUN_INSTALLER" = "1" ]; then
  THEN="push install/${ROLE}.sh and run it (Docker + n8n)"
else
  THEN="nothing (RUN_INSTALLER=0)"
fi

cat <<PLAN

  Plan
  ----
  node          $NODE
  container     $CTID  ($CT_HOSTNAME), unprivileged, nesting=1,keyctl=1, start on boot
  template      $TEMPLATE_REF
  specs         ${CT_CORES} vCPU / ${CT_RAM} MB RAM / ${CT_SWAP} MB swap / ${CT_DISK} GB on ${ROOT_STORE}
  network       ${NET0}
  login         $( [ -n "$CT_SSHKEY" ] && echo "SSH key $CT_SSHKEY" || echo "root password (pct will ask)" )
  then          $THEN

PLAN

if [ "$CONFIRM" != "yes" ]; then
  if [ -t 0 ]; then
    printf '  Create it? [y/N] '
    read -r go || go=""
    case "$go" in
      [yY]*) ;;
      *) echo "  Nothing was changed."; exit 0 ;;
    esac
  else
    echo "  Dry run. Nothing was changed. Re-run with --yes to apply."
    exit 0
  fi
fi

# --- Create -----------------------------------------------------------------
if pveam list "$TEMPLATE_STORE" | grep -q "$TEMPLATE_NAME"; then
  say "Template already downloaded."
else
  say "Downloading template: $TEMPLATE_NAME"
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_NAME"
fi

say "Creating container $CTID..."
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --swap "$CT_SWAP" \
  --rootfs "${ROOT_STORE}:${CT_DISK}" \
  --net0 "$NET0" \
  --ostype debian \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --description "$DESC" \
  "${PCT_AUTH[@]}"

# Proxmox ARM kernels often lack AppArmor; LXC then fails to start with a
# useless "sync_wait" error. Only relax the profile where there is no AppArmor
# to relax. (Same reasoning as vnc-gateway's create-lxc.sh.)
APPARMOR_ENABLED_FILE="${APPARMOR_ENABLED_FILE:-/sys/module/apparmor/parameters/enabled}"
PVE_CONF_DIR="${PVE_CONF_DIR:-/etc/pve/lxc}"
if ! { [ -r "$APPARMOR_ENABLED_FILE" ] && grep -qi '^y' "$APPARMOR_ENABLED_FILE" 2>/dev/null; }; then
  warn "No usable AppArmor on this kernel; setting 'lxc.apparmor.profile: unconfined'."
  echo "lxc.apparmor.profile: unconfined" >> "${PVE_CONF_DIR}/${CTID}.conf" 2>/dev/null ||
    warn "could not write ${PVE_CONF_DIR}/${CTID}.conf -- add that line by hand if the start fails"
fi

say "Starting..."
if ! pct start "$CTID"; then
  warn "Get the real error with: lxc-start -n $CTID -F -l DEBUG -o /tmp/lxc-$CTID.log"
  warn "Remove the container with: pct destroy $CTID"
  die "container $CTID could not be started"
fi

say "Waiting for network inside the container..."
ready=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ "$ready" = "1" ] || warn "Container has no DNS yet; the installer step may fail."

CT_ADDR="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

if [ "$RUN_INSTALLER" = "1" ] && [ "$ready" = "1" ]; then
  say "Installing inside the container (pulls Docker and images; give it a few minutes)..."
  pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates openssl"
  pct push "$CTID" "$INSTALLER" /root/vault-loop-install.sh --perms 0700
  pct exec "$CTID" -- bash /root/vault-loop-install.sh
else
  say "Skipping the installer (RUN_INSTALLER=$RUN_INSTALLER, network ready=$ready)."
  say "Run it later with: bash proxmox/update-lxc.sh --ctid $CTID --role $ROLE --yes"
fi

cat <<EOF

  Container    $CTID  ($CT_HOSTNAME) on $NODE
  Address      ${CT_ADDR:-<check: pct exec $CTID -- hostname -I>}
  Shell        pct enter $CTID
  Update       bash proxmox/update-lxc.sh --ctid $CTID --role $ROLE --snapshot --yes

  Next steps are in docs/PHASE0.md.

EOF
