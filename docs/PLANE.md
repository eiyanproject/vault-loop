# Plane: layout and webhooks

How Plane is organised for the loop, and how it talks to n8n (CT 110).

## How Plane is installed

Plane runs in its own CT from the **Proxmox VE community script**
(`community-scripts/ProxmoxVE`, `ct/plane.sh`), not from this repo. As read
from that script on 24 Nov 2026:

- **Native install, no Docker:** nginx, PostgreSQL 16, Redis, RabbitMQ and a
  MinIO-compatible store, with Plane under `/opt/plane` and its Python venv in
  `/opt/plane-venv`.
- **Services:** `plane-api`, `plane-worker`, `plane-beat`, `plane-live`,
  `plane-space`, `minio` (systemd).
- **Config:** the API's settings are in `/opt/plane/apps/api/.env`, loaded by
  the services. Generated credentials are summarised in `~/plane.creds` inside
  the CT. There is no `plane.env`.
- **Web UI:** nginx on port 80.
- **Default size:** 4 vCPU, 6 GB RAM, 8 GB disk.
- **Version:** not pinned. Install and update both take Plane's latest release.
- **Updating:** run the community script's update inside the CT. It backs up and
  restores the `.env` files under `/opt/plane`, so settings added there (like the
  webhook allowlist below) survive an update.

## One workspace, one project per system

Use **one workspace** (for example `homelab`) and **one project per system**.

- A workspace is Plane's top level. Members, webhooks and the cross-project
  "Your work" view are set per workspace. Several workspaces would mean a
  webhook and an API token for each, and no single view from the phone.
- A project is one system: learnbox, web-video-editor,
  vault-loop, vnc-gateway, homelab-monitoring, and so on. Each has its own work
  items, states, labels, Modules and Cycles. Give each a short identifier
  (`LRN`, `R18`, ...) so items read as `LRN-12`.
- Each `Systems/<name>.md` entry in the vault names its Plane project. Triage
  picks the project; a new system becomes a new project in the same workspace.
- A roadmap is the **Modules** inside that system's project, not a separate
  project.
- Every project uses the same states, so n8n only has to recognise one set:
  Proposed → Approved → Agent working → In review → Done, plus Needs you.

### A second workspace only for things the agent must never touch

Personal or non-system tasks can live in their own workspace. The wall that
keeps the agent out is a **separate bot account** that is a member of the
`homelab` workspace only, with its API token created under that account. Your
own account can belong to both. Use the bot account even with one workspace,
so everything the agent does in Plane shows under its name, not yours.

## Webhooks to n8n

Plane and n8n are both on the LAN, so the webhook goes straight from CT 108 to
CT 110 by IP address. **No subdomain, tunnel or public hostname is needed.**

1. **In n8n:** a workflow that starts with a **Webhook** node, method `POST`,
   path e.g. `plane`. Copy its **Production URL**
   (`http://<loop-ip>:5678/webhook/plane`) and **activate** the workflow. The
   Test URL only works while the editor is listening, so never give it to Plane.
2. **In Plane:** *Workspace settings → Webhooks → Add webhook*. Paste the URL and
   tick the events needed (work items). Keep the **secret key** Plane shows: n8n
   uses it to check each delivery really came from Plane.

### Plane refuses a private address unless it is allowed

Plane checks every webhook URL and refuses ones that resolve to a private
address such as `192.168.x.x`, unless the address is in `WEBHOOK_ALLOWED_IPS`
(read by the API at start, from `apps/api/plane/settings/common.py`; a
comma-separated list of addresses or CIDR ranges). The community script does
not set it, so add n8n's address once n8n has its IP. Inside the Plane CT:

```bash
grep -q '^WEBHOOK_ALLOWED_IPS=' /opt/plane/apps/api/.env \
  && sed -i 's|^WEBHOOK_ALLOWED_IPS=.*|WEBHOOK_ALLOWED_IPS=<loop-ip>/32|' /opt/plane/apps/api/.env \
  || echo 'WEBHOOK_ALLOWED_IPS=<loop-ip>/32' >> /opt/plane/apps/api/.env
systemctl restart plane-api plane-worker
```

`plane-worker` is restarted too because it is the service that delivers
webhooks. If saving the webhook in Plane still fails with a "blocked IP" style
error, check the line is there with `grep WEBHOOK_ALLOWED_IPS
/opt/plane/apps/api/.env`.

## Senders outside the LAN

Only a sender outside the network would need a public address. In this plan
that is GitHub ("PR merged"), whose servers can't reach the LAN. Instead of
exposing n8n, n8n **polls GitHub** every few minutes for merged PRs, so nothing
needs a public hostname.
