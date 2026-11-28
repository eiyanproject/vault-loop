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

Use **one workspace** (an existing one is fine) and **one project per system**.

- A workspace is Plane's top level. Members, webhooks and the cross-project
  "Your work" view are set per workspace. Several workspaces would mean a
  webhook and an API token for each, and no single view from the phone.
- A project is one system: learnbox, web-video-editor,
  vault-loop, vnc-gateway, homelab-monitoring, and so on. Each has its own work
  items, states, labels, Modules and Cycles. Give each a short identifier
  (`LRN`, `R18`, ...) so items read as `LRN-12`.
- The registry in the inbox vault (`docs/PHASE1.md` section 3) names each
  system's Plane project. Triage picks the project; a new system becomes a new
  project in the same workspace.
- A roadmap is the **Modules** inside that system's project, not a separate
  project.
- Every project uses the same states, so n8n only has to recognise one set:
  Proposed → Approved → Agent working → In review → Done, plus Needs you.

### A second workspace only for things the agent must never touch

Personal or non-system tasks can live in their own workspace. The wall that
keeps the agent out is a **separate bot account** that is a member of the
loop's workspace only, with its API token created under that account. Your
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

Only a sender outside the network would need a public address (the public
hostname below is for you in a browser, behind Access - not for senders). In this plan
that is GitHub ("PR merged"), whose servers can't reach the LAN. Instead of
exposing n8n, n8n **polls GitHub** every few minutes for merged PRs, so nothing
needs a public hostname.

## Opening Plane on a public hostname

For **you**, from a browser anywhere: `https://<plane-host>` through Cloudflare
Access → a Cloudflare Tunnel → a reverse proxy that reaches `<plane-ip>`. The
webhook to n8n and the PC worker keep using `<plane-ip>` on the LAN. Put Access
over the whole hostname, with no bypass path, before the DNS record exists.

**Browser sign-in then works only on `<plane-host>`.** Plane (checked against
1.5.0) has no setting that allows it on both addresses:

- `WEB_URL` (or `APP_BASE_URL`) **must be set**. `plane/utils/host.py` raises
  `ImproperlyConfigured` on every successful login when both are empty: a bare
  "Server Error (500)" on `POST /auth/sign-in/`, and nothing in the request log.
  Every sign-in redirects to `WEB_URL`.
- `WEB_URL=https://...` makes the session cookie `Secure`, which browsers won't
  store over plain-http `<plane-ip>`.

`<plane-ip>` keeps serving the API and loads the UI, but a browser can only sign
in on `<plane-host>`.

The community script builds Plane with `http://<plane-ip>` fixed in the web
apps and the API, so these change inside the Plane CT:

| File | Change | Why |
|---|---|---|
| `/opt/plane/apps/api/.env` | `WEB_URL`, `APP_BASE_URL`, `ADMIN_BASE_URL`, `SPACE_BASE_URL` = `https://<plane-host>` | sign-in, redirects, cookies |
| same | keep `LIVE_BASE_URL=http://<plane-ip>` | the API calls the live server with it |
| same | `CORS_ALLOWED_ORIGINS=https://<plane-host>,http://<plane-ip>` | also the CSRF trust list |
| `/opt/plane/apps/{web,admin,space}/.env` | every `VITE_*_BASE_URL=` empty; keep the `*_BASE_PATH` lines | the web apps use the address the page was opened on (otherwise set them to `https://<plane-host>`) |
| nginx | pass `X-Forwarded-Proto` through instead of `$scheme` (below) | with MinIO, upload and download links take the request's scheme; behind the tunnel every hop is `http`, so an https page would get `http://` links and block them |

```bash
# inside the Plane CT - back up first
for f in /opt/plane/apps/{web,admin,space,api}/.env /etc/nginx/sites-available/plane.conf; do cp "$f" "$f.bak-pre-subdomain"; done
for a in web admin space; do sed -i -E 's|^(VITE_[A-Z]+_BASE_URL)=.*|\1=|' /opt/plane/apps/$a/.env; done
sed -i -E 's#^(WEB_URL|APP_BASE_URL|ADMIN_BASE_URL|SPACE_BASE_URL)=.*#\1=https://<plane-host>#; s#^CORS_ALLOWED_ORIGINS=.*#CORS_ALLOWED_ORIGINS=https://<plane-host>,http://<plane-ip>#' /opt/plane/apps/api/.env
echo 'map $http_x_forwarded_proto $plane_fwd_proto { default $http_x_forwarded_proto; "" $scheme; }' > /etc/nginx/conf.d/plane-forwarded-proto.conf
sed -i 's|proxy_set_header X-Forwarded-Proto \$scheme;|proxy_set_header X-Forwarded-Proto $plane_fwd_proto;|' /etc/nginx/sites-available/plane.conf
nginx -t && systemctl reload nginx
cd /opt/plane && export NODE_OPTIONS="--max-old-space-size=4096" COREPACK_ENABLE_DOWNLOAD_PROMPT=0
pnpm turbo run build --filter=web --filter=admin --filter=space --filter=live   # 10-20 min
systemctl restart plane-api plane-worker plane-beat plane-live plane-space
```

The reverse proxy in front must send `X-Forwarded-Proto: https` (Caddy:
`reverse_proxy <plane-ip>:80 { header_up X-Forwarded-Proto https }`). Plane's
API runs under gunicorn, which trusts that header from nginx on `127.0.0.1`.

- **Snapshot the CT first** (`pct snapshot <ctid> pre-subdomain`); rolling back
  undoes all of it.
- **It survives updates:** the community script's update backs up and restores
  these four `.env` files and rebuilds the web apps with them, and does not
  touch nginx.
- **Re-check after every Plane update:** sign in on `<plane-host>`, open a page
  in the editor, upload an image.
- **Check from outside:** without an Access session, every path on
  `https://<plane-host>` must answer `302` to `<team>.cloudflareaccess.com`.
- Changing only the API `.env` needs `systemctl restart plane-api plane-worker plane-beat`; a `VITE_*` change needs the rebuild.
