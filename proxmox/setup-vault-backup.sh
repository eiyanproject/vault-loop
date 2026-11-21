#!/usr/bin/env bash
# Nightly git backup of the Obsidian vault held by the Syncthing LXC (CT 107).
#
# Syncthing copies deletions and overwrites to every device, so it is not a
# backup. This commits the vault every night and pushes it to a private GitHub
# repo, using a deploy key that only that repo accepts.
#
# RUN THIS ON THE PROXMOX HOST that holds the Syncthing CT (eiyan2), as root.
#
#   bash proxmox/setup-vault-backup.sh --ctid 107 --vault /path/in/ct \
#        --remote git@github.com:<you>/<private-repo>.git              # plan only
#   ... --yes                                                          # apply
#
# Options:
#   --ctid N        the Syncthing container            (required)
#   --vault PATH    the vault folder INSIDE that CT    (required; must exist)
#   --remote URL    SSH remote of an EMPTY private repo (required)
#   --time HH:MM    when to run each day               (default 03:30)
#
# The git directory lives at /var/lib/vault-backup/vault.git, OUTSIDE the
# vault, so Syncthing never sees a .git folder and never syncs it to the phone.
#
# Re-running is safe: the key is kept, the remote and timer are rewritten.
# After --yes it prints a public key: add it to the repo as a deploy key WITH
# write access, then run the first backup with the command it prints.
set -euo pipefail

CTID=""; VAULT=""; REMOTE=""; AT="03:30"; CONFIRM="no"
GITDIR="/var/lib/vault-backup/vault.git"
KEY="/var/lib/vault-backup/id_ed25519"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ctid)   CTID="${2:-}"; shift 2 ;;
    --vault)  VAULT="${2:-}"; shift 2 ;;
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --time)   AT="${2:-}"; shift 2 ;;
    --yes)    CONFIRM="yes"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$CTID" ]   || die "--ctid is required (the Syncthing LXC, 107)"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "--ctid must be a number"
[ -n "$VAULT" ]  || die "--vault is required (the vault folder inside CT $CTID)"
[[ "$VAULT" == /* ]] || die "--vault must be an absolute path inside the container"
[[ "$VAULT" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--vault may only contain letters, digits, . _ - /"
[ -n "$REMOTE" ] || die "--remote is required, e.g. git@github.com:<you>/<private-repo>.git"
[[ "$REMOTE" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] ||
  die "--remote must be an SSH GitHub URL like git@github.com:<you>/<repo>.git (deploy keys only work over SSH)"
[[ "$AT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--time must be HH:MM"
command -v pct >/dev/null 2>&1 || die "pct not found - run this on the Proxmox host"

pct status "$CTID" 2>/dev/null | grep -q running || die "CT $CTID is not running (or not on this node)"
pct exec "$CTID" -- test -d /run/systemd/system || die "CT $CTID does not run systemd; this script installs a systemd timer"
pct exec "$CTID" -- test -d "$VAULT" || die "$VAULT does not exist inside CT $CTID. Add the vault folder in Syncthing first (docs/PHASE0.md step 3)."

OWNER="$(pct exec "$CTID" -- stat -c '%U' "$VAULT" 2>/dev/null || echo '?')"
FILES="$(pct exec "$CTID" -- sh -c "find '$VAULT' -type f -not -path '*/.stversions/*' | wc -l" 2>/dev/null || echo '?')"
HAVE_KEY="no"; pct exec "$CTID" -- test -f "$KEY" && HAVE_KEY="yes"

cat <<PLAN

  Plan
  ----
  container     $CTID
  vault         $VAULT  (owner $OWNER, $FILES files)
  git dir       $GITDIR  (outside the vault)
  remote        $REMOTE
  deploy key    $KEY  ($( [ "$HAVE_KEY" = yes ] && echo "exists, kept" || echo "generated now" ))
  schedule      daily at $AT, catch-up after downtime (Persistent=true)
  installs      git, openssh-client (apt) inside CT $CTID
  excluded      .stversions/ .stfolder .obsidian/workspace*.json .trash/

PLAN

if [ "$CONFIRM" != "yes" ]; then
  echo "  Dry run. Nothing was changed. Re-run with --yes to apply."
  exit 0
fi

echo "==> installing git inside CT $CTID"
pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y -qq git openssh-client"

echo "==> deploy key and git dir"
pct exec "$CTID" -- bash -s -- "$VAULT" "$REMOTE" "$GITDIR" "$KEY" <<'INNER'
set -euo pipefail
VAULT="$1"; REMOTE="$2"; GITDIR="$3"; KEY="$4"
install -d -m 0700 "$(dirname "$KEY")"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "vault-backup@$(hostname)" -f "$KEY"
if [ ! -d "$GITDIR" ]; then
  git init -q --bare "$GITDIR"
  git --git-dir="$GITDIR" config core.bare false
  git --git-dir="$GITDIR" symbolic-ref HEAD refs/heads/main
fi
git --git-dir="$GITDIR" config core.worktree "$VAULT"
git --git-dir="$GITDIR" config user.name "vault-backup"
git --git-dir="$GITDIR" config user.email "vault-backup@localhost"
git --git-dir="$GITDIR" remote remove origin 2>/dev/null || true
git --git-dir="$GITDIR" remote add origin "$REMOTE"
mkdir -p "$GITDIR/info"
cat > "$GITDIR/info/exclude" <<'EOX'
# managed by vault-loop setup-vault-backup.sh
.stversions/
.stfolder
.stfolder/
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.trash/
EOX
INNER

echo "==> backup command and timer"
pct exec "$CTID" -- bash -s -- "$GITDIR" "$KEY" "$AT" "$VAULT" <<'INNER'
set -euo pipefail
GITDIR="$1"; KEY="$2"; AT="$3"; VAULT="$4"
cat > /usr/local/bin/vault-backup <<EOB
#!/usr/bin/env bash
# managed by vault-loop setup-vault-backup.sh
set -euo pipefail
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(dirname "$KEY")/known_hosts"
# The vault is owned by the Syncthing user, git runs as root: allow this one tree.
g() { git -C "$VAULT" -c safe.directory='*' --git-dir="$GITDIR" "\$@"; }
g add -A
if g diff --cached --quiet; then
  echo '{"level":"info","msg":"vault unchanged","svc":"vault-backup"}'
else
  g commit -q -m "vault backup \$(date -u +%Y-%m-%dT%H:%MZ)"
  echo "{\"level\":\"info\",\"msg\":\"committed \$(g rev-parse --short HEAD)\",\"svc\":\"vault-backup\"}"
fi
g push -q origin HEAD:main
echo '{"level":"info","msg":"pushed","svc":"vault-backup"}'
EOB
chmod 0755 /usr/local/bin/vault-backup

cat > /etc/systemd/system/vault-backup.service <<'EOS'
# managed by vault-loop setup-vault-backup.sh
[Unit]
Description=Commit and push the Obsidian vault
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vault-backup
Nice=10
EOS

cat > /etc/systemd/system/vault-backup.timer <<EOT
# managed by vault-loop setup-vault-backup.sh
[Unit]
Description=Nightly vault backup

[Timer]
OnCalendar=*-*-* $AT:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOT

systemctl daemon-reload
systemctl enable --now vault-backup.timer >/dev/null
INNER

PUB="$(pct exec "$CTID" -- cat "${KEY}.pub")"
cat <<EOF

  Done. One step is yours, then one test run.

  1. GitHub -> the private repo -> Settings -> Deploy keys -> Add deploy key
     Title: vault-backup (CT $CTID)     Allow write access: ON
     Key:
       $PUB

  2. First backup (pushes the whole vault):
       pct exec $CTID -- systemctl start vault-backup.service
       pct exec $CTID -- journalctl -u vault-backup.service -n 20 --no-pager

  Next run: $(pct exec "$CTID" -- systemctl list-timers vault-backup.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3}')

EOF
