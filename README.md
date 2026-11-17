# lab-platform
Shared Kubernetes platform: default gp3 storage, metrics-server, AWS Load Balancer Controller,
kube-prometheus-stack (Prometheus, Alertmanager, Grafana), alert rules, traffic generator.

```bash
export MY_IP_CIDR=<your ip>/32 GRAFANA_ADMIN_PASSWORD=... [SLACK_WEBHOOK_URL=...]
./install.sh
```
