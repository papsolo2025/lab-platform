#!/usr/bin/env bash
# Day 15: EFS StorageClass + a demo where pods in DIFFERENT Availability Zones share one volume.
# Run after `terraform apply` in lab-terraform/envs/extension.
set -euo pipefail
cd "$(dirname "$0")"
REGION="${AWS_REGION:-us-west-2}"

EFS_ID=$(aws efs describe-file-systems --region "$REGION" \
  --query "FileSystems[?Name=='devops-lab-shared'].FileSystemId | [0]" --output text)
[[ "$EFS_ID" == "None" || -z "$EFS_ID" ]] && { echo "EFS file system not found - apply envs/extension first"; exit 1; }
echo "==> EFS file system: $EFS_ID"

echo "==> Waiting for the EFS CSI driver"
kubectl -n kube-system rollout status deploy/efs-csi-controller --timeout=180s

echo "==> StorageClass 'efs' (dynamic provisioning: one EFS access point per PVC)"
sed "s/__EFS_ID__/$EFS_ID/" storageclass-efs.yaml | kubectl apply -f -

echo "==> Demo: 2 writers in different AZs + 1 reader, all on the same ReadWriteMany volume"
kubectl apply -f shared-files-demo.yaml
kubectl -n storage-demo rollout status deploy/writer --timeout=180s

echo
echo "Check it:"
echo "  kubectl -n storage-demo get pods -o wide            # writers on nodes in different zones"
echo "  kubectl -n storage-demo logs deploy/reader --tail=6  # lines from BOTH writers in one file"
echo "  kubectl get pvc -n storage-demo                     # RWX, storageClass efs"
