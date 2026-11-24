#!/bin/bash
# proxmox/create-lxc.sh against stubbed pct/pvesm/pveam/pvesh/dpkg/ip/ping/hostname.
set -u
mkdir -p /stub /out/conf
export PATH=/stub:$PATH
export PVE_CONF_DIR=/out/conf

cat > /stub/pvesm <<'EOF'
#!/bin/bash
echo "Name             Type     Status           Total            Used       Available        %"
echo "local-lvm        lvmthin  active        10000000         500000         9500000    5.00%"
EOF
cat > /stub/pvesh <<'EOF'
#!/bin/bash
echo 108
EOF
cat > /stub/pveam <<'EOF'
#!/bin/bash
case "$1" in
  available)
    echo "system           debian-13-standard_13.6-1_arm64.tar.zst"
    echo "system           debian-13-standard_13.6-1_amd64.tar.zst"
    echo "system           debian-12-standard_12.7-1_amd64.tar.zst" ;;
esac
exit 0
EOF
cat > /stub/pct <<'EOF'
#!/bin/bash
echo "$*" >> /out/pct.calls
case "$1" in
  status) [ "${STUB_EXISTS:-0}" = "1" ] && exit 0; exit 1 ;;
  create) printf '%s\n' "$@" > /out/create.args ;;
  exec)   case "$*" in *hostname*) echo 192.168.0.40 ;; esac ;;
esac
exit 0
EOF
cat > /stub/hostname <<'EOF'
#!/bin/bash
echo "${STUB_NODE:-eiyan2}"
EOF
printf '#!/bin/bash\necho amd64\n' > /stub/dpkg
printf '#!/bin/bash\necho "default via 192.168.0.1 dev vmbr0"\n' > /stub/ip
printf '#!/bin/bash\nexit 1\n' > /stub/ping
chmod +x /stub/*

# A copy of the repo layout, so the script finds ../install/<role>.sh.
mkdir -p /work && cp -r /src/proxmox /src/install /work/
S=/work/proxmox/create-lxc.sh

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
no() { echo "FAIL  $1"; fail=$((fail+1)); }
saw()    { case "$2" in *"$3"*) ok "$1";; *) no "$1 -- expected '$3'"; echo "$2" | tail -5;; esac; }
hasarg() { if grep -qx -- "$2" /out/create.args 2>/dev/null; then ok "$1"; else no "$1 -- '$2' not in create args"; fi; }
run() { rm -f /out/create.args /out/pct.calls; bash $S "$@" </dev/null 2>&1; }

out=$(run);                     saw "no role is refused"        "$out" "--role is required"
out=$(run --role web);          saw "unknown role is refused"   "$out" "must be loop"
out=$(run --role plane);        saw "plane role points to docs" "$out" "docs/PLANE.md"

out=$(CT_IP=192.168.0.40/24 CT_GW=192.168.0.1 run --role loop)
saw "loop dry run shows 1 GB" "$out" "2 vCPU / 1024 MB RAM / 512 MB swap / 16 GB"
saw "loop dry run changes nothing" "$out" "Dry run. Nothing was changed"
[ ! -f /out/create.args ] && ok "dry run does not call pct create" || no "dry run called pct create"
saw "picks the amd64 debian 13 template" "$out" "debian-13-standard_13.6-1_amd64"

out=$(STUB_EXISTS=1 run --role loop);          saw "existing CTID refused"     "$out" "already exists"
out=$(STUB_NODE=eiyan run --role loop);        saw "wrong node warns"          "$out" "this is node 'eiyan', not 'eiyan2'"
out=$(INSTALLER=/nope run --role loop);        saw "missing installer refused" "$out" "installer not found"
out=$(CT_IP=192.168.0.40 run --role loop);     saw "IP without prefix refused" "$out" "must include a prefix"

: > /out/key.pub
out=$(CT_IP=192.168.0.40/24 CT_GW=192.168.0.1 CT_SSHKEY=/out/key.pub run --role loop --yes)
hasarg "creates with 1024 MB"         "1024"
hasarg "hostname vault-loop"          "vault-loop"
hasarg "nesting and keyctl"           "nesting=1,keyctl=1"
hasarg "static network"               "name=eth0,bridge=vmbr0,ip=192.168.0.40/24,gw=192.168.0.1"
if grep -q "push 108 /work/proxmox/../install/loop.sh /root/vault-loop-install.sh" /out/pct.calls; then ok "pushes install/loop.sh"; else no "did not push install/loop.sh"; fi
if grep -q "exec 108 -- bash /root/vault-loop-install.sh" /out/pct.calls; then ok "runs the installer"; else no "did not run the installer"; fi

echo "create-lxc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
