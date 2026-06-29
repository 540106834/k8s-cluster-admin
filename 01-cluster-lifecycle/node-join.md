# Worker 节点入网扩容规范（node\-join\.md）Ubuntu22\.04 \+ K8s v1\.32 离线生产版

## 1\. 文档概述

### 1\.1 文档定位

本文为 **Kubernetes 集群 Worker 节点入网、扩容、新增节点接入标准运维文档**，适配 **Ubuntu 22\.04**、**K8s v1\.32 稳定版**、**kubeadm 自建离线集群（Harbor 私有仓库）**。

统一新节点入网基线、环境初始化、运行时配置、kube 组件安装、集群接入、入网校验全流程，用于生产集群横向扩容、节点替换、灾备节点新增，为生产唯一入网标准。

### 1\.2 适用范围

- 生产集群新增 Worker 节点入网

- 故障节点替换、扩容节点接入集群

- 离线机房、无外网环境节点入网

- 统一基线标准化批量扩容场景

### 1\.3 前置依赖

- 集群已完成初始化（`cluster-installation.md`）

- 内网 Harbor 私有仓库正常可用

- 节点主机名唯一、IP 规划合规、内网互通正常

## 2\. 入网前置基线（所有新节点强制执行）

本节为**节点入网必须初始化基线**，不达标禁止 join 集群，否则会出现 NotReady、网络异常、kubelet 启动失败等问题。

### 2\.1 基础环境初始化

```bash
# 关闭 SELinux
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config

# 永久关闭 Swap
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab

# 加载内核模块
modprobe overlay
modprobe br_netfilter

```

### 2\.2 生产内核参数（v1\.32 强制）

```bash
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.tcp_tw_reuse                = 1
net.core.somaxconn                   = 32768
fs.file-max                          = 1048576
EOF

sysctl --system

```

### 2\.3 时间同步与防火墙

```bash
# 安装时间同步
apt install -y chrony
systemctl enable --now chronyd

# 关闭 ufw（Ubuntu22.04 默认开启，集群节点必须关闭）
systemctl stop ufw
systemctl disable ufw

```

## 3\. 离线 containerd 安装 \+ Harbor 私有仓库配置

适配纯离线环境，所有镜像从内网 Harbor 拉取，无任何外网依赖。

### 3\.1 安装 containerd

```bash
apt update
apt install -y containerd.io

# 生成默认配置
containerd config default > /etc/containerd/config.toml

```

### 3\.2 关键配置修改（v1\.32 必改）

```bash
# 开启 systemd cgroup
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# 配置内网 Harbor 免证书校验
HARBOR_DOMAIN="harbor.local.com"
mkdir -p /etc/containerd/certs.d/${HARBOR_DOMAIN}

cat > /etc/containerd/certs.d/${HARBOR_DOMAIN}/host.toml <<EOF
[host."https://${HARBOR_DOMAIN}"]
  skip_verify = true
  capabilities = ["pull", "resolve"]
EOF

# 重启生效
systemctl enable --now containerd
systemctl restart containerd

```

## 4\. 离线安装 kubeadm / kubelet / kubectl v1\.32\.13

离线环境依赖内网 apt 源或本地 deb 包，禁止外网源。

```bash
apt update
# 固定生产稳定版 v1.32.13
apt install -y kubelet=1.32.13-00 kubeadm=1.32.13-00 kubectl=1.32.13-00

# 锁定版本，禁止自动升级
apt-mark hold kubelet kubeadm kubectl

# kubelet 开机自启
systemctl enable kubelet

```

## 5\. 节点入网 join 操作（核心步骤）

### 5\.1 获取集群入网命令（Master 节点执行）

若原有 token 过期，在任意 Master 节点重新生成永久入网命令：

```bash
kubeadm token create --print-join-command

```

### 5\.2 Worker 节点执行入网

在待入网 Worker 节点执行输出的 join 命令，示例如下：

```bash
kubeadm join 192.168.1.100:6443 --token xxxxx \
--discovery-token-ca-hash sha256:xxxxxx

```

### 5\.3 入网成功标志

- 提示 `This node has joined the cluster`

- 无报错、无证书超时、无网络连通异常

## 6\. 入网后标准化配置

### 6\.1 同步 kubeconfig（可选）

如需在该节点使用 kubectl，同步 master config：

```bash
mkdir -p $HOME/.kube
scp root@master1:/etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

```

### 6\.2 节点业务标签与分层（生产必做）

新节点入网后必须立刻打标签，归属业务池，防止调度混乱。

```bash
# 环境标签
kubectl label nodes new-node-01 env=prod
# 业务类型标签
kubectl label nodes new-node-01 node-type=normal
# 可用区标签
kubectl label nodes new-node-01 az=az1

```

### 6\.3 资源预留生效确认

参照 `worker-node-management.md` 核对 kubelet 资源预留、驱逐阈值配置，确保新节点与存量节点基线完全一致。

## 7\. 入网结果生产验收（必须逐项校验）

```bash
# 1. 查看节点状态，必须为 Ready
kubectl get nodes

# 2. 查看节点详细信息，无污点异常、状态正常
kubectl describe node 新节点名

# 3. 查看系统 Pod 无异常重启
kubectl get pods -n kube-system

# 4. 检查节点资源上报正常
kubectl top node

```

**验收标准**：

- 节点状态 Ready，无 NotReady、无 SchedulingDisabled

- kube\-proxy、calico 网络 Pod 正常运行

- 节点标签、分层归属正确

- 资源预留、系统参数基线合规

## 8\. 入网常见故障与排错（v1\.32 专属）

### 8\.1 join 失败：证书/Token 过期

重新在 master 生成 token 即可：`kubeadm token create --print-join-command`

### 8\.2 节点入网后 NotReady

优先排查：

- swap 是否彻底关闭

- containerd systemd cgroup 是否开启

- Harbor 镜像是否完整，calico 镜像是否拉取成功

- 节点防火墙是否未关闭，端口不通

### 8\.3 kubelet 启动失败（v1\.32 高频）

v1\.32 强校验运行时，99% 原因为：**cgroup 模式不匹配**或 **swap 未关闭干净**。

### 8\.4 离线环境镜像拉取失败

检查 containerd 仓库配置、Harbor 域名解析、私有仓库镜像完整性。

## 9\. 生产红线规范

- 禁止基线不完整的节点入网生产集群

- 禁止新节点不打业务标签直接承载流量

- 禁止新节点未完成验收直接投入生产

- 禁止新旧节点基线不一致，导致调度异常、资源抢占

## 10\. 关联文档

- 节点日常管理：`worker-node-management.md`

- 节点下线缩容：`node-remove.md`

- 节点维护操作：`node-maintenance.md`

- 集群离线安装：`cluster-installation.md`

> （注：部分内容可能由 AI 生成）
