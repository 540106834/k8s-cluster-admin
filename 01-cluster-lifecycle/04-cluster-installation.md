# Kubernetes 集群安装实战（kubeadm 生产版）

## 1\. 文档说明

### 1\.1 定位

本文为**生产级 kubeadm 集群标准化安装手册**，仅聚焦 kubeadm 部署方案，覆盖「系统基线初始化、容器运行时安装、kubeadm 组件部署、高可用集群初始化、节点接入、集群校验、生产优化」全流程。

所有步骤适配前文`cluster-planning.md` 生产规划规范，适配 **3Master\+N Worker 高可用架构**，适用于企业内网/裸金属/虚拟机生产环境。

云托管集群无需执行本文档（ACK/TKE/EKS 控制面由厂商托管），本文档仅适用于**自建 kubeadm 集群****、Harbor私有仓库离线生产环境**。

### 1\.2 集群架构约定

- 架构：3 Master 高可用 \+ VIP 负载均衡 \+ 多 Worker 节点

- Etcd：3 节点堆叠部署（与 Master 共节点，生产标准）

- 负载均衡：自研 VIP/硬件 LB/Keepalived 统一代理 apiserver

- 运行时：containerd（生产唯一推荐，废弃 docker）

- 网络插件：Calico v3\.29（离线YAML\+离线镜像，适配私有Harbor）

- 镜像体系：全组件基于**本地Harbor私有仓库**，无任何外网依赖

### 1\.3 环境前置约束（生产必做）

所有节点（Master\+Worker）统一执行前置初始化，**不一致会导致集群安装失败、运行异常**

- 操作系统：**Ubuntu 22\.04 LTS（生产主推，完美适配 K8s v1\.32）**

- 内核 ≥5\.4，推荐 5\.15\+

- 关闭 Swap、关闭 SELinux、时间同步、主机名唯一

- IP 网段、主机名严格遵循规划文档

- 所有节点互通、DNS 正常、无端口冲突

---

## 2\. 全节点系统基线初始化（所有节点统一执行）

### 2\.1 基础环境配置

关闭 SELinux

```bash
# Ubuntu22.04 关闭SELinux（默认未安装，仅兜底屏蔽）
sudo apt install -y selinux-utils
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config 2>/dev/null
```

永久关闭 Swap

```bash
# Ubuntu22.04 永久关闭Swap（生产强依赖）
sudo swapoff -a
sudo sed -i '/swap/s/^/#/' /etc/fstab

# 额外兜底：防止开机自动挂载swap
systemctl mask swap.target
```

加载内核模块

```bash
# Ubuntu22.04 加载K8s必需内核模块
sudo modprobe overlay
sudo modprobe br_netfilter

# 开机自动加载
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
```

### 2\.2 生产内核参数调优（K8s 必备）

新建 k8s 专属内核配置文件

```bash
# Ubuntu22.04 K8s生产内核参数
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.tcp_tw_reuse                = 1
net.core.somaxconn                   = 32768
fs.file-max                          = 1048576
EOF

sudo sysctl --system
```

### 2\.3 时间同步

```bash
# Ubuntu22.04 时间同步（生产必做）
sudo apt update && sudo apt install -y chrony
sudo systemctl enable --now chronyd
sudo timedatectl set-timezone Asia/Shanghai
```

---

## 3\. 容器运行时安装（containerd）

所有节点统一安装 containerd，适配 K8s CRI 标准

### 3\.1 安装 containerd

```bash
# ====================== 离线环境 containerd 安装（无外网） ======================
# 方式1：使用本地离线deb包安装（推荐纯离线机房）
# 方式2：对接内网Ubuntu离线源
sudo apt update
sudo apt install -y containerd.io

# 生成默认配置
sudo containerd config default | sudo tee /etc/containerd/config.toml
```

### 3\.2 生产关键配置修改

**开启 cgroup 驱动为 systemd（K8s 强制要求）**

```bash
# 1. 开启systemd cgroup（K8s v1.32强制）
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# 2. 【离线核心配置】对接内网Harbor私有仓库
# 替换为自己的Harbor域名/IP
HARBOR_DOMAIN="harbor.local.com"
sudo mkdir -p /etc/containerd/certs.d/${HARBOR_DOMAIN}

# 配置私有仓库信任、免外网、本地拉取
sudo tee /etc/containerd/certs.d/${HARBOR_DOMAIN}/host.toml > /dev/null <<EOF
[host."https://${HARBOR_DOMAIN}"]
  skip_verify = true
  capabilities = ["pull", "resolve"]
EOF
```

### 3\.3 重启生效

```bash
# 重启生效
sudo systemctl enable --now containerd
sudo systemctl restart containerd
```

---

## 4\. kubeadm/kubelet/kubectl 统一安装

### 4\.1 配置 K8s 官方源

统一版本、杜绝版本混杂，本文基线版本：**v1\.32\.x 社区最新稳定版（v1\.32\.13）**，适配 Ubuntu22\.04 离线生产环境。**全程无外网、全部依赖本地Harbor私有仓库\+本地APT离线源**。

```bash
# ====================== Ubuntu22.04 离线环境 K8s v1.32 安装说明 ======================
# 离线环境前置准备（运维提前完成）
# 1. 搭建本地/内网 Harbor 私有仓库（示例地址：harbor.local.com）
# 2. 在外网机器拉取所有K8s/Calico镜像，打包导入Harbor
# 3. 搭建Ubuntu22.04本地离线APT源，包含kubelet/kubeadm/kubectl依赖
# 4. 所有节点域名解析正常：harbor.local.com 指向内网HarborIP

# 离线环境无需外网GPG、无需外网apt源
# 直接安装本地离线包或同步内网离线源
sudo apt update
# 离线安装固定版本
sudo apt install -y kubelet=1.32.13-00 kubeadm=1.32.13-00 kubectl=1.32.13-00

# 锁定版本，生产禁止自动升级
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet
```

### 4\.2 版本锁定（生产必做，防止自动升级）

Ubuntu22\.04 使用 `apt-mark hold` 锁定版本，禁止系统自动更新 K8s 组件，保障集群版本稳定。

---

## 5\. 高可用集群初始化（Master 节点操作）

### 5\.1 初始化前置说明

- 仅在 **第一台 Master 节点** 执行 init 初始化

- 其余 Master、Worker 节点通过 join 加入集群

- VIP 为 apiserver 统一入口，提前配置 Keepalived 就绪

### 5\.2 kubeadm init 生产完整命令

严格匹配规划文档网段，**禁止随意修改网段**

```bash
# ====================== 【Harbor离线专属】kubeadm init 初始化 ======================
# 核心：--image-repository 指定内网Harbor仓库，不走外网阿里云
# 提前已将k8s.gcr.io镜像全部导入Harbor对应项目
HARBOR_REPO="harbor.local.com/k8s"

sudo kubeadm init \
--apiserver-advertise-address=0.0.0.0 \
--control-plane-endpoint=192.168.1.100 \
--kubernetes-version=v1.32.13 \
--service-cidr=10.96.0.0/16 \
--pod-network-cidr=10.244.0.0/16 \
--image-repository=${HARBOR_REPO} \
--upload-certs
```

参数说明：

- `--control-plane-endpoint`：集群 VIP 地址（高可用核心）

- `--upload-certs`：自动同步证书至其他 Master（多 Master 必备）

- 镜像仓库使用阿里云镜像，适配国内生产环境

### 5\.3 初始化成功后关键输出留存

保存 **master join 命令** 和 **worker join 命令**，后续节点接入使用

配置 kubectl 认证文件

```bash
# Ubuntu22.04 普通用户授权kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

## 6\. 安装网络插件 Calico（v1\.32 适配版）

集群初始化完成后，必须安装 CNI 否则节点处于 NotReady 状态

```bash
# ====================== 【完全离线】Calico v3.29 部署 ======================
# 前置：已将calico镜像全部上传至内网Harbor
# 1. 下载标准calico.yaml（外网机器一次下载，离线保存）
# 2. 全局替换镜像地址为私有Harbor
# 3. 拷贝至所有离线节点执行

# 替换示例（离线文件预处理命令）
# sed -i 's/docker.io/harbor.local.com/g' calico-v3.29-offline.yaml

# 离线部署
kubectl apply -f ./calico-v3.29-offline.yaml
```

校验网络 Pod 全部就绪

```bash
kubectl get pods -n kube-system
```

---

## 7\. 其余 Master 节点扩容加入（高可用补齐）

使用 init 输出的 **control\-plane join** 命令，在第二、第三台 Master 执行

```bash
# Ubuntu22.04 新增Master节点加入命令
sudo kubeadm join VIP:6443 --token xxx --discovery-token-ca-hash sha256:xxx --control-plane --certificate-key xxx
```

三台 Master 全部加入后，集群控制面高可用搭建完成

---

## 8\. Worker 节点加入集群

所有 Worker 节点执行节点基线、containerd、kube 组件安装后，执行 join 接入

```bash
# Ubuntu22.04 Worker节点加入集群
sudo kubeadm join VIP:6443 --token xxx --discovery-token-ca-hash sha256:xxx
```

Token 过期重新生成（生产常用）

```bash
# Ubuntu22.04 重新生成join命令
sudo kubeadm token create --print-join-command
```

---

## 9\. 集群安装后生产校验（必做）

```bash
# Ubuntu22.04 集群全量校验
kubectl get nodes
kubectl get cs
kubectl get pods -n kube-system
kubectl version
kubectl get svc
```

---

## 10\. 生产初始化优化（安装后必调）

### 10\.1 Master 节点污点隔离

确保控制面不跑业务 Pod（生产强制规范）

```bash
# Ubuntu22.04 Master节点污点隔离
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
```

确认污点生效，无业务 Pod 调度至 Master

### 10\.2 资源预留配置

参照 `cluster-planning.md` 配置 kubelet 资源预留，防止节点资源打满雪崩

---

## 11\. 安装常见故障排查（生产避坑）

- **节点 NotReady**：Ubuntu22\.04优先检查ufw防火墙、iptables转发、cgroup驱动、内核模块是否加载

- **kubelet 启动失败**：swap未彻底关闭、containerd配置未生效、系统未重启内核参数

- **join 失败**：token过期、时间不同步、Ubuntu默认ufw未放行节点通信

- **calico 启动失败**：离线YAML未替换镜像地址、Harbor无对应镜像、仓库证书未信任、版本不匹配（v1\.32必须≥v3\.28）

- **多 Master 证书异常**：初始化未加 \-\-upload\-certs，手动同步证书目录

**Ubuntu22\.04 \+ K8s v1\.32 离线强避坑**：1、所有节点containerd必须统一信任内网Harbor；2、全程禁用外网源、杜绝外网域名残留；3、离线YAML必须预处理替换为私有镜像；4、系统默认ufw防火墙需提前关闭，保证内网节点、Harbor互通

```bash
# 生产部署期间临时关闭ufw（集群稳定后可按需配置放行策略）
sudo ufw disable
```

---

## 12\. 云托管集群差异说明

**ACK/TKE/EKS 无需执行本文所有安装操作**

- 云托管集群控制面由厂商初始化，用户无需 kubeadm init、无需搭建高可用、无需维护证书与 etcd

- 云集群仅需维护 Worker 节点，节点接入由云平台自动完成

- 本文所有流程**仅适用于自建 kubeadm 集群**

---

## 13\. 安装落地验收标准

- 所有节点状态 Ready，无异常、无污点错误

- kube\-system 所有 Pod 正常 running，无 crashloop

- 3 台 Master 控制面组件正常，领导者选举生效

- VIP 可正常访问 apiserver，多 Master 负载均衡生效

- 网络互通正常，Pod 跨节点访问、Service 访问正常

- 系统基线、内核参数、swap、selinux 全部合规

## 14\. 离线环境前置镜像打包清单（Harbor导入必备）

在**有外网机器**提前拉取、打包、推送至内网Harbor，离线机房无任何外网依赖。

### 14\.1 K8s v1\.32 核心组件镜像清单

```bash
# kubeadm 默认镜像列表
kubeadm config images list --kubernetes-version=v1.32.13

# 批量拉取、打包、推送至Harbor示例
# 示例脚本可批量迁移至私有仓库

```

### 14\.2 Calico v3\.29 离线镜像清单

calico\-node、calico\-kube\-controllers、calico\-cni、calico\-pod2daemon\-flexvol 全套镜像，统一推送至Harbor私有项目。

## 15\. K8s v1\.32 离线专属避坑

- **仓库域名一致性**：containerd、kubeadm、Calico YAML 仓库地址必须与Harbor完全一致，否则镜像拉取失败

- **跳过证书校验**：内网Harbor自签名证书必须在containerd配置skip\_verify，v1\.32\+强制校验仓库合法性

- **版本强匹配**：离线Calico必须v3\.28\+/v3\.29，低版本不兼容v1\.32 API

- **禁止残留外网镜像**：离线YAML必须全局清理docker\.io/registry\.k8s\.io外网地址，否则集群启动异常

## 16\. v1\.32 版本生命周期说明

**版本生命周期提示**：Kubernetes v1\.32 社区已于 2026\-02\-28 停止维护（EOL），不再接收安全更新与漏洞修复。离线内网环境无自动补丁能力，建议严格固化版本、定期离线漏洞巡检、内网手动补丁更新。

**v1\.32 核心离线适配变更**

- 彻底废弃beta旧API，离线存量YAML需提前整改

- 强化容器运行时、仓库合法性校验，离线私有仓库必须标准化配置

- kubelet资源调度严格，离线集群需规范资源预留，避免内网集群资源雪崩

## 14\. K8s v1\.32 版本专属说明（生产必读）

**版本生命周期提示**：Kubernetes v1\.32 社区已于 2026\-02\-28 停止维护（EOL），不再接收安全更新与漏洞修复。生产长期稳定运行建议优先选择 **v1\.33/v1\.34 长期支持新版**；若业务强需 v1\.32，必须固定最新补丁版 v1\.32\.13，并严格做好集群漏洞巡检与基线加固。

**v1\.32 核心生产变更**

- 移除 FlowSchema、PriorityLevelConfiguration 资源的 v1beta3 旧 API，仅保留稳定 v1 版本

- StatefulSet 自动清理废弃 PVC 特性正式稳定，生产需注意存量存储数据兼容

- 强化 cgroup 校验、容器运行时校验，不标准的运行时配置会直接初始化失败

- kubelet 资源预留调度逻辑优化，对节点资源超配、碎片容忍度更低，需严格按规划配置预留值

> （注：部分内容可能由 AI 生成）
