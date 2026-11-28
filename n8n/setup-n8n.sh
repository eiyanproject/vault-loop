#!/usr/bin/env bash
#
# Sets up the loop inside a running n8n through its public API:
#   1. the data table `loop_jobs` (the job queue)
#   2. two credentials: "vault-loop worker" (the PC worker's token) and
#      "Syncthing CT 107" (Syncthing's API key)
#   3. the workflow `vault-loop` from n8n/workflows/vault-loop.json,
#      created or updated in place, then turned on
#
# Run it from any machine that reaches n8n, e.g. inside CT 110, from a checkout
# of this repo. Needs curl and jq. Re-running is safe: it creates only what is
# missing and updates the workflow to the repo's version.
#
#   N8N_API_KEY=... SYNCTHING_API_KEY=... bash n8n/setup-n8n.sh --url http://127.0.0.1:5678
#   N8N_API_KEY=... SYNCTHING_API_KEY=... bash n8n/setup-n8n.sh --url http://127.0.0.1:5678 --yes
#
# Nothing is changed until you pass --yes.
#
#   N8N_API_KEY        n8n: Settings -> n8n API -> Create an API key
#   SYNCTHING_API_KEY  CT 107's Syncthing: Actions -> Settings -> General -> API Key
#                      (only needed the first time, when the credential is created)
#   SYNCTHING_URL      CT 107's Syncthing      (default: http://192.168.0.36:8384)
#   SYNCTHING_FOLDER   the vault's folder ID   (default: vault; the ID column in
#                      Syncthing's folder list, not its label)
#   TOKEN_FILE         where the PC worker's token is written on first run
#                      (default: ./worker-token, mode 600). Give it to the worker.
#
# Secrets are read from the environment and sent only to n8n. They are never
# printed.
set -euo pipefail

URL=""; CONFIRM="no"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW_FILE="${WORKFLOW_FILE:-$HERE/workflows/vault-loop.json}"
TOKEN_FILE="${TOKEN_FILE:-./worker-token}"
SYNCTHING_URL="${SYNCTHING_URL:-http://192.168.0.36:8384}"
SYNCTHING_URL="${SYNCTHING_URL%/}"
SYNCTHING_FOLDER="${SYNCTHING_FOLDER:-vault}"

die() { echo "error: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --yes) CONFIRM="yes"; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$URL" ] || die "--url is required, e.g. --url http://127.0.0.1:5678"
URL="${URL%/}"
[ -n "${N8N_API_KEY:-}" ] || die "N8N_API_KEY is not set (n8n: Settings -> n8n API)"
command -v jq   >/dev/null 2>&1 || die "jq is required (apt-get install -y jq)"
command -v curl >/dev/null 2>&1 || die "curl is required"
[ -f "$WORKFLOW_FILE" ] || die "workflow file not found: $WORKFLOW_FILE (run n8n/build.sh)"
[[ "$SYNCTHING_URL" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || die "SYNCTHING_URL must look like http://host:8384"
[[ "$SYNCTHING_FOLDER" =~ ^[A-Za-z0-9._-]+$ ]] || die "SYNCTHING_FOLDER may only contain letters, digits, . _ -"

api() {  # api METHOD PATH [JSON-BODY]
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  if [ -n "$body" ]; then
    code="$(curl -sS -m 30 -o "$out" -w '%{http_code}' -X "$method" "$URL/api/v1$path" \
      -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' --data-binary @- <<<"$body")"
  else
    code="$(curl -sS -m 30 -o "$out" -w '%{http_code}' -X "$method" "$URL/api/v1$path" \
      -H "X-N8N-API-KEY: $N8N_API_KEY")"
  fi
  if [ "${code:0:1}" != "2" ]; then
    echo "error: $method $path -> HTTP $code: $(head -c 400 "$out")" >&2
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

# --- Look at what is there ---------------------------------------------------
api GET "/workflows?limit=1" >/dev/null || die "n8n API not reachable at $URL, or the API key is wrong"

TABLE_ID="$(api GET "/data-tables?filter=$(jq -rn '{name:"loop_jobs"}|tostring|@uri')" | jq -r '.data[0].id // empty')"
CREDS="$(api GET "/credentials?limit=250" 2>/dev/null || echo '{"data":[]}')"
WORKER_CRED_ID="$(jq -r '.data[] | select(.name=="vault-loop worker") | .id' <<<"$CREDS" | head -1)"
SYNC_CRED_ID="$(jq -r '.data[] | select(.name=="Syncthing CT 107") | .id' <<<"$CREDS" | head -1)"
WF_ID="$(api GET "/workflows?name=vault-loop&limit=250" | jq -r '.data[] | select(.name=="vault-loop") | .id' | head -1)"

if [ -z "$SYNC_CRED_ID" ] && [ -z "${SYNCTHING_API_KEY:-}" ]; then
  die "SYNCTHING_API_KEY is not set, and the 'Syncthing CT 107' credential does not exist yet"
fi

cat <<PLAN

  Plan for $URL
  ----
  data table  loop_jobs            $( [ -n "$TABLE_ID" ] && echo "exists ($TABLE_ID), kept" || echo "create" )
  credential  vault-loop worker    $( [ -n "$WORKER_CRED_ID" ] && echo "exists, kept" || echo "create; token written to $TOKEN_FILE" )
  credential  Syncthing CT 107     $( [ -n "$SYNC_CRED_ID" ] && echo "exists, kept" || echo "create from SYNCTHING_API_KEY" )
  workflow    vault-loop           $( [ -n "$WF_ID" ] && echo "exists ($WF_ID), update to the repo version" || echo "create" ), then activate
  syncthing   $SYNCTHING_URL, folder ID '$SYNCTHING_FOLDER'

PLAN

if [ "$CONFIRM" != "yes" ]; then
  echo "  Dry run. Nothing was changed. Re-run with --yes to apply."
  exit 0
fi

# --- 1. Data table -----------------------------------------------------------
if [ -z "$TABLE_ID" ]; then
  TABLE_ID="$(api POST /data-tables "$(jq -n '{name:"loop_jobs", columns:[
      {name:"job_key",type:"string"}, {name:"kind",type:"string"}, {name:"source",type:"string"},
      {name:"ref",type:"string"}, {name:"status",type:"string"}, {name:"attempts",type:"number"},
      {name:"detail",type:"string"}]}')" | jq -r '.id // .data.id')"
  [ -n "$TABLE_ID" ] && [ "$TABLE_ID" != "null" ] || die "could not create the loop_jobs data table"
  echo "==> created data table loop_jobs ($TABLE_ID)"
fi

# --- 2. Credentials ----------------------------------------------------------
if [ -z "$WORKER_CRED_ID" ]; then
  [ -e "$TOKEN_FILE" ] && die "$TOKEN_FILE already exists but n8n has no 'vault-loop worker' credential. Move the file away first."
  TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  ( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE" )
  WORKER_CRED_ID="$(api POST /credentials "$(jq -n --arg v "$TOKEN" \
      '{name:"vault-loop worker", type:"httpHeaderAuth", data:{name:"X-Worker-Token", value:$v}}')" | jq -r '.id')"
  unset TOKEN
  echo "==> created credential 'vault-loop worker'; the worker's token is in $TOKEN_FILE (mode 600)"
fi
if [ -z "$SYNC_CRED_ID" ]; then
  SYNC_CRED_ID="$(api POST /credentials "$(jq -n --arg v "$SYNCTHING_API_KEY" \
      '{name:"Syncthing CT 107", type:"httpHeaderAuth", data:{name:"X-API-Key", value:$v}}')" | jq -r '.id')"
  echo "==> created credential 'Syncthing CT 107'"
fi

# --- 3. Workflow -------------------------------------------------------------
BODY="$(sed -e "s/__WORKER_CRED_ID__/$WORKER_CRED_ID/g" -e "s/__SYNCTHING_CRED_ID__/$SYNC_CRED_ID/g" \
             -e "s|__SYNCTHING_URL__|$SYNCTHING_URL|g" -e "s/__SYNCTHING_FOLDER__/$SYNCTHING_FOLDER/g" "$WORKFLOW_FILE" \
  | jq '{name, nodes, connections, settings}')"
if [ -n "$WF_ID" ]; then
  api PUT "/workflows/$WF_ID" "$BODY" >/dev/null
  echo "==> updated workflow vault-loop ($WF_ID)"
else
  WF_ID="$(api POST /workflows "$BODY" | jq -r '.id')"
  echo "==> created workflow vault-loop ($WF_ID)"
fi
api POST "/workflows/$WF_ID/activate" >/dev/null
echo "==> activated"

cat <<EOF

  Done. In n8n:
    Run now form   $URL/form/vault-loop/run-now
    Plane webhook  $URL/webhook/vault-loop/plane        (paste into Plane's webhook settings)
    Worker API     POST $URL/webhook/vault-loop/jobs/next and /jobs/report,
                   header X-Worker-Token: <contents of $TOKEN_FILE>
    Queue          Overview -> Data tables -> loop_jobs

EOF
