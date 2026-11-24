#!/usr/bin/env bash
# End-to-end test of n8n/setup-n8n.sh and the vault-loop workflow against a
# throwaway n8n (the pinned version) on its own Docker network. Docker only;
# everything is removed afterwards.
#
#   bash test/run-n8n.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$(grep -E '^N8N_VERSION_PIN=' "$ROOT/install/loop.sh" | cut -d= -f2 | tr -d '"')"
NET="vl-n8n-test-$$"; N8N="vl-n8n-$$"
export MSYS_NO_PATHCONV=1

cleanup() { docker rm -f "$N8N" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
# KEEP=1 leaves the test n8n running on http://127.0.0.1:15679 for debugging;
# remove it afterwards with: docker rm -f <name printed below>
if [ -n "${KEEP:-}" ]; then echo "keeping $N8N on :15679"; PUBLISH=(-p 127.0.0.1:15679:5678); else trap cleanup EXIT; PUBLISH=(); fi

docker network create "$NET" >/dev/null
docker run -d --name "$N8N" --network "$NET" "${PUBLISH[@]}" \
  -e N8N_DIAGNOSTICS_ENABLED=false -e N8N_SECURE_COOKIE=false -e N8N_PERSONALIZATION_ENABLED=false \
  "docker.n8n.io/n8nio/n8n:${PIN}" >/dev/null

docker run --rm --network "$NET" -e N8N_HOST_URL="http://$N8N:5678" \
  -v "$ROOT:/src:ro" debian:13 bash -c '
    set -e
    apt-get update -qq >/dev/null && apt-get install -y -qq curl jq ca-certificates >/dev/null
    bash /src/test/scripts/n8n-workflow.test.sh'
