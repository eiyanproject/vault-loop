#!/usr/bin/env bash
# Regenerates n8n/workflows/vault-loop.json from n8n/src/workflow.js.
# Uses the pinned n8n image's own Node.js, so nothing else needs installing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PIN="$(grep -E '^N8N_VERSION_PIN=' "$HERE/../install/loop.sh" | cut -d= -f2 | tr -d '"')"
mkdir -p "$HERE/workflows"
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint node -v "$HERE/src:/src:ro" \
  "docker.n8n.io/n8nio/n8n:${PIN}" /src/workflow.js > "$HERE/workflows/vault-loop.json.tmp"
mv "$HERE/workflows/vault-loop.json.tmp" "$HERE/workflows/vault-loop.json"
echo "wrote n8n/workflows/vault-loop.json"
