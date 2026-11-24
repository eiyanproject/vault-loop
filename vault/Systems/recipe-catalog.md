---
system: recipe-catalog
repo: eiyanproject/recipe-catalog
plane_project:
handover: README.md, DEPLOY-LXC.md
deploy: "Proxmox host: ./update-lxc.sh --ctid <ctid> --yes"
ctid:
node:
url:
working_copy: Documents\Claudecode\recipe-catalog
---

# recipe-catalog

Search over open recipe datasets (Food.com corpus). Postgres + FastAPI +
React (Vite). Fully local or free anonymous datasets only, no accounts. A new
dataset is a new adapter in `ingest/adapters/`, never a schema change.
`DEPLOY-LXC.md` uses CT 115 / `cookcatalog` in its examples; confirm the real
CTID before filling it in.
