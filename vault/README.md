# vault/ - seed files for the loop's Obsidian vault

Copy these into the vault the loop watches (the one Syncthing shares through
CT 107). Nothing in the vault is overwritten by the loop; these are starting
points you own once copied.

```
vault/Templates/   note templates: CHANGE, PROJECT, INCIDENT, IDEA
vault/Systems/     the systems registry: one note per system the loop may change
```

## Templates

Turn on Obsidian's core **Templates** plugin and point its template folder at
`Templates`. Then *Insert template* in a new note in `Inbox/`.

Every template has the same frontmatter the triage step reads:

| Key | Meaning |
|---|---|
| `type` | `change`, `project`, `incident` or `idea` |
| `status` | `draft` while you write; **`ready`** hands it to the loop. Triage only picks up `ready` notes |
| `system` | a `Systems/` note name for a change or incident; blank for a new project or an idea |

## Systems registry

One note per system. The loop matches a CHANGE note to a system by `system:`
(or by asking you when it can't tell), then works only in that system's repo.
A new system gets its entry here once it is built.

| Key | Meaning |
|---|---|
| `repo` | GitHub `owner/name` |
| `plane_project` | the Plane project identifier, e.g. `LRN` - fill in after creating the project |
| `handover` | the context doc the agent reads first, path inside the repo |
| `deploy` | the command that ships a change, and where it runs |
| `ctid` / `node` / `url` | where it runs |

This repo is public, so it only holds entries for public repos, and leaves
their LAN addresses blank. Entries for private systems live in
`vault/Systems/private/`, which git ignores: they stay on the PC that made
them. Copy them into the vault the same way.

Blank means not known yet - fill it in rather than guessing. Facts here were
taken from each repo and its notes on 24 Nov 2026; the repo wins when they
disagree.
