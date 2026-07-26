# backup-etcd-cluster.md

## ETCD 集群定时备份、快照恢复、灾备完整运维手册

## 一、文档定位

ETCD 是 K8s 集群唯一持久化存储，保存全部集群资源、配置、密钥、RBAC、状态数据；一旦损坏丢失集群完全瘫痪，无法恢复业务。
本文覆盖**定时自动备份、手动快照、备份校验、快照恢复、跨集群迁移、清理过期备份、故障应急恢复**全套流程，适配 3/5 Master 高可用 ETCD 集群；是集群交付、日常运维、灾备演练强制落地规范。
前置依赖：build-kubernetes-cluster.md、validate-cluster-health.md
下游关联：replace-worker-node.md、expand-worker-nodes.md

## 二、核心前置基础

### 2.1 关键前提约束

1. ETCD 版本兼容性：快照仅可恢复至**同主版本** ETCD（etcd 3.4 快照不能直接恢复到 3.5）
2. 高可用集群备份规则：仅需在**任意一台 Master 节点**执行备份，无需所有节点同时备份
3. 备份不可存放集群本地磁盘，必须同步至独立远端存储（对象存储/异地服务器）
4. 备份前必须校验集群整体健康，集群异常时禁止生成快照

### 2.2 集群证书路径（标准 kubeadm 部署）

默认证书路径（所有Master节点统一）

```bash
# CA根证书
/etc/kubernetes/pki/etcd/ca.crt
# 客户端证书
/etc/kubernetes/pki/etcd/healthcheck-client.crt
/etc/kubernetes/pki/etcd/healthcheck-client.key
# ETCD 本地监听地址
https://127.0.0.1:2379
```

### 2.3 环境变量（备份脚本统一引用）

```bash
cat << 'EOF' >> ~/.bashrc
# ETCDCTL 默认连接配置
export ETCDCTL_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
export ETCDCTL_CERT="/etc/kubernetes/pki/etcd/server.crt"
export ETCDCTL_KEY="/etc/kubernetes/pki/etcd/server.key"
export ETCDCTL_ENDPOINTS="https://127.0.0.1:2379"
EOF
source .bashrc
```

## 三、ETCD 集群健康预检查（备份前置步骤，强制执行）

每次自动/手动备份前，先校验集群无故障，避免损坏快照：
```bash
# 1. 集群所有节点健康检测
etcdctl endpoint health
root@k8s-master-192-168-122-100:~# etcdctl endpoint health
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 49.77839ms

# 2. 查看集群成员，无失联节点
etcdctl member list
root@k8s-master-192-168-122-100:~# etcdctl member list
4b2b60f9e30f8da1, started, k8s-master-192-168-122-100, https://192.168.122.100:2380, https://192.168.122.100:2379, false
# 节点 ID: 4b2b60f9e30f8da1
# 节点名称: k8s-master-192-168-122-100
# Peer 地址: [https://192.168.122.100:2380](https://192.168.122.100:2380)（节点间通信）
# Client 地址: [https://192.168.122.100:2379](https://192.168.122.100:2379)（客户端访问）
# 是否是 Learner: false（常规投票成员）

# 3. 清除所有告警（磁盘满、碎片、节点断开告警必须提前处理）
etcdctl alarm list
etcdctl alarm disarm
```

**校验失败阻断备份规则**：

1. 存在节点 `unhealthy` → 停止备份，先修复集群
2. 存在空间/碎片告警 → 清理磁盘、碎片整理后再备份
3. 磁盘使用率 >85% → 扩容磁盘再备份

## 四、手动单次快照备份（应急/交付验收使用）

### 4.1 本地快照生成命令

```bash
#!/bin/bash
# 创建备份存储目录
mkdir -p /data/etcd-backup/snapshot

# 生成带时间戳快照文件
SNAP_NAME=etcd-snapshot-$(date +%Y%m%d_%H%M).db
etcdctl snapshot save /data/etcd-backup/snapshot/$SNAP_NAME
```

### 4.2 快照完整性校验（必做）
快照生成后立即校验文件可用，防止损坏备份：
```bash
etcdctl snapshot status /data/etcd-backup/snapshot/$SNAP_NAME
```
输出关键字段校验：
- hash、revision、total-key-count 存在数值，无报错
- 文件大小不为0，无文件损坏提示

### 4.3 远端同步备份（防止节点磁盘损坏丢失）
示例：同步至远端备份服务器 / 阿里云OSS/MinIO 对象存储
```bash
# rsync同步异地备份服务器
rsync -avz /data/etcd-backup/snapshot root@backup-server:/k8s-etcd-backup/cluster01/

# MinIO上传示例（需提前安装mc客户端）
mc cp /data/etcd-backup/snapshot/$SNAP_NAME minio/etcd-backup/cluster01/
```

## 五、定时自动备份生产脚本（标准落地）
### 5.1 完整备份脚本 /opt/etcd-backup/etcd-backup.sh
```bash
#!/bin/bash

# ==================== 配置区域 ====================
# 基础路径与名称
BACKUP_DIR="/data/backup/etcd"
DATE_TAG=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="etcd-snapshot-${DATE_TAG}.db"
LOCAL_FILE="${BACKUP_DIR}/${BACKUP_NAME}"

# MinIO 配置
MINIO_ALIAS="minio"
MINIO_BUCKET="k8s-backups"
MINIO_PATH="${MINIO_ALIAS}/${MINIO_BUCKET}/etcd"

# 保留天数（本地和 MinIO 超过这个天数的备份会被清理）
RETENTION_DAYS=7

# etcdctl 认证配置（可直接复用你前面配好的环境变量）
export ETCDCTL_API=3
export ETCDCTL_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
export ETCDCTL_CERT="/etc/kubernetes/pki/etcd/server.crt"
export ETCDCTL_KEY="/etc/kubernetes/pki/etcd/server.key"
export ETCDCTL_ENDPOINTS="https://127.0.0.1:2379"
# ==================================================

# 创建本地备份目录
mkdir -p "${BACKUP_DIR}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始执行 etcd 快照备份..."

# 1. 执行 etcd 快照
etcdctl snapshot save "${LOCAL_FILE}"
if [ $? -ne 0 ]; then
    echo "[ERROR] etcd 快照备份失败！"
    exit 1
fi
echo "[SUCCESS] 快照已成功保存至: ${LOCAL_FILE}"

# 2. 验证快照完整性
echo "[INFO] 正在验证快照完整性..."
etcdctl -w table snapshot status "${LOCAL_FILE}"
if [ $? -ne 0 ]; then
    echo "[ERROR] etcd 快照文件损坏或验证不通过！"
    rm -f "${LOCAL_FILE}"
    exit 1
fi

# 3. 上传到 MinIO
echo "[INFO] 正在上传快照到 MinIO (${MINIO_PATH})..."
mc cp "${LOCAL_FILE}" "${MINIO_PATH}/"
if [ $? -ne 0 ]; then
    echo "[ERROR] 上传至 MinIO 失败！"
    exit 1
fi
echo "[SUCCESS] 成功上传至 MinIO 目标桶。"

# 4. 清理本地超过指定天数的旧备份
echo "[INFO] 清理本地 ${RETENTION_DAYS} 天前的旧备份..."
find "${BACKUP_DIR}" -name "etcd-snapshot-*.db" -mtime +${RETENTION_DAYS} -exec rm -f {} \;

# 5. 清理 MinIO 上超过指定天数的旧备份（利用 mc rm）
echo "[INFO] 清理 MinIO 上 ${RETENTION_DAYS} 天前的旧备份..."
mc find "${MINIO_PATH}" --older-than "${RETENTION_DAYS}d" --exec "mc rm {}"

# 6. 记录备份成功日志
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] 备份成功: $SNAP_FILE" >> /data/etcd-backup/backup-success.log
```

### 5.2 脚本授权与定时任务配置
```bash
# 赋予执行权限
chmod +x /opt/etcd-backup/etcd-backup.sh

# 配置crontab 每日凌晨2点自动备份
crontab -e
# 写入定时规则
0 2 * * * /bin/bash /opt/etcd-backup/etcd-backup.sh >> /data/etcd-backup/cron-backup.log 2>&1
```

### 5.3 备份保留策略（企业标准）
1. 本地节点：保留7天每日全量快照
2. 异地远端存储：保留30天每日快照，每月留存1份月度长期快照
3. 月度长期快照禁止自动清理，手动归档至归档存储

## 六、快照恢复完整流程（集群数据丢失/损坏应急灾备）
### 前置说明
集群彻底损坏（所有ETCD数据目录丢失、数据库损坏、误删集群资源）使用快照恢复；
恢复会覆盖全部集群数据，**恢复前导出当前故障快照留存故障现场**。

### 步骤1：停止所有Master节点ETCD静态Pod
所有Master节点执行，关闭etcd服务：
```bash
mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.bak
# 确认etcd容器全部停止
crictl ps | grep etcd
```

### 步骤2：清空原有损坏ETCD数据目录（所有Master）
```bash
# 默认etcd数据目录（kubeadm部署）
ETCD_DATA=/var/lib/etcd
mv $ETCD_DATA $ETCD_DATA.bak-broken
mkdir -p $ETCD_DATA
```

### 步骤3：在任意Master节点将快照恢复至本地数据目录
```bash
# 选择可用快照文件
SNAP=/data/etcd-backup/snapshot/etcd-snapshot-20250101_0200.db

# 快照恢复，指定集群初始集群配置（3节点示例）
etcdctl snapshot restore $SNAP \
--name=etcd-master-0 \
--data-dir=/var/lib/etcd \
--initial-cluster=etcd-master-0=https://192.168.1.10:2380,etcd-master-1=https://192.168.1.11:2380,etcd-master-2=https://192.168.1.12:2380 \
--initial-cluster-token=etcd-cluster-0 \
--initial-advertise-peer-urls=https://192.168.1.10:2380
```
参数说明：
- --name 当前执行恢复的节点etcd名称（与manifest内名称一致）
- initial-cluster 完整集群三个节点对等通信地址
- initial-advertise-peer-urls 当前节点peer监听地址

### 步骤4：同步恢复后数据目录至另外两台Master节点
将恢复完成的`/var/lib/etcd`目录完整同步至其余所有Master节点，三台节点数据目录完全一致。

### 步骤5：恢复etcd静态Pod，启动集群
所有节点恢复manifest文件：
```bash
mv /etc/kubernetes/manifests/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
```

### 步骤6：校验集群恢复完成
等待etcd容器重建启动，执行健康检查：
```bash
etcdctl endpoint health
kubectl get nodes,deployments --all-namespaces
```
校验集群资源、配置、CRD、PV/PVC全部恢复至快照时间点状态。

## 七、跨集群快照迁移（新集群从旧集群恢复全量数据）
1. 保证新旧集群ETCD大版本完全一致
2. 在新集群全部停止etcd，清空数据目录
3. 使用旧集群快照执行snapshot restore，修改initial-cluster为新集群节点IP
4. 同步数据目录至所有新Master节点，启动etcd完成迁移

## 八、备份运维监控与告警
### 8.1 备份失败告警监控
监控日志文件`/data/etcd-backup/backup-error.log`，文件存在则触发钉钉/短信告警。
### 8.2 备份磁盘空间监控
监控`/data/etcd-backup`磁盘使用率，阈值80%触发告警，及时扩容或清理过期快照。
### 8.3 远端同步失败监控
定时检测远端备份服务器快照文件，若当日快照缺失则告警。

## 九、生产高频故障与规避方案
### 1. 快照文件损坏，无法恢复
根因：备份时集群不健康、磁盘IO故障、快照生成未执行snapshot status校验
规避：脚本强制前置健康校验+快照完整性校验，异常直接终止备份并告警

### 2. 备份仅存在本地节点，磁盘损坏全部丢失
根因：未同步至异地/对象存储
规范：每次备份完成强制rsync/上传至远端独立存储

### 3. 跨版本快照恢复失败
根因：ETCD大版本不兼容
规范：升级ETCD前先完成全量快照备份；快照仅用于同版本集群恢复

### 4. 定时备份磁盘打满节点崩溃
根因：未配置自动清理过期快照
规范：脚本自动删除7天前本地快照，远端分层归档留存

### 5. 恢复集群后节点无法加入集群
根因：restore时initial-cluster、peer地址参数填写错误
规范：提前固化集群节点peer地址模板，恢复脚本预填参数

## 十、落地运维规范
1. 仅在一台Master节点部署定时备份任务，避免多节点重复备份占用IO
2. 所有快照必须双存储：本地临时留存+异地远端长期归档
3. 每周执行一次**灾备演练**，随机选取快照在测试集群完成恢复验证备份可用
4. 集群版本升级前，手动执行一次全量快照备份并归档长期保存
5. 禁止将备份存放于集群同一台宿主机，杜绝单点磁盘故障丢失备份
6. 备份脚本输出完整日志，异常错误持续告警，杜绝静默备份失败

## 十一、关联文档索引
build-kubernetes-cluster.md kubeadm集群部署ETCD配置
validate-cluster-health.md 集群交付ETCD健康校验标准
replace-worker-node.md 故障节点替换集群数据校验
expand-worker-nodes.md 节点扩容后ETCD集群状态检查