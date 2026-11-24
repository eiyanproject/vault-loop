---
system: vnc-gateway
repo: eiyanproject/vnc-gateway
plane_project:
handover: docs/HANDOVER.md
deploy: "Proxmox host: bash update-lxc.sh --ctid 103 --snapshot --yes"
ctid: 103
node: eiyan
url:
working_copy: Documents\Claudecode\vnc-gateway
---

# vnc-gateway

Browser VNC gateway (guacamole-lite) for the Windows PC, behind Cloudflare
Access for public use. Rules for changing it: the repo's `CLAUDE.md`. Agreed
to-do list: the repo's `TODO.md`.
