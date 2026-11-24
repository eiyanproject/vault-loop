---
system: homelab-monitoring
repo: eiyanproject/homelab-monitoring
plane_project:
handover: README.md, docs/DEPLOY.md
deploy: "Proxmox hosts: scripts in /srv/homelab-monitoring/scripts (see docs/DEPLOY.md)"
ctid: 200 (eiyan2, primary), 201 (eiyan, standby)
node: eiyan2, eiyan
url:
working_copy: Documents\Claudecode\homelab-monitoring
---

# homelab-monitoring

VictoriaMetrics + VictoriaLogs + vmagent + Grafana, one stack per node. New
services register with `scripts/register-service.sh`; the service contract is
`docs/SERVICE-CONTRACT.md`. PVE pushes InfluxDB line protocol (its OTLP is
JSON-only).
