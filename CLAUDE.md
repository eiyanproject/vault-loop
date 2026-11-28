# vault-loop

Infrastructure for the vault → Plane → Claude Code → PR loop. README.md has the
shape; docs/PHASE0.md is the runbook for the current phase.

Invariants:

- Host scripts follow the homelab convention: they print a plan and change
  nothing until `--yes` (or a typed "y" at a terminal). Installers under
  `install/` run inside the container, are idempotent, and are the update path.
- Installers never overwrite secrets already in `.env`. The only key they
  rewrite on a re-run is the version pin.
- Every third-party download is pinned to an exact version at least two weeks
  old.
- Plane is **not** installed or updated by this repo: it runs in its own CT from
  the Proxmox VE community script (native install under `/opt/plane`, no
  Docker). `docs/PLANE.md` is the only Plane material here; never add a Plane
  installer back.
- Nothing in this repo opens a port to the internet. Remote access is LAN,
  Tailscale, and public hostnames that go Access → tunnel → OCI Caddy →
  Tailscale, with Access over the whole hostname and no bypass path: every
  machine-to-machine call stays on the LAN (`docs/N8N.md`).
- The vault backup keeps its git directory outside the vault, so Syncthing never
  sees `.git`.
- Never print, log or commit a secret. Generated keys stay in the container.
- New .sh files: `git update-index --chmod=+x` (authored on Windows).
- Every address, API key, token and webhook is listed in `docs/ENDPOINTS.md`:
  what it is for and where its value lives, never the value. Update it in the
  same change that adds, moves or removes one.

- The n8n workflow is generated: edit `n8n/src/workflow.js`, run
  `bash n8n/build.sh`, commit both. Never hand-edit `n8n/workflows/*.json`.
  Values that differ per install (credential IDs, Syncthing address and folder)
  are `__PLACEHOLDERS__` filled in by `n8n/setup-n8n.sh`.

Tests (Docker only): `bash test/run-scripts.sh` and `bash test/run-n8n.sh`.
PC helpers: `pwsh -File test/pc.tests.ps1`.

## Observability

n8n exposes `/metrics` on 5678 (`N8N_METRICS=true`). Register it on both mon
LXCs with homelab-monitoring's `scripts/register-service.sh`. Plane has no
Prometheus endpoint; its CT is covered by the PVE guest metrics.
