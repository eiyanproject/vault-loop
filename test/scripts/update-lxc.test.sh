#!/bin/bash
# proxmox/update-lxc.sh against a stubbed pct.
set -u
mkdir -p /stub /out
export PATH=/stub:$PATH
cat > /stub/pct <<'EOF'
#!/bin/bash
echo "$*" >> /out/pct.calls
case "$1" in
  status) echo "status: ${STUB_STATUS:-running}" ;;
  config) echo "hostname: ${STUB_NAME:-vault-loop}" ;;
esac
exit 0
EOF
chmod +x /stub/pct
mkdir -p /work && cp -r /src/proxmox /src/install /work/
S=/work/proxmox/update-lxc.sh

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
no() { echo "FAIL  $1"; fail=$((fail+1)); }
saw() { case "$2" in *"$3"*) ok "$1";; *) no "$1 -- expected '$3'"; echo "$2" | tail -5;; esac; }
run() { rm -f /out/pct.calls; bash $S "$@" </dev/null 2>&1; }

out=$(run --role loop);                         saw "ctid required"           "$out" "--ctid is required"
out=$(run --ctid 108 --role web);               saw "bad role refused"        "$out" "must be loop"
out=$(run --ctid 117 --role plane);             saw "plane role points to docs" "$out" "docs/PLANE.md"
out=$(run --ctid 108 --role loop)
saw "dry run shows the n8n pin" "$out" "pins 2.46.6"
saw "dry run changes nothing"   "$out" "Dry run. Nothing was changed"
grep -q '^push' /out/pct.calls && no "dry run pushed the installer" || ok "dry run does not push"
out=$(STUB_NAME=plane run --ctid 108 --role loop);       saw "role/name mismatch refused" "$out" "does not look like role 'loop'"
out=$(STUB_STATUS=stopped run --ctid 108 --role loop);   saw "stopped CT refused"         "$out" "is not running"
out=$(run --ctid 108 --role loop --loop-ip 1.2.3.4);     saw "--loop-ip is gone"          "$out" "unknown argument: --loop-ip"

out=$(run --ctid 108 --role loop --snapshot --yes)
grep -q '^snapshot 108 pre-update-' /out/pct.calls && ok "takes a snapshot" || no "no snapshot"
grep -q '^push 108 .*/install/loop.sh /root/vault-loop-install.sh' /out/pct.calls && ok "pushes the installer" || no "did not push"
saw "prints rollback" "$out" "pct rollback 108 pre-update-"
grep -q '^exec 108 -- bash /root/vault-loop-install.sh' /out/pct.calls && ok "runs the installer" || no "did not run the installer"

echo "update-lxc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
