# Worker 节点在线维护规范（node\-maintenance\.md）Ubuntu22\.04 \+ K8s v1\.32 离线生产版

## 1\. 文档概述

### 1\.1 文档定位

本文为 Kubernetes 集群 Worker 节点**在线运维、不停机维护、系统补丁、内核升级、故障修复、配置变更**标准化文档，完全适配 **Ubuntu 22\.04、K8s v1\.32、kubeadm 自建离线 Harbor 集群**。

区别于节点下线销毁，本文适用于**节点保留、仅做运维变更**的生产场景，统一维护流程、风险控制、变更规范、验收标准，保障集群运维零事故、业务无感知。

### 1\.2 适用场景

- 系统安全补丁更新、Ubuntu 内核小版本升级

- 节点内核参数、sysctl 配置优化变更

- containerd、kubelet 组件配置更新与重启

- 节点磁盘清理、资源优化、故障修复（网络/进程/挂载）

- 硬件运维、宿主机重启、机房巡检维护

- 节点基线修复、环境标准化整改

### 1\.3 核心维护原则

- **单台逐维维护**：禁止多节点同时维护，避免集群容错窗口击穿

- **先驱逐后变更**：生产节点变更必须先封锁驱逐，杜绝业务原地重启中断

- **变更可回滚**：所有配置修改、版本升级必须保留回滚方案

- **维护必验收**：变更完成校验节点、网络、业务三层状态

## 2\. 维护前置检查（生产强制）

所有节点维护操作执行前，必须完成以下检查，不达标禁止任何变更操作。

### 2\.1 集群健康度检查

```bash
# 节点状态全检
kubectl get nodes
# 系统组件健康检查
kubectl get pods -n kube-system
# 网络插件状态检查
kubectl get calicoapiserverconfigs -n kube-system
# 核心业务Pod状态检查
kubectl get pods --all-namespaces | grep -E "CrashLoopBackOff|Error|Pending"
```

集群存在节点异常、组件报错、Pod 异常时，禁止开展节点维护工作。

### 2\.2 业务高可用校验

- 确认待维护节点业务副本数 ≥2，集群其余节点可完整承接流量

- 排查节点内单副本、有状态、中间件、数据库业务，提前做好迁移或维护窗口报备

- 检查 PDB 中断预算，确保 Pod 可正常驱逐重建

- 核对业务监控 QPS、错误率、延迟，确认业务稳态无波动

### 2\.3 节点资源预检

```bash
# 查看节点资源负载
kubectl top node <node-name>
# 查看节点Pod分布
kubectl get pods -o wide | grep <node-name>
# 检查磁盘使用率、inode占用
df -h
df -i
```

## 3\. 标准维护通用流程（所有变更统一套用）

适用于所有节点配置变更、补丁升级、重启维护，是生产唯一标准流程。

### 3\.1 步骤1：节点封锁（禁止新调度）

```bash
kubectl cordon <node-name>
```

节点状态变为 SchedulingDisabled，停止新 Pod 调度，保障维护期间无新增业务负载。

### 3\.2 步骤2：业务平滑驱逐

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

自动迁移业务 Pod 至其他健康节点，仅保留 calico、kube\-proxy 等守护进程组件，实现业务无感知维护。

### 3\.3 步骤3：执行节点运维变更

根据实际维护场景执行对应操作：系统补丁、内核升级、配置修改、组件重启、磁盘清理、机器重启等。

### 3\.4 步骤4：等待节点自动恢复Ready状态

```bash
# 持续观察节点状态
watch kubectl get nodes
```

运维变更完成后，等待 kubelet、containerd、网络插件自动恢复，节点状态变为 Ready。

### 3\.5 步骤5：解除节点封锁，恢复调度

```bash
kubectl uncordon <node-name>
```

节点重新纳入集群调度池，可正常接收新业务 Pod。

### 3\.6 步骤6：全维度生产验收

验收节点状态、组件运行、网络连通、业务访问、监控指标，确认维护无任何业务影响。

## 4\. 高频维护场景专项操作

### 4\.1 系统补丁/内核升级维护

适配 Ubuntu22\.04 离线环境，仅更新系统安全补丁，不跨大版本升级内核。

```bash
# 离线更新系统补丁
apt update
apt upgrade -y

# 重启生效
reboot
```

内核/补丁升级必须严格遵循【封锁\-驱逐\-升级\-重启\-恢复】标准流程，禁止在线热更新。

### 4\.2 containerd 配置变更与重启

适用于 Harbor 私有仓库配置、cgroup 配置、镜像拉取参数调整场景。

```bash
# 修改配置后重启服务
systemctl daemon-reload
systemctl restart containerd

# 校验运行状态
systemctl status containerd
crictl info
```

### 4\.3 kubelet 配置更新维护

适用于资源预留、驱逐阈值、节点参数变更场景。

```bash
systemctl daemon-reload
systemctl restart kubelet
systemctl status kubelet
```

### 4\.4 节点磁盘清理运维

解决磁盘占用过高、镜像残留、日志堆积问题，无需下线节点，仅需封锁驱逐后清理。

```bash
# 清理无用容器镜像
crictl prune

# 清理系统日志
journalctl --vacuum-size=100M

# 清理kubelet残留日志
rm -rf /var/log/kubelet/*
```

## 5\. 故障节点紧急维护流程

针对节点 NotReady、kubelet 挂掉、网络异常、磁盘只读等突发故障，执行紧急维护修复。

### 5\.1 紧急修复原则

- 短期故障优先原地修复，无需下线节点

- 无法原地修复则立即执行驱逐下线，规避业务异常

- 修复完成后校验基线一致性，防止参数错乱

### 5\.2 常见故障快速修复

- **kubelet 异常退出**：检查日志、修复配置、重启 kubelet，异常持续则驱逐节点排查

- **containerd 卡死**：重启 containerd，清理僵死容器，校验 Harbor 仓库连通性

- **磁盘满导致节点异常**：紧急清理无用镜像、日志、临时文件，恢复节点状态

- **网络异常**：检查 CNI 配置、内核参数、防火墙规则，重启网络插件

## 6\. 批量节点维护规范

- **严格单台维护**：同一时间仅允许单台节点处于维护状态，禁止多台节点同时驱逐下线

- **跨AZ错开维护**：优先不同可用区间隔维护，杜绝单AZ整体故障

- **逐台验收闭环**：单台节点恢复调度、业务稳态后，再进行下一台节点维护

- **避开业务高峰**：批量补丁、内核升级统一在低峰维护窗口执行

## 7\. 维护后验收标准（必做）

### 7\.1 节点层验收

- 节点状态正常 Ready，无 SchedulingDisabled、NotReady 状态

- kubelet、containerd 服务正常运行，无重启报错

- 系统资源、磁盘、inode 负载正常，无持续升高趋势

### 7\.2 集群层验收

- kube\-system 所有组件 Pod 正常运行，无重启、报错

- Calico 网络插件状态正常，网络连通无异常

- 集群调度正常，无 Pending、异常 Pod

### 7\.3 业务层验收

- 业务 Pod 重建完成、运行正常，无 CrashLoop 重启

- 业务接口访问正常，QPS、错误率、延迟无波动

- 日志无报错、无超时、无连接异常信息

## 8\. 维护回滚机制

- **配置回滚**：所有变更操作前备份原配置文件，异常即刻还原基线配置

- **版本回滚**：补丁/组件升级异常，离线回退至原稳定版本

- **节点回滚**：维护后节点异常，立即封锁驱逐，下线替换备用节点

## 9\. 生产红线禁止规范

- 禁止未封锁、未驱逐节点，直接重启节点或重启核心组件

- 禁止集群异常、业务抖动期间执行任何节点维护变更

- 禁止多台节点同时维护，击穿集群容错阈值

- 禁止维护完成不做验收、不确认业务状态直接结束变更

- 禁止随意修改 kubelet、containerd 核心配置，无备份无回滚方案

- 禁止单副本核心业务无预处理、无迁移直接维护节点

## 10\. 关联文档

- 节点入网扩容：`node-join.md`

- 节点下线缩容：`node-remove.md`

- 节点日常管理：`worker-node-management.md`

- Kubeconfig 权限管理：`kubeconfig-management.md`

> （注：部分内容可能由 AI 生成）
