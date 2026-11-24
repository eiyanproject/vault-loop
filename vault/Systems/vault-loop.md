---
system: vault-loop
repo: eiyanproject/vault-loop
plane_project:
handover: README.md, docs/PHASE0.md, docs/N8N.md, docs/PLANE.md
deploy: "Proxmox host: bash proxmox/update-lxc.sh --ctid 108 --role loop --snapshot --yes"
ctid: 108
node: eiyan2
url: http://<loop-ip>:5678
working_copy: Documents\Claudecode\vault-loop
---

# vault-loop

This loop's own infrastructure: the n8n control layer and its workflows, the
vault backup on CT 107, and the PC helpers. Plane is not part of it (community
script). Rules: the repo's `CLAUDE.md`.
