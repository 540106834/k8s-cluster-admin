# docs/03-storage/01-storage-design.md
# kube-prometheus-stack 持久化存储整体设计方案
## 文档基础信息
- K8s集群：v1.32
- Chart版本：kube-prometheus-stack-65.1.0
- 存储底座：NFS 服务端 + 集群统一 StorageClass `nfs-sc`
- 交付模式：离线MinIO Chart + Git配置管控
- 文档等级：★★★★★ 核心存储设计文档
- 前置阅读：02-deployment/02-configuration.md、02-deployment/01-installation.md

## 目录
1. 存储整体架构总览
2. 存储分层与数据生命周期
3. 三大有状态组件PVC规格规划（Prometheus/Alertmanager/Grafana）
4. NFS StorageClass 标准化配置
5. TSDB 存储调优（保留周期、容量上限、压缩、分片）
6. 数据读写权限、目录结构说明
7. 存储扩容标准操作流程
8. 存储备份与快照策略
9. 存储故障边界与风险规避
10. 配套关联文档索引

---

# 1. 存储整体架构总览
## 1.1 分层架构
```
业务Pod/Exporter指标 → Prometheus TSDB(NFS持久)
告警事件/静默配置 → Alertmanager状态存储(NFS持久)
Grafana面板/账号/数据源配置 → Grafana持久卷(NFS持久)
底层统一存储供给：NFS服务端共享目录 + K8s StorageClass nfs-sc
```
## 1.2 设计约束（强制落地）
1. 所有持久数据**统一NFS存储**，禁止使用hostPath、本地磁盘临时存储；
2. 所有PVC动态由`nfs-sc`供给，不手动创建PV；
3. 区分时序数据、告警元数据、可视化配置三类数据，隔离PVC；
4. 容量规划按业务峰值预分配，杜绝运行中PVC频繁扩容；
5. 离线环境无云存储快照能力，依赖NFS层文件备份。

## 1.3 无持久化组件说明
node-exporter、kube-state-metrics、prometheus-operator均为内存运行，无持久化PVC，不占用NFS空间。

---

# 2. 存储分层与数据生命周期
## 2.1 Prometheus TSDB（核心大容量时序层）
- 数据类型：全集群指标采样数据（容器、节点、中间件、业务API）
- 写入逻辑：每30s抓取一次，本地内存缓存后落盘NFS
- 生命周期：配置`retention=15d`，超期数据自动删除；同时配置容量硬上限`retentionSize`，磁盘满优先删旧数据
- 数据分片：TSDB按2h分块，旧块自动压缩节省NFS空间

## 2.2 Alertmanager 状态存储（轻量元数据层）
- 数据类型：告警静默记录、通知发送状态、告警分组缓存
- 生命周期：无过期清理规则，长期留存，数据量级GB级，容量需求极低

## 2.3 Grafana 配置存储（可视化配置层）
- 数据类型：用户账号、权限、数据源连接、自定义大盘、告警通知渠道配置
- 生命周期：永久存储，修改即持久化；大盘模板优先Git管控，PVC仅存运行时修改内容

---

# 3. 三大有状态组件PVC规格规划（生产标准）
## 3.1 Prometheus PVC（HA双副本独立PVC）
```yaml
prometheus:
  prometheusSpec:
    replicas: 2
    storageSpec:
      volumeClaimTemplate:
        storageClassName: nfs-sc
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 500Gi
```
- 单副本500Gi，双副本总计1TB NFS空间；
- 访问模式RWO：NFS后端锁定，避免多Pod同时读写损坏TSDB；
- 适用场景：上千节点、数百业务Pod全量指标采集；
- 小集群/uat环境可下调至200Gi，保留周期7天。

## 3.2 Alertmanager PVC
```yaml
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        storageClassName: nfs-sc
        resources:
          requests:
            storage: 20Gi
```
- 固定20Gi，冗余充足，实际占用通常<5Gi；
- 仅存储告警状态，无海量时序写入。

## 3.3 Grafana PVC
```yaml
grafana:
  persistence:
    enabled: true
    storageClassName: nfs-sc
    size: 30Gi
```
- 30Gi用于存储用户配置、自定义面板缓存；
- 大盘模板通过Git ConfigMap注入，不占用PVC大量空间。

## 3.4 集群PVC标签统一规范
所有PVC自动注入统一标签，便于NFS存储分层统计：
```yaml
metadata:
  labels:
    platform: monitor
    storage-type: prometheus-tsdb/alert-state/grafana-config
```

---

# 4. NFS StorageClass 标准化配置（集群全局预置）
## 4.1 nfs-sc 完整YAML定义
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-sc
provisioner: kubernetes.io/nfs-subdir-external-provisioner
parameters:
  nfs.server: 192.168.10.100  # NFS服务端IP
  nfs.path: /export/monitor    # 监控专属NFS根目录
  storageClass.beta.kubernetes.io/fsId: "1000"
reclaimPolicy: Retain  # PVC删除后PV保留，防止误删时序数据
allowVolumeExpansion: true  # 支持在线PVC扩容
volumeBindingMode: Immediate
```
## 4.2 关键参数说明
1. `reclaimPolicy: Retain`：核心安全策略，删除监控release不会清理NFS时序数据，避免数据丢失；
2. `allowVolumeExpansion: true`：支持PVC在线扩容，无需重建Pod；
3. 独立NFS根目录`/export/monitor`：与日志、中间件存储物理隔离，IO互不争抢；
4. NFS服务端权限：目录UID/GID=1000，匹配容器运行用户，避免读写Permission Denied。

## 4.3 NFS服务端目录自动分层逻辑
nfs-subdir-external-provisioner自动为每个PVC创建独立子目录，隔离数据：
```
/export/monitor/
├── prometheus-monitor-kube-monitor-prometheus-0-pvc-xxx
├── prometheus-monitor-kube-monitor-prometheus-1-pvc-xxx
├── alertmanager-monitor-kube-monitor-alertmanager-0-pvc-xxx
└── grafana-monitor-kube-monitor-grafana-pvc-xxx
```
每个组件数据独立目录，扩容、备份、清理互不干扰。

---

# 5. TSDB 存储调优参数（values配置落地）
## 5.1 基础生命周期控制（生产标准）
```yaml
prometheus:
  prometheusSpec:
    retention: 15d          # 时间维度过期删除
    retentionSize: "450GB"  # 容量硬上限，优先触发容量清理
    walCompression: true    # WAL预写日志压缩，降低NFS IO压力
    blocksCompression: zstd # 历史数据块高压缩算法
```
## 5.2 IO 性能调优参数
```yaml
    tsdb:
      minBlockDuration: 2h
      maxBlockDuration: 2h
      retentionBlockDuration: 15d
      headChunksWriteBuffer: 104857600 # 100MB内存写入缓冲，减少NFS频繁刷盘
```
## 5.3 采集频率配套存储适配
- scrapeInterval=30s：标准生产采样，存储压力适中；
- 若业务开启10s高频采集，PVC容量需翻倍至1TB/副本，保留周期缩短至7d。

## 5.4 容量水位预警阈值
内置告警规则监控PVC使用率：
- 80%：低危，规划扩容窗口；
- 90%：高危，立即执行PVC扩容；
- 95%：紧急，TSDB触发强制删旧数据，指标丢失风险。

---

# 6. 数据读写权限、容器目录结构
## 6.1 Prometheus 容器挂载目录
```
/mnt/prometheus/
├── wal/        # 预写日志，实时写入NFS
├── blocks/     # 压缩时序数据块
├── chunks_head/# 当前2小时热数据块
└── lock        # TSDB锁文件，RWO模式防止双写损坏
```
运行用户：65534(nobody)，NFS目录授权nobody读写。

## 6.2 Alertmanager 容器挂载目录
```
/mnt/alertmanager/
└── silences.json # 告警静默持久文件
```

## 6.3 Grafana 容器挂载目录
```
/var/lib/grafana/
├── grafana.db    # SQLite本地数据库（账号、数据源、面板配置）
├── plugins/
└── dashboards/
```

## 6.4 权限故障典型场景
NFS目录UID不匹配 → Pod启动报错`permission denied opening storage`；
解决方案：NFS服务端执行`chown -R 1000:1000 /export/monitor`。

---

# 7. 存储扩容标准操作流程
## 7.1 前置校验
1. 监控PVC使用率告警确认水位≥80%；
2. NFS服务端磁盘剩余空间充足；
3. 确认StorageClass开启`allowVolumeExpansion: true`。

## 7.2 修改values配置扩容
修改`values-prod.yaml`中prometheus PVC存储请求，从500Gi扩容至1TB：
```yaml
resources:
  requests:
    storage: 1Ti
```

## 7.3 下发配置生效
```bash
helm upgrade kube-monitor /opt/monitor-chart/kube-prometheus-stack \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml
```
## 7.4 扩容生效验证
1. 查看PVC状态变为`FileSystemResizePending`；
2. 进入Prometheus Pod，执行`df -h /mnt/prometheus`确认容量更新；
3. TSDB写入正常，无报错日志。

> 无需删除Pod，NFS支持在线文件系统扩容，采集无中断。

---

# 8. 存储备份与快照策略
## 8.1 定时全量备份（NFS层脚本）
每日凌晨2点执行，保留7天备份：
```bash
# NFS服务端定时任务 crontab
0 2 * * * /opt/script/monitor-nfs-backup.sh
```
脚本逻辑：
1. 停止Prometheus Pod，冻结TSDB写入；
2. tar压缩对应PVC独立目录；
3. 备份文件迁移至异地备份存储；
4. 重启Prometheus Pod，恢复指标采集。

## 8.2 应急快照备份（变更前手动执行）
升级、存储配置修改前，手动对NFS目录打压缩包，参考02-deployment/03-upgrade.md升级备份流程。

## 8.3 备份恢复流程
1. 清空故障PVC目录；
2. 解压备份压缩包至对应NFS子目录；
3. 校验目录权限；
4. 重启对应StatefulSet Pod，加载历史时序数据。

---

# 9. 存储故障边界与风险规避
## 9.1 风险1：NFS服务端宕机/断连
现象：Prometheus日志报`context deadline exceeded`，指标无法落盘；
规避：NFS服务端做高可用主备；监控NFS挂载状态告警；
临时降级：Prometheus内存缓存短期写入，NFS恢复后自动落盘。

## 9.2 风险2：PVC容量打满
现象：retentionSize触发，自动删除最早时序数据；
规避：配置PVC使用率告警，80%水位提前扩容；
应急：临时下调retention保留周期释放空间。

## 9.3 风险3：多Pod同时读写TSDB
规避：StorageClass访问模式强制RWO，HA双副本独立PVC，互不挂载。

## 9.4 风险4：PVC误删除丢失数据
规避：StorageClass `reclaimPolicy: Retain`；删除release前先备份NFS目录；禁止批量清理monitor命名空间PV/PVC。

## 9.5 风险5：NFS IO延迟过高导致抓取丢失
规避：监控NFS磁盘iowait指标；监控Prometheus `prometheus_tsdb_wal_fsync_duration_seconds` 延迟告警；NFS监控目录与业务日志目录物理磁盘隔离。

---

# 10. 配套关联文档索引
1. Chart存储配置落地：02-deployment/02-configuration.md
2. 离线安装PVC创建流程：02-deployment/01-installation.md
3. Helm升级存储备份操作：02-deployment/03-upgrade.md
4. 存储故障排查：09-troubleshooting/03-pvc-error.md
5. 集群资源容量规划标准：10-best-practices/01-resource-planning.md
6. 监控告警规则配置：05-prometheus-operator/03-prometheusrule.md