# 01-os-init.md｜Ubuntu 22.04 全节点系统初始化+生产基线加固

## 一、文档基础信息

- **适配前置**：00-README.md 全局集群规范
- **适配系统**：Ubuntu 22.04 LTS x86_64
- **集群版本**：Kubernetes v1.32.13 / containerd v2.1.2 / Harbor v2.11.0
- **执行范围**：✅ k8s-master-01、✅ k8s-worker-01、✅ k8s-worker-02 **全部集群节点执行**；Harbor节点无需执行
- **下游依赖**：执行完成后跳转 02-containerd.md 部署容器运行时

## 二、全局集群节点信息（本章全局参数，禁止修改）

|主机名|IP地址|节点角色|
|---|---|---|
|k8s-master-01|192.168.11.161|K8s控制面节点|
|k8s-worker-01|192.168.11.162|K8s工作节点|
|k8s-worker-02|192.168.11.163|K8s工作节点|
|harbor.jinshaoyong.com|192.168.11.170|私有镜像仓库节点|

## 三、系统基础环境校验

所有节点执行，校验服务器基线达标

```bash
# 查看系统版本，确认 Ubuntu22.04
lsb_release -a
# 查看内核版本，推荐 ≥5.15
uname -r
# 校验CPU架构
arch
```

## 四、APT软件源优化（阿里云国内源，全节点执行）

### 4.1 备份默认源+替换阿里云源

```bash
# 备份原有系统源
cp /etc/apt/sources.list /etc/apt/sources.list.bak-$(date +%Y%m%d)

# 写入Ubuntu22.04 阿里云官方源
cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
EOF
```

### 4.2 更新系统依赖+安装K8s必备工具包

```bash
# 必须（Kubernetes 节点运行 / kubeadm 基础依赖）
apt update && apt install -y \
ca-certificates curl gnupg lsb-release \
iptables socat conntrack ipset \
chrony

# 扩展（运维工具 / 调试 / 便利性工具）
apt install -y \
telnet wget tree zip unzip \
vim openssh-server apt-transport-https
```

## 五、K8s强制前置配置（集群运行必要条件）

### 5.1 永久关闭Swap分区（K8s硬性强制要求）

```bash
# 临时关闭swap
swapoff -a
# 永久注释fstab开机挂载
sed -i '/swap/s/^/#/' /etc/fstab

# 结果校验：Swap total 为0
free -h
cat /etc/fstab | grep swap
```

### 5.2 加载容器网络内核模块（开机自启）

K8s+Calico网络必备内核模块：overlay、br_netfilter

```bash
# 配置开机自动加载
cat > /etc/modules-load.d/99-k8s-kernel.conf <<EOF
overlay
br_netfilter
EOF

# 实时加载内核模块
modprobe overlay
modprobe br_netfilter

# 校验模块加载成功
lsmod | grep -E "overlay|br_netfilter"
```

### 5.3 内核网络参数调优（生产集群专用）

```bash
# 写入集群专用sysctl参数
cat > /etc/sysctl.d/99-k8s-network-tune.conf <<EOF
# 网桥转发（K8s iptables转发核心参数）
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
# IPv4全局转发，容器跨网段通信必备
net.ipv4.ip_forward                 = 1
# 放大连接跟踪表，高并发Pod防丢包
net.netfilter.nf_conntrack_max      = 262144
# 关闭IPv6自动路由接收，规避网络异常
net.ipv6.conf.all.accept_ra         = 0
net.ipv6.conf.default.accept_ra     = 0
# 内存OOM优化
vm.overcommit_memory = 1
# TCP网络性能优化
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 0
EOF

# 全局生效所有内核参数
sysctl --system

# 核心参数校验，全部输出=1
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward
```

## 六、主机名配置+全局Hosts静态解析（全节点统一）

### 6.1 设置节点主机名（按节点单独执行）

```bash
# ---------- Master节点执行 ----------
hostnamectl set-hostname k8s-master-01

# ---------- Worker01节点执行 ----------
hostnamectl set-hostname k8s-worker-01

# ---------- Worker02节点执行 ----------
hostnamectl set-hostname k8s-worker-02
```

### 6.2 全节点统一写入hosts解析（全部三台节点执行）

解决集群节点域名互通、Harbor私有仓库域名解析问题

```bash
cat >> /etc/hosts <<EOF
192.168.11.161  k8s-master-01
192.168.11.162  k8s-worker-01
192.168.11.163  k8s-worker-02
192.168.11.170  harbor.jinshaoyong.com
EOF

# 校验解析结果
cat /etc/hosts
```

## 七、生产系统安全基线加固

### 7.1 关闭Ubuntu自带防火墙与Apparmor

集群内网无防火墙拦截，规避K8s节点、Pod通信失败

```bash
systemctl stop ufw && systemctl disable ufw
systemctl stop apparmor && systemctl disable apparmor
systemctl status ufw apparmor
```

### 7.2 SSH服务安全加固

```bash
# 禁止root账号远程登录
sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
# 关闭密码登录，生产环境仅密钥登录
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# 重启sshd生效
systemctl restart sshd
systemctl enable sshd
```

### 7.3 容器资源阈值调优（limits.conf）

解决容器文件句柄不足、进程数超限Pod启动失败问题

```bash
cat > /etc/security/limits.d/99-k8s-limits.conf <<EOF
root soft nofile 65535
root hard nofile 65535
root soft nproc unlimited
root hard nproc unlimited
* soft nofile 65535
* hard nofile 65535
* soft nproc unlimited
* hard nproc unlimited
EOF
```

## 八、集群时钟同步（强必要项）

K8s证书、日志、调度强依赖时钟对齐；全节点统一上海时区+chrony时间同步

```bash
# 设置上海时区
timedatectl set-timezone Asia/Shanghai

# 开机自启时钟同步
systemctl enable --now chronyd

# 校验同步状态
chronyc sources
chronyc tracking
```

## 九、初始化全维度验收清单（必须全部通过）

全部节点执行以下命令，确认初始化环境达标，才可进入下一步部署containerd

```bash
# 1. Swap分区全部关闭
free -h | grep Swap

# 2. 内核网络模块正常加载
lsmod | grep -E "overlay|br_netfilter"

# 3. 核心转发内核参数生效
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables

# 4. 系统时区+时间同步正常
timedatectl && chronyc tracking

# 5. 文件句柄阈值生效
ulimit -n && ulimit -u

# 6. 防火墙/Apparmor已关闭
systemctl status ufw apparmor

# 7. 节点&Harbor域名解析正常
ping -c 3 harbor.jinshaoyong.com
```

## 十、上下游文档关联

- 上游：00-README.md 集群全局规范
- 下游：✅ **02-containerd.md** 部署 containerd v2.1.2 容器运行时
- 故障定位：异常问题查阅 10-troubleshooting.md 系统初始化故障章节
