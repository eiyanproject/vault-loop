# vault-loop

Infrastructure for the vault → Plane → Claude Code → PR loop. README.md has the
shape; docs/PHASE0.md is the runbook for the current phase.

Invariants:

- Host scripts follow the homelab convention: they print a plan and change
  nothing until `--yes` (or a typed "y" at a terminal). Installers under
  `install/` run inside the container, are idempotent, and are the update path.
- Installers never overwrite secrets already in `.env` / `plane.env`. The only
  keys they rewrite on a re-run are version pins.
- Every third-party download is pinned to an exact version at least two weeks
  old. Plane's release files are also pinned by sha256 in `install/plane.sh`;
  bumping the version means bumping the hashes.
- Nothing in this repo opens a port to the internet. Remote access is Tailscale
  in Phase 0; a public hostname later goes Access → tunnel → OCI Caddy → Tailscale.
- The vault backup keeps its git directory outside the vault, so Syncthing never
  sees `.git`.
- Never print, log or commit a secret. Generated keys stay in the container.
- New .sh files: `git update-index --chmod=+x` (authored on Windows).

Tests (Docker only): `bash test/run-scripts.sh`. PC helpers: `pwsh -File test/pc.tests.ps1`.

## Observability

n8n exposes `/metrics` on 5678 (`N8N_METRICS=true`). Register it on both mon
LXCs with homelab-monitoring's `scripts/register-service.sh`. Plane has no
Prometheus endpoint; its CT is covered by the PVE guest metrics.
