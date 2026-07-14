#!/bin/bash
set -e

echo "======================================"
echo " Kubernetes Admin Node Setup"
echo "======================================"

apt update

apt install -y \
    curl \
    wget \
    jq \
    tree \
    bash-completion \
    ca-certificates \
    gnupg

apt install -y \
    unzip \
    zip \
    rsync \
    tar

apt install -y \
    iproute2 \
    net-tools \
    dnsutils \
    tcpdump \
    traceroute \
    netcat-openbsd

apt install -y \
    iftop \
    iotop \
    ncdu \
    tmux

echo "Install yq..."

curl -fSL \
  http://192.168.11.100:8081/repository/sre-toolbox/binary/yq/v4.44.3/yq_linux_amd64 \
  -o /usr/local/bin/yq

chmod +x /usr/local/bin/yq

echo "Install kubectl v1.32.13..."

wget -O kubectl.deb https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.32/deb/amd64/kubectl_1.32.13-1.1_amd64.deb

dpkg -i kubectl.deb

echo "Install Helm v3.16.1 from Nexus..."

curl -fSL \
  http://192.168.11.100:8081/repository/sre-toolbox/binary/helm/v3.18.2/helm-linux-amd64 \
  -o /usr/local/bin/helm

chmod +x /usr/local/bin/helm

echo "Enable kubectl completion..."

kubectl completion bash > /etc/bash_completion.d/kubectl
source /etc/bash_completion.d/kubectl

EOF

echo "======================================"
echo " Installation Finished"
echo "======================================"

kubectl version --client

helm version

echo "Run: source ~/.bashrc"