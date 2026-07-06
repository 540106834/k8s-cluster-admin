#!/bin/bash
set -e

echo "===== 1. stop services ====="
systemctl stop kubelet || true
systemctl stop containerd || true

echo "===== 2. kubeadm reset ====="
kubeadm reset -f || true

echo "===== 3. remove kubernetes data ====="
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /var/lib/cni
rm -rf /etc/cni
rm -rf /opt/cni
rm -rf /var/run/kubernetes

echo "===== 4. remove kubelet leftovers ====="
rm -f /var/lib/kubelet/kubeadm-flags.env
rm -f /var/lib/kubelet/config.yaml

echo "===== 5. clean systemd kubelet overrides ====="
rm -f /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
systemctl daemon-reload

echo "===== 6. clean iptables (k8s rules) ====="
iptables -F || true
iptables -t nat -F || true
iptables -t mangle -F || true
iptables -X || true

echo "===== 7. restart container runtime ====="
systemctl restart containerd

echo "===== DONE ====="
echo "Node is now clean. Ready for kubeadm init."