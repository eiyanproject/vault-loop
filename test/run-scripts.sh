#!/usr/bin/env bash
# Shell-script tests. Each runs in its own throwaway Debian container with the
# Proxmox tools stubbed, so nothing here can touch a real host.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(pwd -W 2>/dev/null || pwd)"   # Git Bash on Windows needs the C:/ form

rc=0
for t in shellcheck create-lxc update-lxc setup-vault-backup; do
  echo "################################ $t"
  MSYS_NO_PATHCONV=1 docker run --rm -v "$SRC:/src:ro" debian:13 bash -c "
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq shellcheck git openssh-client >/dev/null 2>&1
    bash /src/test/scripts/$t.test.sh
  " || rc=1
done
exit $rc
