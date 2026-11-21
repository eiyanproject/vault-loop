#!/bin/bash
# proxmox/setup-vault-backup.sh. pct exec is stubbed to run the command right
# here, so the real git, ssh-keygen and generated backup script are exercised.
# apt-get and systemctl are stubbed; nothing leaves this container.
set -u
mkdir -p /stub /out /run/systemd/system
export PATH=/stub:$PATH
cat > /stub/pct <<'EOF'
#!/bin/bash
echo "$*" >> /out/pct.calls
case "$1" in
  status) echo "status: running" ;;
  exec)   shift 2; [ "$1" = "--" ] && shift; exec "$@" ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > /stub/apt-get
cat > /stub/systemctl <<'EOF'
#!/bin/bash
echo "systemctl $*" >> /out/systemctl.calls
exit 0
EOF
chmod +x /stub/*

S=/src/proxmox/setup-vault-backup.sh
R=git@github.com:someone/vault.git

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
no() { echo "FAIL  $1"; fail=$((fail+1)); }
saw() { case "$2" in *"$3"*) ok "$1";; *) no "$1 -- expected '$3'"; echo "$2" | tail -8;; esac; }
run() { bash $S "$@" </dev/null 2>&1; }

# A vault owned by someone else, as on CT 107 (Syncthing's user), with the
# files that must never reach the backup.
useradd -m stuser 2>/dev/null
mkdir -p /srv/vault/Inbox /srv/vault/.stversions /srv/vault/.obsidian /srv/vault/.trash
echo "first note"  > /srv/vault/Inbox/a.md
echo "old version" > /srv/vault/.stversions/a~1.md
echo "{}"          > /srv/vault/.obsidian/workspace.json
echo "{}"          > /srv/vault/.obsidian/app.json
echo "gone"        > /srv/vault/.trash/x.md
chown -R stuser:stuser /srv/vault

out=$(run --vault /srv/vault --remote $R);                           saw "ctid required"         "$out" "--ctid is required"
out=$(run --ctid 107 --vault srv/vault --remote $R);                 saw "relative vault refused" "$out" "absolute path"
out=$(run --ctid 107 --vault /srv/vault --remote https://github.com/someone/vault.git); saw "https remote refused" "$out" "SSH GitHub URL"
out=$(run --ctid 107 --vault /srv/vault --remote $R --time 25:00);   saw "bad time refused"      "$out" "HH:MM"
out=$(run --ctid 107 --vault '/srv/va;rm' --remote $R);              saw "odd vault chars refused" "$out" "may only contain"
out=$(run --ctid 107 --vault /srv/nope --remote $R);                 saw "missing vault refused" "$out" "does not exist inside CT 107"

out=$(run --ctid 107 --vault /srv/vault --remote $R)
saw "dry run plan"           "$out" "daily at 03:30"
saw "dry run changes nothing" "$out" "Dry run. Nothing was changed"
[ ! -e /var/lib/vault-backup ] && ok "dry run created nothing" || no "dry run created /var/lib/vault-backup"

out=$(run --ctid 107 --vault /srv/vault --remote $R --time 04:15 --yes)
saw "prints the deploy key" "$out" "ssh-ed25519 "
[ -f /var/lib/vault-backup/id_ed25519 ] && ok "key generated" || no "no key"
[ ! -e /srv/vault/.git ] && ok "no .git inside the vault" || no ".git created inside the vault"
grep -q 'OnCalendar=\*-\*-\* 04:15:00' /etc/systemd/system/vault-backup.timer && ok "timer at --time" || no "timer time wrong"
grep -q 'enable --now vault-backup.timer' /out/systemctl.calls && ok "timer enabled" || no "timer not enabled"
shellcheck -S warning /usr/local/bin/vault-backup && ok "generated vault-backup passes shellcheck" || no "generated script fails shellcheck"

# Point origin at a local bare repo and run a real backup.
git init -q --bare /tmp/remote.git
git --git-dir=/var/lib/vault-backup/vault.git remote set-url origin /tmp/remote.git
if out=$(/usr/local/bin/vault-backup 2>&1); then ok "first backup runs"; else no "first backup failed"; echo "$out"; fi
files=$(git --git-dir=/tmp/remote.git ls-tree -r --name-only main 2>/dev/null)
saw "note is backed up"      "$files" "Inbox/a.md"
saw "obsidian config kept"   "$files" ".obsidian/app.json"
case "$files" in *.stversions*) no ".stversions leaked into the backup";; *) ok ".stversions excluded";; esac
case "$files" in *workspace.json*) no "workspace.json leaked";; *) ok "workspace.json excluded";; esac
case "$files" in *.trash*) no ".trash leaked";; *) ok ".trash excluded";; esac

out=$(/usr/local/bin/vault-backup 2>&1); saw "unchanged vault makes no commit" "$out" "vault unchanged"
n1=$(git --git-dir=/tmp/remote.git rev-list --count main)
echo "second note" > /srv/vault/Inbox/b.md; chown stuser /srv/vault/Inbox/b.md
/usr/local/bin/vault-backup >/dev/null 2>&1
n2=$(git --git-dir=/tmp/remote.git rev-list --count main)
[ "$n2" -eq $((n1 + 1)) ] && ok "a change makes one new commit" || no "commit count $n1 -> $n2"

# Re-run keeps the key.
k1=$(cat /var/lib/vault-backup/id_ed25519.pub)
run --ctid 107 --vault /srv/vault --remote $R --yes >/dev/null
k2=$(cat /var/lib/vault-backup/id_ed25519.pub)
[ "$k1" = "$k2" ] && ok "re-run keeps the deploy key" || no "re-run replaced the key"

echo "setup-vault-backup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
