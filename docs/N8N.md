# n8n: install and how it is configured

n8n (CT 110) is the loop's control layer: job queue, triggers and the Run now
page. It does no AI work and reads no vault files. The container runs **only
n8n**: one Docker container with its built-in SQLite database in a volume.

## Two ways to install

`install/loop.sh` is written to run inside the container.
`proxmox/create-lxc.sh` creates the container and then runs that same script in
it.

**A. From the Proxmox host (creates the container too)** - `docs/PHASE0.md` step 5:

```bash
git clone https://github.com/eiyanproject/vault-loop.git
cd vault-loop
bash proxmox/create-lxc.sh --role loop
```

**B. Inside a container that already exists.** Docker needs these features, set
on the **host**:

```bash
pct set <ctid> --features nesting=1,keyctl=1
pct reboot <ctid>
```

Then **inside the container**, as root:

```bash
apt-get update && apt-get install -y curl
curl -fsSLO https://raw.githubusercontent.com/eiyanproject/vault-loop/main/install/loop.sh
bash loop.sh
```

Either way, the script installs Docker, writes `/opt/vault-loop/.env` with a
random encryption key, starts n8n on port 5678, waits until it is ready, and
prints the URL plus the two monitoring registration commands.

Afterwards: open `http://<loop-ip>:5678`, create the owner account, and back up
the encryption key (`grep N8N_ENCRYPTION_KEY /opt/vault-loop/.env`). Without it,
credentials saved in n8n can't be decrypted after a rebuild.

Updating is re-running the installer (A: `proxmox/update-lxc.sh --ctid 108
--role loop --yes`; B: `bash loop.sh` again). It keeps every setting and only
changes the n8n version.

## Where things are configured

**In the web interface** (`http://<loop-ip>:5678`), which is where nearly all of
it happens:

- **Workflows** - nodes on a canvas: Webhook → IF → HTTP Request, and so on.
- **Credentials** - Plane, GitHub and ntfy tokens, saved once and shared by
  every workflow.
- **Executions** - every run, with what went in and out of each node.
- **Settings** - users, the owner account, n8n API keys.

**In `/opt/vault-loop/.env`**, set once by the installer and rarely touched:
timezone, the URL n8n advertises for webhooks (`WEBHOOK_URL`), metrics, and how
long old executions are kept. Change a value there, then
`docker compose -f /opt/vault-loop/docker-compose.yml up -d`. Never paste this
file anywhere: it holds the encryption key.

## Serving n8n on a public hostname

n8n can also be opened at an https hostname, e.g. `https://<n8n-host>`, through
Cloudflare Access → a Cloudflare Tunnel → a reverse proxy that reaches the LAN.
The LAN address keeps working, and every machine-to-machine call (Plane's
webhook, the PC worker, the metrics scrape) stays on the LAN.

- **Put Access in front of the whole hostname, with no bypass path.** The Run
  now form and the Plane webhook have no authentication of their own; on the
  LAN that is fine, on the internet it is not. Create the Access application
  **before** the DNS record exists.
- **In `.env`**, then recreate the container
  (`docker compose -f /opt/vault-loop/docker-compose.yml up -d --force-recreate`):

  ```
  N8N_HOST=<n8n-host>
  N8N_PROTOCOL=https
  WEBHOOK_URL=https://<n8n-host>/
  N8N_PROXY_HOPS=1
  ```

  `WEBHOOK_URL` only changes the URLs n8n *shows* for webhooks and forms; the
  paths answer on every address. The installer only fills in missing keys, so
  re-running it keeps these.
- **Leave `N8N_SECURE_COOKIE=false`** while you also log in over plain http on
  the LAN: with it on, n8n refuses an http login.
- **Check:** without an Access session, `curl -sI https://<n8n-host>/form/vault-loop/run-now`
  must answer `302` to `<team>.cloudflareaccess.com`, never `200`.

## Loop workflow (Phase 2)

The loop runs as **one workflow**, `vault-loop`, kept in this repo:
`n8n/src/workflow.js` is the source, `n8n/build.sh` generates
`n8n/workflows/vault-loop.json`, and `n8n/setup-n8n.sh` creates the queue
table and credentials, imports the workflow and turns it on. Steps:
`docs/PHASE2.md`.

You can still open and inspect it in the web interface, and its queue shows
under *Overview → Data tables → loop_jobs*. Changes made only in the web
interface are overwritten the next time setup runs, so make lasting changes in
`n8n/src/workflow.js`. The repo copy is the one that counts.
