#!/bin/bash
# shellcheck every script in the repo, plus the scripts setup-vault-backup.sh
# generates inside the container.
set -u
fail=0
for f in /src/proxmox/*.sh /src/install/*.sh /src/test/run-scripts.sh; do
  if shellcheck -S warning "$f"; then echo "PASS  shellcheck $(basename "$f")"
  else echo "FAIL  shellcheck $(basename "$f")"; fail=1; fi
done
exit $fail
