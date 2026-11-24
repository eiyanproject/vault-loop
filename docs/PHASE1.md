# Phase 1: templates, registry and Plane setup

Configuration only. At the end, every system you'd want changed has a registry
entry and a Plane project, and you can move a work item from your phone.

## 1. Settle the open decisions

These change how later phases behave. Defaults used until you decide:

| Decision | Default until decided |
|---|---|
| Approval on every change ticket? | Yes: nothing codes without an Approved item |
| Daily job cap and quiet hours | Not enforced yet; the worker (Phase 3) will read them |
| New systems get a GitHub repo automatically? | No: you create the repo when you approve the roadmap |
| Phase 0 access: Tailscale only? | Yes |

## 2. Copy the templates and registry into the vault

The seed files are in this repo under `vault/` (see `vault/README.md`):

- `vault/Templates/` → the vault's `Templates/` folder. In Obsidian, turn on the
  core **Templates** plugin and set its template folder to `Templates`.
- `vault/Systems/` → the vault's `Systems/` folder. One note per system:
  vnc-gateway, learnbox, recipe-catalog, portfolio,
  homelab-monitoring, web-video-editor, vault-loop.

Copying never overwrites anything; if a file with the same name exists, keep
yours and merge by hand. Then fill in the blanks in each `Systems/` note:
the `ctid`, `node` or `deploy` fields left empty are ones the repos don't record.

The vault also needs the folders the loop files notes into: `Inbox`, `Idea`,
`Project`, `Incident`, `Task`, `Learned`, `_agent`. `pc/new-vault.ps1 -Path
<vault>` creates any that are missing and never overwrites a file.

## 3. Plane: workspace, projects, states, labels

Layout and the reasons for it: `docs/PLANE.md`. In the Plane web UI:

1. **One workspace**, e.g. `homelab`.
2. **One project per `Systems/` note.** Use a short identifier and write it into
   that note's `plane_project:` field:

   | System | Suggested identifier |
   |---|---|
   | vnc-gateway | `VNC` |
   | learnbox | `LRN` |
   | recipe-catalog | `RCP` |
   | portfolio | `WEB` |
   | homelab-monitoring | `MON` |
   | web-video-editor | `WVE` |
   | vault-loop | `LOOP` |

3. **States, the same in every project** (*Project settings → States*):
   `Proposed`, `Approved`, `Agent working`, `In review`, `Done`, `Needs you`.
   The names matter: n8n queues a coding job when an item's state is named
   exactly **Approved**.
4. **Labels**, the same in every project: `change`, `project`, `incident`,
   `small`.
5. **A bot account for the agent.** Invite a second Plane user (for example
   `loop-bot`) to the `homelab` workspace only, as a member. Sign in as it once
   and create its **API token** (*Profile settings → API tokens*, or *Workspace
   settings → API tokens* depending on the Plane version). Keep the token for
   Phase 3; the PC worker uses it.

**Check:** on your phone, open Plane over Tailscale, open any project, and move
a test work item between two states.

## Done when

- Every system you'd want changed has a `Systems/` note with its
  `plane_project` filled in, and a Plane project with the six states.
- The bot account exists in the `homelab` workspace with an API token.
- You can move a work item from your phone.
