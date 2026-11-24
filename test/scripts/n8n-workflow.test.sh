#!/bin/bash
# Runs inside test/run-n8n.sh's Debian container, next to a fresh n8n.
# Sets up a test owner and API key, runs n8n/setup-n8n.sh, then drives the
# workflow's webhooks and checks the loop_jobs table.
set -u
U="$N8N_HOST_URL"
pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
no() { echo "FAIL  $1"; fail=$((fail+1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 -- expected '$3', got '$2'"; fi; }

for _ in $(seq 1 90); do curl -fsS -m 3 "$U/healthz/readiness" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS -m 3 "$U/healthz/readiness" >/dev/null || { echo "FAIL  n8n never became ready"; exit 1; }

# Test-only owner and API key, generated per run and never printed.
PW="T$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')a1"
curl -fsS -m 30 -c /tmp/cj -X POST "$U/rest/owner/setup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"owner@test.localhost\",\"firstName\":\"Test\",\"lastName\":\"Owner\",\"password\":\"$PW\"}" >/dev/null \
  || { echo "FAIL  owner setup"; exit 1; }
SCOPES="$(curl -fsS -m 30 -b /tmp/cj "$U/rest/api-keys/scopes" | jq -c '.data')"
export N8N_API_KEY
N8N_API_KEY="$(curl -fsS -m 30 -b /tmp/cj -X POST "$U/rest/api-keys" -H 'Content-Type: application/json' \
  -d "{\"label\":\"test\",\"scopes\":$SCOPES,\"expiresAt\":null}" | jq -r '.data.rawApiKey')"
[ -n "$N8N_API_KEY" ] && [ "$N8N_API_KEY" != null ] && ok "test API key created" || { no "test API key"; exit 1; }

S=/src/n8n/setup-n8n.sh
cd /tmp || exit 1
export SYNCTHING_API_KEY="test-syncthing-key" SYNCTHING_URL="http://syncthing.invalid:8384" SYNCTHING_FOLDER="vault"

out=$(bash $S 2>&1);                          case "$out" in *"--url is required"*) ok "url required";; *) no "url required";; esac
out=$(N8N_API_KEY=wrong bash $S --url "$U" 2>&1); case "$out" in *"not reachable"*|*"API key is wrong"*) ok "bad API key refused";; *) no "bad API key: $out";; esac
out=$(bash $S --url "$U" 2>&1)
case "$out" in *"Dry run. Nothing was changed"*) ok "dry run";; *) no "dry run: $out";; esac
eq "dry run created no table" "$(curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$U/api/v1/data-tables" | jq '.data|length')" "0"

out=$(bash $S --url "$U" --yes 2>&1); echo "$out" | sed 's/^/      /'
case "$out" in *"==> activated"*) ok "setup applies and activates";; *) no "setup --yes failed"; echo "$out"; exit 1;; esac
[ "$(stat -c %a /tmp/worker-token)" = 600 ] && ok "worker token file is mode 600" || no "token file mode"
case "$out" in *"$(cat /tmp/worker-token)"*) no "setup printed the worker token";; *) ok "worker token not printed";; esac
case "$out" in *"test-syncthing-key"*) no "setup printed the Syncthing key";; *) ok "Syncthing key not printed";; esac

out=$(bash $S --url "$U" --yes 2>&1)
case "$out" in *"updated workflow"*) ok "re-run updates in place";; *) no "re-run: $out";; esac
eq "still one workflow" "$(curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$U/api/v1/workflows" | jq '[.data[]|select(.name=="vault-loop")]|length')" "1"
eq "still one table" "$(curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$U/api/v1/data-tables" | jq '.data|length')" "1"
WF="$(curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$U/api/v1/workflows" | jq -r '.data[]|select(.name=="vault-loop")')"
case "$WF" in *__SYNCTHING_URL__*|*__WORKER_CRED_ID__*) no "placeholders left in the workflow";; *) ok "placeholders filled";; esac
eq "workflow is active" "$(jq -r .active <<<"$WF")" "true"

TID="$(curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$U/api/v1/data-tables" | jq -r '.data[0].id')"
rows() { curl -fsS -H "X-N8N-API-KEY: $N8N_API_KEY" "$U/api/v1/data-tables/$TID/rows?limit=100" | jq -c '.data'; }
# rq NAME JQ-FILTER EXPECTED: the webhook answers before its execution has
# written the row, so retry for up to 15 s before deciding. A short settle
# first, so "nothing happened" checks don't pass before the execution ran.
rq() {
  local got=""
  sleep 2
  for _ in $(seq 1 15); do
    got="$(rows | jq -r "$2")"
    [ "$got" = "$3" ] && break
    sleep 1
  done
  eq "$1" "$got" "$3"
}
TOKEN="$(cat /tmp/worker-token)"
post() { curl -sS -m 30 -o /tmp/body -w '%{http_code}' -X POST "$U/webhook/vault-loop/$1" -H 'Content-Type: application/json' "${@:3}" -d "$2"; }

# Plane webhook
post plane '{"event":"issue","action":"updated","data":{"id":"item-1","state":{"name":"Approved"}}}' >/dev/null
rq "approved item queued" '[.[]|select(.ref=="item-1" and .status=="queued" and .kind=="plane-item")]|length' "1"
post plane '{"event":"issue","action":"updated","data":{"id":"item-1","state":{"name":"Approved"}}}' >/dev/null
rq "duplicate approval not queued twice" '[.[]|select(.ref=="item-1")]|length' "1"
post plane '{"event":"issue","action":"updated","data":{"id":"item-2","state":{"name":"Backlog"}}}' >/dev/null
rq "non-approved item ignored" '[.[]|select(.ref=="item-2")]|length' "0"
post plane '{"event":"project","action":"updated","data":{"id":"p-1"}}' >/dev/null
rq "non-item event ignored" 'length' "1"

# Worker API
eq "next job needs the token" "$(post jobs/next '{}')" "403"
code=$(post jobs/next '{}' -H "X-Worker-Token: $TOKEN"); eq "next job answers" "$code" "200"
eq "next job is the approved item" "$(jq -r '.job.ref' /tmp/body)" "item-1"
JID="$(jq -r '.job.id' /tmp/body)"
rq "claimed job is running" ".[]|select(.id==$JID)|.status" "running"
rq "attempts counted" ".[]|select(.id==$JID)|.attempts" "1"
post jobs/next '{}' -H "X-Worker-Token: $TOKEN" >/dev/null
eq "empty queue gives null" "$(jq -r '.job' /tmp/body)" "null"

post plane '{"event":"issue","action":"updated","data":{"id":"item-1","state":{"name":"Approved"}}}' >/dev/null
rq "running job blocks a duplicate" '[.[]|select(.ref=="item-1")]|length' "1"

eq "bad report refused" "$(post jobs/report '{"id":"x","status":"done"}' -H "X-Worker-Token: $TOKEN")" "400"
eq "report accepted" "$(post jobs/report "{\"id\":$JID,\"status\":\"done\",\"detail\":\"PR opened\"}" -H "X-Worker-Token: $TOKEN")" "200"
rq "job marked done" ".[]|select(.id==$JID)|.status" "done"
rq "report detail kept" ".[]|select(.id==$JID)|.detail" "PR opened"

post plane '{"event":"issue","action":"updated","data":{"id":"item-1","state":{"name":"Approved"}}}' >/dev/null
rq "done job can be queued again" '[.[]|select(.ref=="item-1")]|length' "2"

# Run now form
fcode=$(curl -sS -m 30 -o /tmp/form -w '%{http_code}' "$U/form/vault-loop/run-now"); eq "Run now form page loads" "$fcode" "200"
grep -q 'Vault loop: run now' /tmp/form && ok "form shows its title" || no "form title missing"

echo "n8n-workflow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
