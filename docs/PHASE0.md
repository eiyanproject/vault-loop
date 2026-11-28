# Phase 0: infrastructure

Installs only. No automation runs at the end of this phase; you get the pieces
the later phases wire together.

**Done when:**

- a note written on the phone reaches CT 107 within a minute, with the PC off,
  and reaches the PC once it is back on;
- n8n and Plane both open from the phone;
- CT 200's Grafana shows `vault-loop` as a scraped service;
- the vault's first backup commit is on GitHub.

Order matters only where a step says so. Steps marked **(host)** run on the
Proxmox host eiyan2 as root, from a checkout of this repo.

Decisions already made: Syncthing reuses CT 107; Plane is self-hosted; n8n is
the control layer; no public hostnames in Phase 0 (the phone uses Tailscale).

---

## 1. PC

1. Install **Obsidian**: `winget install --id Obsidian.Obsidian -e`
2. Install **Syncthing**. The "Syncthing Windows Setup" installer linked from
   syncthing.net/downloads also sets it to start at login, which is what you
   want: the PC only receives notes while Syncthing runs.
3. Create the vault skeleton (creates only what's missing, never overwrites):

   ```powershell
   pwsh -File pc\new-vault.ps1 -Path "$HOME\Vaults\Main"
   ```

   Then in Obsidian: *Open folder as vault* → that folder.
4. Make sure **Docker Desktop** is running, **gh** is signed in (`gh auth login`)
   and **Claude Code** answers `claude --version`. Claude Code headless and its
   token come in Phase 3; nothing to set up for it now.
5. Check:

   ```powershell
   pwsh -File pc\check-pc.ps1 -Vault "$HOME\Vaults\Main"
   ```

## 2. Phone

1. Install **Obsidian** from the Play Store.
2. Install a **Syncthing Android client**. The original Syncthing app was
   discontinued in 2024; use the maintained fork listed on syncthing.net.
3. Install **Tailscale** if it isn't already, sign in to your tailnet, and turn
   on subnet routes so `192.168.0.0/24` is reachable (the route the homarr node
   advertises).

The phone's vault folder is created in step 4 when you accept the share.

## 3. CT 107: add the vault folder

CT 107 already runs Syncthing on eiyan2 with 256 MB RAM, which is enough for a
notes vault. In its web UI (`http://<ct107-ip>:8384`):

1. **Add Folder**
   - Label `Vault`, Folder ID `vault`
   - Path: somewhere on CT 107's disk, e.g. `/srv/vault` (create it if needed).
     Note the path: step 7 needs it.
   - **File Versioning** → Staggered, max age 30 days. This is the undo for an
     accidental delete that syncs everywhere.
   - **Ignore Patterns** → one line: `#include .stignore-shared`
2. Leave it empty for now; it fills from the PC in step 4.

## 4. Pair the devices

CT 107 is the hub; it is the only device that is always on.

1. PC Syncthing → *Add Remote Device* → CT 107's device ID (CT 107 UI →
   *Actions → Show ID*). Accept on CT 107.
2. PC → edit the `Main` vault folder: Folder ID **`vault`**, share with CT 107.
   (If the PC already created a folder with another ID, remove it from Syncthing
   — not from disk — and add it again with ID `vault`.)
3. Phone → add CT 107 as a device, accept the `vault` share, put it in a new
   folder, and set its ignore patterns to `#include .stignore-shared`.
4. In Obsidian on the phone: *Open folder as vault* → that folder.

**Test:** turn the PC's Syncthing off, write a note in `Inbox/` on the phone,
then on the host:

```bash
pct exec 107 -- ls -la /srv/vault/Inbox
```

The note should be there within a minute. Start the PC's Syncthing again and it
should appear on the PC too.

## 5. CT vault-loop: n8n (host)

Pick a free static IP first (`ping` it; nothing should answer).

```bash
bash proxmox/create-lxc.sh --role loop
```

It asks for the IP, shows the plan, and asks before creating anything. Defaults:
next free CTID (108 at the moment), 2 vCPU / 1 GB / 16 GB, Debian 13, n8n
2.46.6. At the end it prints the URL.

Then open `http://<loop-ip>:5678` and create the n8n owner account. Save the
encryption key somewhere safe (the installer prints how to read it): without it,
credentials stored in n8n are lost on a rebuild.

To install into a container that already exists instead, and for what is
configured in the web interface versus `.env`, see `docs/N8N.md`.

## 6. CT plane: Plane (community script) — done

Plane runs in its own CT, installed with the **Proxmox VE community script**,
not by this repo. That script installs Plane natively under `/opt/plane` (no
Docker) and is also how Plane is updated. Its default size is 4 vCPU / 6 GB
RAM / 8 GB disk; `docs/PLANE.md` has the details.

Then:

1. `http://<plane-ip>/god-mode/` → create the instance admin.
2. `http://<plane-ip>/` → create **one** workspace (e.g. `homelab`). Projects
   and states come in Phase 1; `docs/PLANE.md` has the layout (one project per
   system) and the bot account for the agent.
3. **Once n8n has its IP (step 5)**, allow Plane to send webhooks to it: add
   `WEBHOOK_ALLOWED_IPS=<loop-ip>/32` to Plane's API config and restart it.
   The exact commands are in `docs/PLANE.md` ("Plane refuses a private
   address"). Without this, Plane won't deliver webhooks to n8n.

## 7. Vault backup (host)

1. On GitHub, create an **empty private** repo for the vault (no README, no
   licence).
2. Run, with the CT 107 path from step 3:

   ```bash
   bash proxmox/setup-vault-backup.sh --ctid 107 --vault /srv/vault \
        --remote git@github.com:<you>/<vault-repo>.git
   ```

   Read the plan, then add `--yes`.
3. Add the public key it prints as a **deploy key with write access** on that
   repo.
4. Run the first backup with the command it prints, and check the commit is on
   GitHub.

From then on it runs nightly at 03:30 and catches up after downtime. Logs go to
CT 107's journal (`journalctl -u vault-backup`).

## 8. Monitoring (host)

From the homelab-monitoring checkout, once per node:

```bash
./scripts/register-service.sh --ctid 200 --service vault-loop --target <loop-ip>:5678 --yes   # on eiyan2
./scripts/register-service.sh --ctid 201 --service vault-loop --target <loop-ip>:5678 --yes   # on eiyan
```

Check it within a minute or two:

```bash
curl -s 'http://192.168.0.200:8428/api/v1/query?query=up{service="vault-loop"}'
```

Plane has no `/metrics`; its CT is covered by the guest metrics PVE already
sends.

## 9. From the phone

With Tailscale on, open `http://<loop-ip>:5678` and `http://<plane-ip>/`. Both
should load. Bookmark them.

---

## What you'll have

| | Where | Address |
| --- | --- | --- |
| Vault hub | CT 107, eiyan2 | `/srv/vault` (or your path) |
| n8n | CT 110, eiyan2 | `http://<loop-ip>:5678` |
| Plane | CT 108, eiyan2 | `http://<plane-ip>/` |
| Vault backup | GitHub, private | nightly 03:30 |

## Undo

- `pct stop <ctid> && pct destroy <ctid>` removes either new CT completely.
- On CT 107: `systemctl disable --now vault-backup.timer`, then delete
  `/usr/local/bin/vault-backup`, `/etc/systemd/system/vault-backup.*` and
  `/var/lib/vault-backup`. The vault itself is never touched by the backup.
