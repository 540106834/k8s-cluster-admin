# Kubernetes 集群证书续期规范（11\-certificate\-renewal\.md）Ubuntu22\.04 离线生产版

## 1\. 文档概述

### 1\.1 文档定位

本文为 Kubernetes 生产集群 **SSL 证书生命周期管理、到期检测、在线续期、过期急救、证书标准化运维** 专属规范文档，适配 **Ubuntu22\.04、kubeadm 自建离线 Harbor 集群、K8s v1\.32 版本**。统一生产集群证书巡检、续期流程、备份策略、异常处理机制，杜绝证书过期导致集群 apiserver 瘫痪、节点脱机、业务调度异常等重大生产事故。

### 1\.2 核心原则

- **在线无损续期**：生产集群证书续期全程不停机、不中断业务，依托kubeadm官方灰度续期机制

- **提前周期运维**：禁止证书临近过期或过期后处理，固定周期巡检、提前续期

- **备份优先原则**：任何证书操作前必须完整备份原有证书与配置，支持一键回滚

- **全节点统一更新**：Master控制面证书续期后，同步分发配置至所有Worker节点，保证集群证书一致性

- **闭环验收机制**：续期完成后全维度校验证书时效、集群状态、业务连通性

### 1\.3 适用场景

- K8s 集群各类证书到期检测、日常周期性巡检

- 集群证书在线手动续期、自动续期校验

- kubeconfig 客户端证书、组件通信证书更新

- 证书过期集群异常急救恢复

- 版本升级后证书重置、基线标准化梳理

## 2\. K8s 集群证书基础说明（生产必知）

### 2\.1 证书默认生命周期

kubeadm 初始化集群默认证书有效期为 **1 年**，v1\.32 版本延续社区生命周期规则，所有集群组件通信证书、客户端证书均有固定时效，到期后直接导致：节点 NotReady、kubectl 无法连接、Pod 调度失败、集群组件瘫痪。

### 2\.2 集群核心证书清单

所有证书存放路径：`/etc/kubernetes/pki/`

- **ca\.crt / ca\.key**：集群根证书（永久有效，默认不失效）

- **apiserver 系列证书**：apiserver\.crt、apiserver\-kubelet\-client\.crt 核心通信证书

- **front\-proxy 系列证书**：前端代理通信证书，用于集群审计、转发

- **etcd 系列证书**：etcd 数据库通信、加密证书，集群存储核心依赖

- **kubeconfig 客户端证书**：admin、kubelet、controller、scheduler 访问证书

## 3\. 证书到期巡检（日常运维标准）

生产集群固定每月执行证书巡检，提前预判过期时间，杜绝过期事故。

### 3\.1 批量查询所有证书过期时间

```bash
# 批量查看集群所有证书有效期
kubeadm certs check-expiration

```

输出字段说明：剩余有效期、是否可续期、证书类型，生产标准：**剩余有效期小于60天必须执行续期操作**。

### 3\.2 单独证书校验命令

```bash
# 查看单证书详细时效
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates

```

## 4\. 证书续期前置准备（生产强制）

### 4\.1 集群健康预检

集群异常、组件报错、业务抖动时，禁止执行证书续期操作

```bash
kubectl get nodes
kubectl get pods -n kube-system
kubectl get all --all-namespaces

```

### 4\.2 证书全量备份（不可省略）

续期前完整备份 pki 证书目录与 kubeconfig 配置，用于异常回滚

```bash
# 备份证书目录
cp -r /etc/kubernetes/pki /etc/kubernetes/pki-bak-$(date +%Y%m%d)

# 备份核心kubeconfig文件
cp -r /etc/kubernetes/*.kubeconfig /etc/kubernetes/bak-$(date +%Y%m%d)/

```

### 4\.3 环境基线确认

- 集群 kubeadm/kubelet 版本统一无混杂

- Harbor 离线环境组件正常，无镜像拉取异常

- 高可用集群逐台 Master 状态正常，无异常节点

## 5\. 在线证书续期标准流程（生产无损）

本流程适用于证书未过期、集群正常运行的生产场景，**全程业务无中断**。

### 5\.1 执行全局证书续期

```bash
# 续期所有集群短期证书，自动生成1年有效期新证书
kubeadm certs renew all

```

执行完成后，所有 apiserver、etcd、proxy、客户端证书全部刷新，有效期重置为1年。

### 5\.2 刷新管理员 kubeconfig 配置

```bash
# 重新生成admin配置
kubeadm kubeconfig user --client-name=admin --org=system:masters --kubeconfig=/etc/kubernetes/admin.conf

# 同步本地kubectl配置
cp /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

```

### 5\.3 重启集群核心组件生效

证书更新后需重启 kubelet 使新证书挂载生效，无需重启集群、无需停机

```bash
systemctl daemon-reload
systemctl restart kubelet

```

## 6\. 高可用集群多Master节点同步流程

多 Master 集群需**逐台更新证书与配置**，保证所有控制面节点证书一致

1. 在主 Master 节点执行完整续期流程（renew all、刷新配置、重启kubelet）

2. 将新生成的 `/etc/kubernetes/pki/` 证书目录同步至其他所有 Master 节点

3. 所有备 Master 节点依次执行：daemon\-reload \+ 重启 kubelet

4. 逐台校验节点状态、集群组件健康度

## 7\. Worker 节点证书同步更新

控制面证书续期完成后，所有 Worker 节点 kubelet 客户端证书同步失效，需统一更新，否则节点会逐步变为 NotReady。

### 7\.1 标准更新方案

```bash
# 1. 封锁节点避免业务震荡（单台逐台操作）
kubectl cordon <node-name>

# 2. 节点本地删除旧证书配置
rm -rf /var/lib/kubelet/pki/*

# 3. 重启kubelet自动拉取新证书
systemctl daemon-reload
systemctl restart kubelet

# 4. 等待节点Ready后解除封锁
kubectl uncordon <node-name>

```

严格遵循**单台逐台更新、逐台验收**原则，禁止批量重启所有Worker节点。

## 8\. 证书过期紧急急救方案（故障恢复）

针对证书已过期、集群无法访问、节点全部离线的极端生产故障。

### 8\.1 故障现象

- kubectl 命令报错：x509: certificate has expired

- 所有 Worker 节点 NotReady

- kube\-system 组件全部异常、集群无法调度

### 8\.2 急救恢复步骤

```bash
# 1. 强制续期所有过期证书
kubeadm certs renew all

# 2. 刷新全局kubeconfig
kubeadm kubeconfig user --client-name=admin --org=system:masters --kubeconfig=/etc/kubernetes/admin.conf

# 3. 重启控制面组件
systemctl daemon-reload
systemctl restart kubelet

# 4. 逐台重置Worker节点证书，恢复集群连通性
```

证书过期无需重装集群，通过官方 renew 命令可完整恢复集群能力。

## 9\. 续期后生产验收标准（必做）

### 9\.1 证书时效验收

```bash
# 确认所有证书有效期刷新正常
kubeadm certs check-expiration

```

### 9\.2 集群状态验收

- 所有 Master、Worker 节点状态全部 Ready

- kube\-system 所有组件 Pod 正常 Running，无重启、报错

- 集群 API 访问正常，kubectl 操作无证书报错

### 9\.3 业务层验收

- 所有业务 Pod 运行稳定，无批量重建、Crash 异常

- 业务接口、网络连通、存储挂载完全正常

- 监控指标、日志无证书认证、连接超时报错

## 10\. 生产红线与运维规范

- 禁止证书过期后再处理，固定每月巡检、提前60天续期

- 禁止无备份直接续期证书，无回滚兜底机制

- 禁止批量同时更新所有 Worker 节点证书，引发集群整体不可用

- 禁止集群异常、业务高峰期执行证书续期操作

- 禁止多 Master 集群单节点更新，不同步其他控制面节点证书

- 禁止续期完成后不做全维度验收，遗留隐性集群故障

## 11\. 日常运维周期规范

- **月度巡检**：执行证书过期检测，记录剩余有效期

- **季度续期**：临近60天有效期统一批量续期，纳入运维变更窗口

- **版本升级联动**：集群版本升级后强制巡检证书，同步刷新证书基线

## 12\. 关联文档

- 集群版本升级：`kubernetes-upgrade.md`

- 节点在线维护：`node-maintenance.md`

- 节点入网扩容：`node-join.md`

- 节点下线缩容：`node-remove.md`

> （注：部分内容可能由 AI 生成）
