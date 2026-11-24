---
system: portfolio
repo: eiyanproject/portfolio
plane_project:
handover: README.md
deploy: "GitHub Actions (.github/workflows/deploy.yml)"
ctid:
node: OCI micro (ap-tokyo-1)
url: https://eiyanproject.com
working_copy: Documents\Claudecode\portfolio
---

# portfolio

The public site for eiyanproject.com: Astro, static, on an OCI Always Free
micro behind a Cloudflare Tunnel. Ports 80/443 stay closed on the box; adding a
hostname takes DNS + a cloudflared ingress rule + a Caddy site block.
