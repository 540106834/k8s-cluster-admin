#!/bin/bash
set -e

K8S_VERSION="v1.32.13"

IMAGES=(
  "registry.k8s.io/kube-apiserver:${K8S_VERSION}"
  "registry.k8s.io/kube-controller-manager:${K8S_VERSION}"
  "registry.k8s.io/kube-scheduler:${K8S_VERSION}"
  "registry.k8s.io/kube-proxy:${K8S_VERSION}"
  "registry.k8s.io/coredns/coredns:v1.11.3"
  "registry.k8s.io/pause:3.10"
  "registry.k8s.io/etcd:3.5.24-0"
)

echo "Start pulling Kubernetes images for ${K8S_VERSION}"
echo "----------------------------------------------"

for img in "${IMAGES[@]}"; do
  echo "[PULL] $img"
  if docker pull "$img"; then
    echo "[OK]   $img"
  else
    echo "[FAIL] $img"
    exit 1
  fi
done

echo "----------------------------------------------"
echo "All images pulled successfully."