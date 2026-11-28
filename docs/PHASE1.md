# Phase 1: inbox vault, registry and Plane setup

Configuration only. At the end, every system you'd want changed has a registry
row and a Plane project, and you can move a work item from your phone.

## 1. Decisions

| Decision | Chosen |
|---|---|
| Approval on every change ticket? | Yes: nothing codes without an **Approved** Plane item |
| Daily job cap and quiet hours | Not enforced yet; the worker (Phase 3) will read them, from Claude Code's own usage-limit figures |
| New systems' repos | Created by Claude Code on the PC with its existing `gh` login, when you approve the roadmap. No separate token |
| Remote access | LAN, Tailscale, and public hostnames behind Cloudflare Access (`docs/N8N.md`, `docs/PLANE.md`) |
| Inbox | **One** existing vault the loop watches, using that vault's own note types (below) |
| Agent and your notes | It may edit existing notes to keep them true after a change, listing each edited note in the PR. A new note in your vaults stays your call |

## 2. The inbox vault

The loop watches **one** vault (the one Syncthing shares through the hub). It
does not need its own `Inbox/` folder or templates if the vault already files
work by type. A vault that does, with frontmatter like this:

```yaml
type: improvement        # error, improvement, housekeeping, idea, ...
status: open
priority: should         # urgent, core, should, nice
systems: [learnbox]      # which system(s) the work is for
```

is used as it is. Map its folders to routes:

| Folder (`type`) | Route |
|---|---|
| errors (`error`) | incident: change on each system in `systems:` |
| improvements (`improvement`), housekeeping (`housekeeping`) | change on each system in `systems:` |
| wishlist (`idea`) | new system, or a feature of one named in `systems:` |
| discussions, plans, fixes, templates | never picked up |

Add the loop's statuses to the vault's own list: **`ready`** (you set it -
this hands the note to the loop), then `queued`, `in-progress`, `in-review`
(the agent sets these), ending in the vault's own `fixed` / `done`. Only
`ready` starts anything. The agent writes `plane:` and `pr:` into the
frontmatter and keeps a short `## Loop` section in the note, so the vault alone
shows where a ticket is.

`priority:` becomes the Plane priority: urgent → Urgent, core → High,
should → Medium, nice → Low. A note with several `systems:` becomes one Plane
item per system, linked.

A vault with no types of its own can start from the generic templates in
`vault/Templates/` (`vault/README.md`).

## 3. The registry

A table in the inbox vault, one row per system: its repo(s) and its Plane
project identifier. A new system is a new row. It lives in the vault, not in
this repo, so private repo names are fine there. Each system's own vault (if
it has one) is what the agent reads to orient, and updates after a change.

`vault/Systems/` here is the older one-note-per-system form of the same thing,
kept as an example.

## 4. Plane: workspace, projects, states, labels

Layout and the reasons for it: `docs/PLANE.md`. In the Plane web UI:

1. **One workspace** (an existing one is fine).
2. **One project per registry row**, with a short identifier (`LRN`, `MON`,
   `VNC` ...). Write it into the registry.
3. **States, the same in every project** (*Project settings → States*):
   `Proposed`, `Approved`, `Agent working`, `In review`, `Done`, `Needs you`.
   The names matter: n8n queues a coding job when an item's state is named
   exactly **Approved**.
4. **Labels**, the same in every project: `change`, `project`, `incident`,
   `small`.
5. **A bot account for the agent.** Invite a second Plane user (for example
   `loop-bot`) to the workspace only, as a member. Sign in as it once and
   create its **API token** (*Profile settings → API tokens*, or *Workspace
   settings → API tokens* depending on the Plane version). Keep the token for
   Phase 3; the PC worker uses it.

**Check:** on your phone, open Plane, open any project, and move a test work
item between two states.

## Done when

- Every registry row has a repo (or is marked planned) and a Plane project
  with the six states.
- The inbox vault's status list has `ready`, `queued`, `in-progress`,
  `in-review`.
- The bot account exists in the workspace with an API token.
- You can move a work item from your phone.
