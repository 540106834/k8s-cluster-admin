#!/bin/bash
set -e

echo "========================"
echo " Kubernetes Node Init"
echo " Ubuntu 22.04"
echo "========================"

#######################################
# 1. Swap（必须关闭）
#######################################
echo "[1/7] Disable swap"

swapoff -a

# 幂等删除 swap 行
sed -ri.bak '/\sswap\s/s/^/#/' /etc/fstab

# systemd 屏蔽（可选增强）
systemctl mask swap.target 2>/dev/null || true


#######################################
# 2. 内核模块
#######################################
echo "[2/7] Load kernel modules"

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter


#######################################
# 3. sysctl 内核参数
#######################################
echo "[3/7] Set sysctl"

cat >/etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system


#######################################
# 4. 时间同步
#######################################
echo "[4/7] Time sync"

apt-get install -y chrony
systemctl enable chrony --now
timedatectl set-timezone Asia/Shanghai


#######################################
# 5. 基础工具
#######################################
echo "[5/7] Install base tools"

apt-get update
apt-get install -y \
  curl wget vim \
  net-tools \
  conntrack \
  ipvsadm \
  ipset \
  iptables \
  tcpdump \
  jq \
  socat \
  ethtool


#######################################
# 6. 禁用 Ubuntu 防火墙（仅开发/学习环境）
#######################################
echo "[6/7] Disable ufw"

systemctl disable ufw --now 2>/dev/null || true


#######################################
# 7. 验证
#######################################
echo "[7/7] Validation"

echo "Swap:"
swapon --show || true

echo "Kernel modules:"
lsmod | grep -E "overlay|br_netfilter" || true

echo "Sysctl:"
sysctl net.ipv4.ip_forward
sysctl net.bridge.bridge-nf-call-iptables

echo "DONE"