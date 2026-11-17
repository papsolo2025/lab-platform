#!/usr/bin/env bash
# Installs the shared Kubernetes platform: storage, autoscaling metrics, ALB ingress, monitoring, alerts.
# Safe to re-run (helm upgrade --install). Run from your laptop after `terraform apply`.
#
# Required env vars:
#   MY_IP_CIDR               e.g. 203.0.113.10/32   (who may reach the ALB)
#   GRAFANA_ADMIN_PASSWORD   choose a strong password
# Optional:
#   SLACK_WEBHOOK_URL        Slack incoming webhook for Alertmanager
set -euo pipefail
cd "$(dirname "$0")"

: "${MY_IP_CIDR:?export MY_IP_CIDR=<your ip>/32}"
: "${GRAFANA_ADMIN_PASSWORD:?export GRAFANA_ADMIN_PASSWORD=...}"
REGION="${AWS_REGION:-us-west-2}"
CLUSTER="${CLUSTER_NAME:-devops-lab}"

# Pinned chart versions - upgrading them is a monthly exercise.
LBC_CHART_VERSION="3.6.3"
KPS_CHART_VERSION="93.3.1"
METRICS_SERVER_CHART_VERSION="3.14.0"

echo "==> kubeconfig"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)

echo "==> Helm repositories"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null

echo "==> Namespaces and default gp3 StorageClass"
kubectl apply -f manifests/namespaces.yaml
kubectl apply -f manifests/storageclass-gp3.yaml

echo "==> metrics-server (needed by HPA and kubectl top)"
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system --version "$METRICS_SERVER_CHART_VERSION" --wait

echo "==> AWS Load Balancer Controller (IAM via EKS Pod Identity, created by Terraform)"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system --version "$LBC_CHART_VERSION" \
  --set clusterName="$CLUSTER" --set region="$REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --wait

echo "==> Scrape targets for the EC2 servers (node_exporter on :9100)"
TARGETS_FILE=$(mktemp)
trap 'rm -f "$TARGETS_FILE" "${SLACK_FILE:-}"' EXIT
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=devops-lab" "Name=tag:Monitoring,Values=true" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ip:PrivateIpAddress,name:Tags[?Key==`Name`]|[0].Value,role:Tags[?Key==`Role`]|[0].Value}' \
  --output json | jq '{prometheus: {prometheusSpec: {additionalScrapeConfigs: [{
      job_name: "ec2-node-exporter",
      static_configs: [ .[] | {targets: ["\(.ip):9100"], labels: {name: .name, role: .role}} ]
    }]}}}' > "$TARGETS_FILE"
echo "    $(jq '.prometheus.prometheusSpec.additionalScrapeConfigs[0].static_configs | length' "$TARGETS_FILE") EC2 targets"

EXTRA_VALUES=(-f "$TARGETS_FILE")
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  SLACK_FILE=$(mktemp)
  # Only substitute the webhook variable; Alertmanager's own {{ }} templates are left alone.
  envsubst '$SLACK_WEBHOOK_URL' < values/alertmanager-slack.yaml > "$SLACK_FILE"
  EXTRA_VALUES+=(-f "$SLACK_FILE")
  echo "    Slack alerting enabled"
fi

echo "==> kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace --version "$KPS_CHART_VERSION" \
  -f values/kube-prometheus-stack.yaml "${EXTRA_VALUES[@]}" \
  --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD" \
  --set-string grafana.ingress.annotations."alb\.ingress\.kubernetes\.io/inbound-cidrs"="$MY_IP_CIDR" \
  --wait --timeout 10m

echo "==> Alert rules"
kubectl apply -f alerts/

echo "==> Traffic generator (gives Prometheus real data for SLOs)"
kubectl apply -f manifests/loadgen.yaml

echo
echo "Done. The ALB takes 2-3 minutes to appear:"
echo "  kubectl get ingress -A"
echo "  Grafana: http://<ALB address>/grafana   user: admin"
