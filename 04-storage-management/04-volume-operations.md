# 04-volume-operations.md
## 一、文档基础信息
- 归属目录：`04-storage-management/`
- 前置阅读：`00-README.md`、`03-storageclass.md`、`02-persistent-volume-claim.md`
- 集群基准：Kubernetes v1.32.13、CSI存储驱动、支持扩容/快照/克隆、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：PVC在线扩容完整流程、PV快照备份、卷克隆、存储卷生命周期、StatefulSet缩容PVC保留机制、分环境操作规范、扩容/快照故障排查

## 二、存储卷高级能力底层前提
### 2.1 功能前置条件
1. StorageClass 必须开启 `allowVolumeExpansion: true` 才能在线扩容；
2. CSI驱动完整实现快照/克隆接口（通用本地Local CSI仅支持扩容，分布式存储支持快照克隆）；
3. 文件系统支持在线扩容（ext4/xfs，数据库标准文件系统）；
4. 集群RBAC放开快照、扩容资源操作权限。

### 2.2 卷生命周期总流程
1. PVC创建 → CSI自动生成PV；
2. 业务运行，按需在线扩容；
3. 定时创建VolumeSnapshot快照备份；
4. 故障可通过快照克隆新PVC恢复数据；
5. 缩容/删除负载：仅删除Pod，PVC/PV保留（Retain策略）；
6. 人工确认数据无需留存，手动删除PVC释放存储。

### 2.3 能力区分
| 能力 | Local SSD CSI | 分布式共享CSI |
|------|---------------|---------------|
| PVC在线扩容 | ✅ 支持 | ✅ 支持 |
| VolumeSnapshot快照 | ❌ 不支持 | ✅ 支持 |
| 卷克隆Snapshot | ❌ 不支持 | ✅ 支持 |

## 三、PVC 在线扩容完整操作流程（生产标准）
### 3.1 前置校验
1. StorageClass `allowVolumeExpansion: true`；
2. 存储池有充足空闲磁盘；
3. 业务低峰窗口执行扩容操作；
4. 扩容前完成数据库全量备份+etcd快照。

### 3.2 PVC标准模板（扩容前）
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-data-pvc
  namespace: prod
spec:
  storageClassName: local-ssd-prod
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi
```

### 3.3 扩容步骤
1. 修改yaml `requests.storage` 上调容量（50Gi → 100Gi）
```yaml
resources:
  requests:
    storage: 100Gi
```
2. 应用更新：
```bash
kubectl apply -f pvc-mysql-prod.yaml -n prod
```
3. 观测PVC扩容状态：
```bash
kubectl get pvc mysql-data-pvc -n prod -w
```
4. 状态变为`FileSystemResizePending` → 等待Pod自动重启扩容文件系统；
5. Pod重建完成后进入容器验证磁盘容量：
```bash
kubectl exec -it mysql-0 -n prod -- df -h /var/lib/mysql
```

### 3.4 StatefulSet扩容存量PVC说明
volumeClaimTemplates仅控制**新扩容Pod**PVC容量；存量Pod原有PVC不会自动扩容，需单独对每个PVC执行扩容操作。

## 四、VolumeSnapshot 快照备份（分布式存储专用）
### 4.1 快照CR模板
```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: mysql-snap-20260707
  namespace: prod
spec:
  volumeSnapshotClassName: dist-snap-class
  source:
    persistentVolumeClaimName: mysql-data-pvc
```
### 4.2 快照运维命令
```bash
# 创建快照
kubectl apply -f snap-mysql.yaml -n prod

# 查看快照列表、就绪状态
kubectl get volumesnapshots -n prod

# 查看快照创建事件
kubectl describe volumesnapshot mysql-snap-20260707 -n prod

# 删除过期快照（释放存储空间）
kubectl delete volumesnapshot mysql-snap-old -n prod
```

## 五、快照克隆恢复（故障数据回滚）
从快照直接生成全新PVC，用于故障恢复、UAT数据复制：
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restore-mysql-pvc
  namespace: prod
spec:
  storageClassName: dist-storage-prod
  dataSource:
    name: mysql-snap-20260707
    kind: VolumeSnapshot
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Gi
```
流程：创建克隆PVC → 绑定新PV，数据完全还原快照时点，不破坏原业务PVC。

## 六、StatefulSet 缩容 PVC 保留机制核心说明
1. StatefulSet执行缩容仅销毁对应序号Pod，**不会自动删除PVC/PV**；
2. PV回收策略`Retain`，删除STS资源依旧保留全部PVC；
3. 重建同序号Pod自动复用原有PVC，数据不丢失；
4. 若需彻底销毁数据，必须人工逐个删除PVC；
### 生产强约束
禁止批量删除数据库PVC，删除前校验快照/备份存在。

## 七、DEV/FAT/UAT/PROD 差异化存储操作规范
| 环境 | 在线扩容 | 快照/克隆 | PVC缩容保留 | 操作审批 |
|------|----------|-----------|-------------|----------|
| DEV本地 | 无CSI扩容能力 | 不支持 | 无PVC | 无需审批 |
| FAT测试 | 可自由扩容 | 可临时创建快照调试 | 缩容后可批量清理PVC | 无需审批 |
| UAT预生产 | 对齐生产扩容流程 | 支持快照克隆，仿真数据迁移 | Retain保留PVC | 导出备份即可操作 |
| PROD生产（强约束） | 仅业务低峰扩容，双人复核 | 定时自动快照，禁止高频手动快照 | 永久保留PVC，人工审核才可删除 | 双人复核+etcd快照备份 |

### PROD硬性规则
1. 数据库扩容避开业务高峰，提前HPA扩容分担流量；
2. 中间件StatefulSet分批扩容PVC，避免同时重建多Pod；
3. 核心数据库每日自动快照，保留7天快照用于故障回滚；
4. 快照占用存储计入存储池容量，定期清理过期快照释放空间。

## 八、存储卷标准运维操作合集
### 1. PVC扩容核心命令
```bash
# 应用扩容后的PVC配置
kubectl apply -f pvc-mysql-prod.yaml -n prod

# 观测扩容进度
kubectl get pvc -n prod -w

# 查看扩容事件、文件系统resize状态
kubectl describe pvc mysql-data-pvc -n prod
```

### 2. 快照与克隆管理
```bash
# 手动创建快照
kubectl apply -f snap-mysql.yaml -n prod

# 从快照克隆新PVC恢复数据
kubectl apply -f pvc-restore-from-snap.yaml -n prod

# 批量清理过期快照
kubectl delete volumesnapshots -n prod --field-selector status.readyToUse=false
```

### 3. StatefulSet缩容后PVC清理
```bash
# 仅删除STS，保留PVC
kubectl delete sts mysql -n prod
# 人工确认无数据后再删除PVC
kubectl delete pvc mysql-data-mysql-0 -n prod
```

## 九、高频存储卷操作故障排查
### 1. PVC扩容报错 Forbidden
StorageClass未开启`allowVolumeExpansion: true`，修改SC开启扩容开关。

### 2. PVC扩容成功，但Pod磁盘容量不变
文件系统未自动resize，重启Pod触发CSI重新挂载扩容文件系统；或手动进入容器执行resize2fs/xfs_growfs。

### 3. 创建VolumeSnapshot失败
1. Local CSI不支持快照，仅分布式存储可用；
2. 快照StorageClass未配置、快照容量超出存储池上限。

### 4. 快照克隆PVC Pending
快照损坏、存储池无空闲容量、accessModes不匹配快照源PVC。

### 5. StatefulSet缩容后PVC丢失
人工手动删除PVC，缩容操作本身不会清理PVC，Retain策略永久保留。

### 6. 扩容后业务OOM、写入延迟飙升
扩容同时大量Pod重启，IO打满存储，操作调整至低峰分批扩容。

### 7. 快照数量过多占用存储
successfulJobsHistoryLimit同类逻辑，定时清理过期快照，配置快照保留上限。

## 十、生产最佳实践
1. 所有业务StorageClass统一开启在线扩容，避免停机迁移磁盘；
2. 分布式存储核心业务配置定时自动快照，形成灾备兜底；
3. 扩容、快照、克隆操作全部记录操作日志，变更前导出yaml备份；
4. StatefulSet缩容严格保留PVC，杜绝误删业务持久数据；
5. 区分FAT可自动清理PVC、PROD人工审核删除PVC流程；
6. 监控PVC扩容失败、快照创建失败告警，第一时间介入处理；
7. 快照仅用于数据恢复，禁止长期大量快照占用存储池资源。

## 十一、关联文档
1. 存储底座：`03-storageclass.md` allowVolumeExpansion扩容开关配置
2. PVC基础：`02-persistent-volume-claim.md` PVC绑定、配额管控
3. 有状态负载：`02-workload-management/04-stateful-workloads.md` StatefulSet PVC生命周期
4. 数据备份：`05-backup-and-migration.md` 快照+定时备份双重数据保障
5. 存储故障汇总：`06-storage-troubleshooting.md` 扩容失败、快照创建异常完整排错SOP