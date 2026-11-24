#!/usr/bin/env bash
# Re-runs a vault-loop installer inside its container: optional snapshot first.
# The installers are idempotent and are the update path -- bump the version pin
# in install/<role>.sh, then run this.
#
# RUN THIS ON THE PROXMOX HOST, on the node that hosts the container, from a
# checkout of this repo.
#
#   bash proxmox/update-lxc.sh --ctid 108 --role loop                     # plan only
#   bash proxmox/update-lxc.sh --ctid 108 --role loop --snapshot --yes    # rollback point, then update
#
# Plane is updated by its own community script, not here (docs/PLANE.md).
# Nothing is changed until you pass --yes.
set -euo pipefail

CTID=""; ROLE=""; SNAPSHOT="no"; CONFIRM="no"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ctid)     CTID="${2:-}"; shift 2 ;;
    --role)     ROLE="${2:-}"; shift 2 ;;
    --snapshot) SNAPSHOT="yes"; shift ;;
    --yes)      CONFIRM="yes"; shift ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$CTID" ] || die "--ctid is required"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "--ctid must be a number"
case "$ROLE" in
  loop) ;;
  plane) die "Plane is updated by its community script, not by this repo. See docs/PLANE.md" ;;
  *) die "--role must be loop" ;;
esac
command -v pct >/dev/null 2>&1 || die "pct not found - run this on the Proxmox host"

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="${INSTALLER:-$HERE/../install/${ROLE}.sh}"
[ -f "$INSTALLER" ] || die "installer not found at $INSTALLER"

pct status "$CTID" 2>/dev/null | grep -q running || die "CT $CTID is not running (or not on this node)"

# Guard against running the n8n installer in some other container.
CT_NAME="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}')"
case "$ROLE:$CT_NAME" in
  loop:vault-loop) ;;
  *) [ -n "${FORCE_ROLE:-}" ] || die "CT $CTID is named '$CT_NAME', which does not look like role '$ROLE'. Set FORCE_ROLE=1 if it really is." ;;
esac

PIN="$(grep -E '^N8N_VERSION_PIN=' "$INSTALLER" | head -1 | cut -d= -f2 | tr -d '"')"
SNAPNAME="pre-update-$(date +%Y%m%d-%H%M%S)"

cat <<PLAN

  Plan
  ----
  container     $CTID ($CT_NAME)
  installer     install/${ROLE}.sh  (pins ${PIN:-?})
  snapshot      $( [ "$SNAPSHOT" = yes ] && echo "$SNAPNAME" || echo "none (pass --snapshot for a rollback point)" )

PLAN

if [ "$CONFIRM" != "yes" ]; then
  echo "  Dry run. Nothing was changed. Re-run with --yes to apply."
  exit 0
fi

if [ "$SNAPSHOT" = yes ]; then
  echo "==> snapshot $SNAPNAME"
  pct snapshot "$CTID" "$SNAPNAME" --description "before vault-loop ${ROLE} update (${PIN:-?})"
fi

echo "==> running install/${ROLE}.sh inside CT $CTID"
pct push "$CTID" "$INSTALLER" /root/vault-loop-install.sh --perms 0700
pct exec "$CTID" -- bash /root/vault-loop-install.sh

if [ "$SNAPSHOT" = yes ]; then
  echo
  echo "  Roll back:        pct rollback $CTID $SNAPNAME"
  echo "  Delete when happy: pct delsnapshot $CTID $SNAPNAME"
  echo "  (snapshots older than 14 days raise a monitoring alert)"
fi
