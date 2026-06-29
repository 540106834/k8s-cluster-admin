# Kubeconfig 配置文件管理规范（自建 \+ 云平台 全覆盖）

## 1\. 文档概述

### 1\.1 文档定位

本文为 Kubernetes **kubeconfig 统一运维规范**，适用于 **kubeadm 自建集群**与 **ACK/TKE/EKS 云托管集群**。覆盖配置原理、文件结构、多集群合并、权限管控、分发规范、证书轮换、泄露应急处理，是集群权限安全与多集群管理的核心基准文档。

### 1\.2 核心作用

kubeconfig（通常为`~/.kube/config`）是 kubectl、客户端工具、控制器连接 K8s apiserver 的**唯一身份凭证**，用于定义：集群地址、CA 证书、用户身份、认证密钥、上下文环境。

### 1\.3 适用场景

- 运维机器、开发者本地客户端认证

- 多集群（测试/预发/生产）切换管理

- CI/CD 流水线、跳板机自动化权限配置

- 自建集群证书更新、kubeconfig 刷新

- 云平台集群临时凭证、子账号权限配置

- kubeconfig 泄露、权限过大等安全风险治理

---

## 2\. Kubeconfig 核心结构解析

所有 kubeconfig 文件统一由 **clusters、users、contexts** 三段结构组成，兼容自建与云集群。

### 2\.1 三大核心字段

- **clusters**：定义集群信息（apiserver 地址、CA 证书），可多个集群并存

- **users**：定义用户凭证（client 证书/密钥、token、用户名）

- **contexts**：绑定「集群\+用户\+命名空间」，实现一键切换环境

### 2\.2 标准最简结构示例

```yaml
apiVersion: v1
kind: Config
preferences: {}
current-context: k8s-prod

clusters:
- cluster:
    server: https://192.168.1.100:6443
    certificate-authority-data: xxx
  name: k8s-prod-cluster

users:
- user:
    client-certificate-data: xxx
    client-key-data: xxx
  name: k8s-prod-admin

contexts:
- context:
    cluster: k8s-prod-cluster
    user: k8s-prod-admin
    namespace: default
  name: k8s-prod

```

---

## 3\. 自建集群 Kubeconfig 管理（kubeadm）

### 3\.1 集群默认 kubeconfig

kubeadm 安装完成后，自动生成集群最高权限配置：

- 路径：`/etc/kubernetes/admin.conf`

- 权限：**集群超级管理员 cluster\-admin**

- 有效期：跟随集群 CA 证书（默认 10 年）

本地运维用户默认配置落地命令：

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

```

### 3\.2 自建集群自定义用户 kubeconfig

**生产禁止直接分发 admin\.conf**，必须基于 RBAC 新建低权限用户 kubeconfig。

核心流程：签发客户端证书 → 创建 RBAC 权限 → 生成独立 kubeconfig。

### 3\.3 自建集群证书更新与 kubeconfig 刷新

kubeadm 证书过期或更新后，`admin.conf` 会自动刷新，需重新同步至本地：

```bash
kubeadm certs renew all
cp /etc/kubernetes/admin.conf $HOME/.kube/config

```

---

## 4\. 云平台集群 Kubeconfig 管理（ACK/TKE/EKS）

### 4\.1 云集群 kubeconfig 特点（与自建核心差异）

- **无固定长期证书**：云厂商默认下发 **短期临时凭证**（12h/24h）

- 认证方式多为 **token/云账号鉴权**，非静态证书

- 权限与云平台 RAM/子账号/权限策略强绑定

- 控制面证书由厂商托管，用户无需维护证书轮换

### 4\.2 各云平台获取 kubeconfig 方式

#### 4\.2\.1 阿里云 ACK

```bash
# 安装 aliyun-cli 后刷新集群凭证
aliyun cs DescribeClusterKubeConfig --cluster-id cxxxxxx
# 自动写入本地 kubeconfig
aliyun cs GetKubeConfig --cluster-id cxxxxxx

```

ACK 默认凭证短期有效，支持配置**长期只读/指定权限 kubeconfig**。

#### 4\.2\.2 腾讯云 TKE

```bash
# tke-cli 自动刷新凭证
tke-cli config import --cluster-id cls-xxxxxx

```

#### 4\.2\.3 AWS EKS

```bash
aws eks update-kubeconfig --name cluster-name --region cn-north-1

```

### 4\.3 云平台长期 kubeconfig 配置（生产常用）

临时凭证不适合流水线、自动化场景，云平台可创建 **固定 ServiceAccount \+ 长期 Token kubeconfig**，实现永久有效、权限可控。

---

## 5\. 多集群 Kubeconfig 合并管理（生产核心）

运维环境普遍存在「测试/预发/生产、自建/云托管」多集群，支持单文件统一管理，无需切换配置文件。

### 5\.1 手动合并规则

- 合并所有 **clusters**、**users** 字段

- 定义独立 **contexts** 区分集群

- 通过 `current-context` 切换默认集群

### 5\.2 常用多集群操作命令

```bash
# 查看所有集群上下文
kubectl config get-contexts

# 切换集群
kubectl config use-context k8s-prod

# 重命名 context
kubectl config rename-context 旧名 新名

# 删除无效集群
kubectl config delete-cluster xxx
kubectl config delete-user xxx
```

---

## 6\. 生产权限规范（自建 \+ 云平台统一）

### 6\.1 强制禁止规范

- 禁止研发、流水线直接使用 **cluster\-admin 超级权限 kubeconfig**

- 禁止公网、代码仓库、Git 存储 kubeconfig 明文

- 禁止多环境共用同一个高权限 kubeconfig

- 禁止长期不轮换运维凭证

### 6\.2 权限分级标准

- **运维管理员**：集群级管理权限，仅跳板机留存

- **开发视图权限**：指定命名空间只读、查看日志

- **CI/CD 权限**：仅部署、重启，无删除集群资源权限

- **监控权限**：资源指标、事件只读

---

## 7\. 安全加固与生命周期管理

### 7\.1 文件权限加固（所有机器必做）

kubeconfig 属于核心密钥，必须严格限制本地权限：

```bash
chmod 600 ~/.kube/config
chown $USER:$USER ~/.kube/config

```

### 7\.2 凭证轮换策略

- **自建集群**：运维证书季度轮换、业务 SA Token 月度轮换

- **云集群**：默认短期凭证自动过期，长期 Token 按月重置

- 人员离职、权限变更 **立即作废对应 kubeconfig/Token**

### 7\.3 泄露应急处理

- 自建集群：重新签发 CA/客户端证书、作废旧证书、刷新所有 kubeconfig

- 云集群：禁用对应 RAM 子账号、删除旧 Token、刷新集群访问策略

- 排查集群操作审计日志，确认是否存在越权操作

---

## 8\. 常见故障排查

- **x509 证书过期**：自建集群证书过期，执行 `kubeadm certs renew all` 刷新配置

- **token 过期**：云平台临时凭证超时，重新 update\-kubeconfig

- **权限拒绝 Forbidden**：当前 context 权限不足，切换高权限账号或更新 RBAC

- **无法连接 apiserver**：集群地址错误、CA 证书不匹配、内网不通、防火墙拦截

- **多集群切换异常**：config 文件格式损坏、字段冲突，清空无效 clusters/users

---

## 9\. 落地验收标准

- 所有机器 kubeconfig 文件权限严格 600，无公开可读权限

- 生产环境无泛滥 cluster\-admin 凭证

- 多集群上下文命名规范、无无效残留配置

- 云平台短期凭证自动刷新、长期凭证权限最小化

- 具备完整的凭证轮换、泄露应急、权限回收流程

> （注：部分内容可能由 AI 生成）
