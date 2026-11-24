---
system: learnbox
repo: eiyanproject/learnbox
plane_project:
handover: README.md
deploy: "Proxmox host: bash update-lxc.sh --ctid 116 --yes (pulls main only)"
ctid: 116
node: eiyan2
url:
working_copy: Documents\Claudecode\learnbox
---

# learnbox

Python/Rust/networking/security/AWS learning platform with a real shell per
lesson. Go service + Vite/TypeScript UI. Rules: the repo's `CLAUDE.md`.
Verified work ships to `main`, because the update script only pulls `main`.
Gamification decisions: `docs/HANDOVER-gamification.md`.
