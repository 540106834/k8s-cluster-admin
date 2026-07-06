# ETCD 数据备份与恢复规范（12\-etcd\-backup\.md）Ubuntu22\.04 离线生产版

## 1\. 文档概述

### 1\.1 文档定位

本文为 Kubernetes 生产集群 **ETCD 数据备份、定时快照、故障恢复、数据灾备、恢复演练** 标准化运维文档，适配 **Ubuntu22\.04、kubeadm 自建离线 Harbor 集群、K8s v1\.32**。ETCD 是 K8s 集群唯一数据源，存储所有集群资源、状态、配置数据，本文统一生产备份策略、恢复流程、自动任务、故障兜底，杜绝误删、数据损坏、集群瘫痪等灾难性事故。

### 1\.2 核心运维原则

- **备份常态化**：全自动定时快照\+人工变更前强制备份，双兜底机制

- **恢复可落地**：所有备份快照必须可恢复、可验证、可演练

- **就近留存\+异地备份**：本地快照留存\+跨节点异地拷贝，防止整机故障丢失数据

- **变更必备份**：集群重大变更（升级、证书续期、资源清理）前强制手动快照

- **过期自动清理**：避免磁盘爆满，自动化清理过期快照

### 1\.3 适用场景

- 集群日常周期性自动备份、快照留存与巡检

- 集群版本升级、证书续期、大规模资源变更前置备份

- 误删资源、误操作、集群数据错乱故障恢复

- ETCD 数据损坏、节点异常、集群瘫痪急救恢复

- 生产灾备演练、集群重建、环境复刻

## 2\. ETCD 生产核心认知

### 2\.1 数据核心价值

ETCD 为 Kubernetes 集群**唯一状态存储数据库**，保存全部核心数据：节点信息、Pod、Deployment、Service、Ingress、PV/PVC、配置、密钥、权限、状态记录。**ETCD 数据损坏/丢失 = 集群彻底瘫痪**，无法自愈，仅能通过备份恢复。

### 2\.2 集群 ETCD 部署模式

- kubeadm 高可用集群：**3 节点 ETCD 集群**，部署在 Master 节点

- 单 Master 集群：单节点 ETCD 实例，风险更高，必须严格执行备份策略

- 数据路径：默认 `/var/lib/etcd`

### 2\.3 备份工具说明

生产唯一标准工具：**etcdctl**，采用官方 **snapshot save** 快照备份，支持一致性时间点完整备份，杜绝增量错乱、数据不一致问题。

## 3\. 环境前置检查（备份前必做）

### 3\.1 获取 ETCD 连接证书与参数

kubeadm 集群 ETCD 为加密访问，必须指定证书参数，否则备份失败。

```bash
# 查看ETCD容器启动参数，确认证书路径
kubectl exec -n kube-system $(kubectl get pods -n kube-system | grep etcd | awk '{print $1}') -- ps aux | grep etcd

```

### 3\.2 生产固定 ETCD 环境变量（全局复用）

所有备份、恢复命令统一使用以下环境变量，保证参数一致：

```bash
export ETCDCTL_API=3
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/peer.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/peer.key
```

### 3\.3 集群健康预检

集群异常、ETCD 报错时禁止备份，避免产生无效快照。

```bash
# 检查etcd集群健康状态
etcdctl endpoint health

# 查看集群节点状态
etcdctl member list

```

## 4\. 手动快照备份（变更前置必执行）

集群升级、证书续期、大规模资源清理、配置变更**必须提前手动备份**。

### 4\.1 手动备份标准命令

```bash
# 创建备份目录
mkdir -p /data/etcd-backup

# 执行一致性快照备份
etcdctl snapshot save /data/etcd-backup/etcd-full-$(date +%Y%m%d-%H%M).db

```

### 4\.2 快照有效性校验

备份完成必须校验快照完整性，防止空备份、损坏备份。

```bash
# 校验快照合法性
etcdctl snapshot status /data/etcd-backup/etcd-full-$(date +%Y%m%d-%H%M).db

```

输出 BlockSize、Hash、Revision 正常即为有效备份。

## 5\. 全自动定时备份方案（生产常驻）

配置 crontab 定时任务，实现**每日自动快照 \+ 过期自动清理**，无人值守运维。

### 5\.1 自动备份脚本

路径：`/usr/local/bin/etcd-auto-backup.sh`

```bash
#!/bin/bash
export ETCDCTL_API=3
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/peer.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/peer.key

BACKUP_DIR=/data/etcd-backup
DATE=$(date +%Y%m%d-%H%M)
BACKUP_FILE=${BACKUP_DIR}/etcd-auto-${DATE}.db

# 目录不存在则创建
mkdir -p ${BACKUP_DIR}

# 执行快照备份
etcdctl snapshot save ${BACKUP_FILE}

# 校验备份有效性
etcdctl snapshot status ${BACKUP_FILE}

# 自动清理7天前旧备份
find ${BACKUP_DIR} -name "etcd-auto-*.db" -mtime +7 -delete

```

### 5\.2 授权与定时任务配置

```bash
# 赋予执行权限
chmod +x /usr/local/bin/etcd-auto-backup.sh

# 配置每日凌晨2点自动备份
crontab -e

# 添加内容
0 2 * * * /usr/local/bin/etcd-auto-backup.sh >> /var/log/etcd-backup.log 2>&1

```

### 5\.3 异地备份规范

为防止单节点磁盘故障丢失数据，每日将最新快照同步至其他 Master 节点或备份服务器，保证异地冗余。

## 6\. ETCD 故障标准恢复流程（生产急救）

适用于误删资源、数据错乱、ETCD 损坏、集群状态异常场景，**恢复操作需在变更窗口执行**。

### 6\.1 恢复前置准备

- 暂停集群所有变更操作、停止流水线发布

- 记录当前异常现象，选择故障前最新有效快照

- 备份当前损坏数据（用于回溯分析）

### 6\.2 停止集群 ETCD 相关组件

所有 Master 节点依次暂停 kubelet，停止 ETCD 集群调度

```bash
systemctl stop kubelet

```

### 6\.3 执行快照恢复

```bash
# 清空旧数据目录
rm -rf /var/lib/etcd/*

# 恢复指定快照
etcdctl snapshot restore /data/etcd-backup/有效快照文件.db \
--data-dir=/var/lib/etcd

```

### 6\.4 重启集群恢复服务

```bash
systemctl start kubelet

```

### 6\.5 集群恢复后验收

- ETCD 节点健康状态正常、member list 无异常

- 所有节点 Ready、系统组件 Running

- 业务资源、配置、状态完全恢复至快照时间点

## 7\. 备份巡检与日常运维规范

### 7\.1 每日巡检项

- 检查自动备份日志，确认每日快照生成成功

- 检查备份磁盘容量，避免磁盘占满

- 校验最新快照文件完整性

### 7\.2 月度灾备演练

每月选取一次低峰窗口，在测试环境执行快照恢复演练，验证备份可用性，杜绝“备份存在但无法恢复”的假性灾备。

## 8\. 生产红线禁止规范

- 禁止关闭自动备份任务、禁止随意删除历史快照

- 禁止集群重大变更不手动备份直接操作

- 禁止使用未校验的快照进行集群恢复

- 禁止集群运行异常、ETCD 不健康时执行备份与恢复

- 禁止长期无异地备份，单盘单点留存风险极高

- 禁止恢复操作不暂停业务、不停止变更，引发数据错乱

## 9\. 故障场景适配说明

- **误删 Namespace/核心资源**：立刻停止发布，使用最近快照恢复

- **集群证书异常、版本升级错乱**：回退至变更前快照

- **ETCD 节点宕机数据损坏**：清空损坏数据，快照重建集群状态

- **大规模配置改错**：秒级回退至历史稳定快照

## 10\. 关联文档

- 集群证书续期：`11-certificate-renewal.md`

- 集群版本升级：`kubernetes-upgrade.md`

- 节点在线维护：`node-maintenance.md`

> （注：部分内容可能由 AI 生成）
