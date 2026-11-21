# vault-loop

Phone note → Plane ticket → Claude Code on the PC → PR → lesson back in the vault.

This repo holds the infrastructure for that loop. The plan and roadmap live in
the artifact "Vault-to-PR Loop"; `docs/PHASE0.md` is the step-by-step for the
first phase.

## Shape

| Piece | Where | What |
| --- | --- | --- |
| Vault sync peer | CT 107 `syncthing` (existing, eiyan2) | Always-on Syncthing copy of the vault |
| Control | CT `vault-loop` (new, eiyan2) | n8n: queue, triggers, Run now page |
| Tickets + roadmaps | CT `plane` (new, eiyan2) | Plane Community |
| AI work | The Windows PC | Claude Code under the existing subscription |
| Capture | Phone + PC | Obsidian, Syncthing |

Nothing in the lab is published to the internet in Phase 0. The phone reaches
n8n and Plane over Tailscale, through the existing subnet route.

## Layout

```
proxmox/create-lxc.sh          host: create CT vault-loop or CT plane (--role)
proxmox/update-lxc.sh          host: re-run the installer inside one of them
proxmox/setup-vault-backup.sh  host: nightly git backup of the vault in CT 107
install/loop.sh                inside CT vault-loop: Docker + n8n
install/plane.sh               inside CT plane: Docker + Plane (pinned, checksummed)
pc/check-pc.ps1                PC: read-only check of the PC prerequisites
pc/new-vault.ps1               PC: create the vault folder skeleton
docs/PHASE0.md                 the Phase 0 runbook
test/run-scripts.sh            script tests, Docker only
```

## Tests

```bash
bash test/run-scripts.sh      # shellcheck + stubbed host-script tests in Debian containers
```

```powershell
pwsh -File test/pc.tests.ps1
```
