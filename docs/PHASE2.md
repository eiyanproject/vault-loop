# Phase 2: triggers, queue and Run now

Everything in this phase lives in **one n8n workflow**, `vault-loop`, built
from `n8n/src/workflow.js` into `n8n/workflows/vault-loop.json`, plus one data
table, `loop_jobs`, which is the job queue. `n8n/setup-n8n.sh` creates both
through n8n's API.

## What the workflow does

| Trigger | Queues | Notes |
|---|---|---|
| **Plane webhook** `POST /webhook/vault-loop/plane` | `plane-item` for a work item moved to **Approved** | Other states and non-item events are ignored. If Plane's payload carries no state name, the item is queued anyway and the worker checks it |
| **Run now** form `/form/vault-loop/run-now` | `scan-inbox`, or `triage` for one note, or requeues a `failed` job by id | Open it from the phone, or make it a Homarr tile |
| **Every 15 minutes** | `scan-inbox` | Also marks a job `failed` when a worker claimed it and sent no report within 2 hours |
| **Every minute**: Syncthing events | `triage` for each `.md` note CT 107 received | Waits until the vault folder is idle again, so one sync gives one job per note and never a half-written file |

At most one job per `kind:ref` is queued or running at a time; a repeat event
for the same note or item is dropped until that job is done or failed.

**The PC worker's side** (built in Phase 3), both `POST`, header
`X-Worker-Token: <token>`:

- `/webhook/vault-loop/jobs/next` → `{"job": {...}}` with the oldest queued job,
  now marked `running`, or `{"job": null}`.
- `/webhook/vault-loop/jobs/report` with `{"id": 12, "status": "done" | "failed",
  "detail": "..."}` → `{"ok": true}`, or HTTP 400 with the reason.

n8n still reads no vault files: Syncthing only tells it *which* notes changed.
The worker reads the notes from the PC's own Syncthing copy.

## 1. n8n

n8n must be running (`docs/N8N.md`). In its web UI:

1. *Settings → n8n API → Create an API key*.
2. In CT 107's Syncthing UI: *Actions → Settings → General → API Key*: copy it.
   Also note the **folder ID** of the shared vault folder (the ID, not the
   label: *Edit* on the folder shows it).

## 2. Run the setup (inside CT 110)

```bash
apt-get install -y git jq
git clone https://github.com/eiyanproject/vault-loop.git /opt/vault-loop-repo
cd /opt/vault-loop-repo
export N8N_API_KEY='<n8n API key>' SYNCTHING_API_KEY='<Syncthing API key>'
export SYNCTHING_URL=http://192.168.0.36:8384 SYNCTHING_FOLDER='<folder ID>'
TOKEN_FILE=/root/worker-token bash n8n/setup-n8n.sh --url http://127.0.0.1:5678        # plan
TOKEN_FILE=/root/worker-token bash n8n/setup-n8n.sh --url http://127.0.0.1:5678 --yes  # apply
```

It prints the plan first and changes nothing without `--yes`. On the first run
it writes the PC worker's token to `/root/worker-token` (mode 600); it never
prints a secret. Re-running it later updates the workflow to the repo's version
and keeps the table, credentials and token.

To change the Syncthing address or folder, re-run setup with the new values
rather than editing the workflow: setup overwrites the workflow each time.

## 3. Plane webhook

1. Allow Plane to reach n8n: `docs/PLANE.md`, "Plane refuses a private address".
2. *Workspace settings → Webhooks → Add webhook*: URL
   `http://<loop-ip>:5678/webhook/vault-loop/plane`, events: work items.

## Check

- Move a Plane work item to **Approved** → a `plane-item` row appears in
  *n8n → Overview → Data tables → loop_jobs*.
- Write a note on the phone → within a minute or two, a `triage` row for it.
- Open the Run now form and pick *Scan Inbox* → a `scan-inbox` row.
- Each trigger fires once per event: the same note synced twice while its job
  is still queued gives one row.

## Tested, and not

`bash test/run-n8n.sh` runs the setup script against a fresh n8n of the pinned
version and drives the Plane webhook, the worker API and the Run now page.
**Not covered by it:** the Syncthing trigger (needs a real Syncthing), the
Run now form's submissions, the 15-minute sweep, and Plane's real webhook
payload. Plane's payload shape was not checked against a live Plane, which is
why an item with no state name in the payload is queued for the worker to
check rather than dropped.

## Not in this phase

- **ntfy alerts on stuck jobs.** The OCI box can't be reached from the LAN over
  Tailscale (the subnet route only goes the other way), so alerts need ntfy's
  public address. Left until that is decided.
- **Checking Plane's webhook signature.** The webhook is LAN-only and Plane may
  only send to n8n's address; signature checking can be added later.
