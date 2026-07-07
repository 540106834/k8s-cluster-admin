# 01-persistent-volume.md
## 一、文档基础信息
- 归属目录：`04-storage-management/`
- 前置阅读：`00-README.md`、`02-workload-management/07-resource-management.md`
- 集群基准：Kubernetes v1.32.13、CSI存储驱动、Local SSD/分布式存储、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：PV静态资源定义、完整生命周期、访问模式、三种回收策略、静态PV完整模板、手工运维流程、分环境管控、故障排查

## 二、PV 底层核心理论
### 2.1 PV 定位
PersistentVolume（持久卷）是集群级存储资源，独立于Namespace，由管理员提前创建静态存储资源；
代表底层物理存储：本地SSD、分布式存储、SAN/NFS等，提供固定容量、访问权限、回收规则。
### 2.2 PV 与 PVC 绑定逻辑
1. PV为集群全局资源，无命名空间隔离；PVC归属单个Namespace；
2. 静态PV依靠`storageClassName`、容量、访问模式匹配PVC；
3. 一对一绑定：一个PV仅能绑定一个PVC，绑定后二者生命周期强关联；
4. 集群推荐动态StorageClass自动供给PV，静态PV仅用于存量老旧存储、固定专属数据库磁盘。

### 2.3 PV 完整生命周期状态
1. **Available**：空闲未绑定，可被PVC申请占用；
2. **Bound**：已匹配PVC，正在被业务Pod使用；
3. **Released**：PVC被删除，PV保留等待管理员处理；
4. **Failed**：回收数据失败，无法复用。

## 三、PV 三大访问模式（统一落地标准）
| 访问模式 | 标识 | 适用场景 | 环境使用规范 |
|------|------|----------|--------------|
| ReadWriteOnce（RWO） | ReadWriteOnce | 单节点挂载，本地SSD单机数据库 | FAT/UAT/PROD数据库、Redis单机通用 |
| ReadOnlyMany（ROM） | ReadOnlyMany | 多节点只读，静态配置文件、镜像缓存 | 静态只读资源专用 |
| ReadWriteMany（RWX） | ReadWriteMany | 多节点同时读写，分布式共享存储 | 仅分布式文件存储使用，本地SSD禁止 |

### 强制约束
本地SSD磁盘仅支持RWO，不支持多节点同时读写RWX。

## 四、三种PV回收策略（分环境严格区分）
### 4.1 Retain（PROD/UAT 默认强制）
删除PVC后PV进入Released状态，**数据完整保留**，不会自动删除底层磁盘；
人工审核确认无业务数据后，手动清理PV与底层存储，防止误删核心业务数据。

### 4.2 Delete（FAT测试默认）
PVC删除时同步删除PV与底层存储数据，自动释放磁盘空间，测试环境快速重置环境。

### 4.3 Recycle（废弃淘汰）
旧版本清空数据复用PV，v1.20+集群不再支持，禁止配置。

## 五、静态PV标准完整模板（Local SSD示例）
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mysql-prod-0
  labels:
    storage: ssd
    env: prod
    business: order
spec:
  # 存储容量
  capacity:
    storage: 50Gi
  # 访问模式
  accessModes:
  - ReadWriteOnce
  # 回收策略（生产强制Retain）
  persistentVolumeReclaimPolicy: Retain
  # 绑定对应StorageClass，和PVC统一匹配
  storageClassName: local-ssd-prod
  # 挂载节点约束：仅指定存储节点可挂载
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: storage-node
          operator: In
          values: ["ssd-01"]
  # 底层宿主机磁盘路径
  local:
    path: /mnt/local-ssd/mysql0
```

### NFS共享存储静态PV模板（RWX）
```yaml
spec:
  capacity:
    storage: 100Gi
  accessModes:
  - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-share
  nfs:
    server: 192.168.20.10
    path: /data/share/uat
```

## 六、DEV/FAT/UAT/PROD 静态PV差异化规范
### DEV本地
不使用集群PV，本地Docker emptyDir/本地磁盘临时存储，无静态PV资源。

### FAT测试
1. persistentVolumeReclaimPolicy: Delete；
2. 容量规格宽松，10Gi~30Gi；
3. 可批量自动清理PV，测试数据无需留存；
4. 允许使用机械盘临时存储。

### UAT预生产
1. persistentVolumeReclaimPolicy: Retain；
2. 容量、StorageClass、访问模式对齐生产；
3. PVC删除后人工审核再清理PV；
4. 优先SSD存储，禁止机械盘承载仿真业务数据。

### PROD生产（强约束）
1. persistentVolumeReclaimPolicy固定Retain，禁止Delete；
2. 数据库、缓存统一SSD Local PV，RWO访问模式；
3. nodeAffinity绑定专属存储节点，禁止跨节点随意调度；
4. PV创建、删除双人复核，删除前完成数据库全量备份；
5. 禁止自动清理PV，防止业务数据误销毁；
6. 大版本升级前导出所有PV资源yaml备份，执行etcd快照。

## 七、静态PV标准运维操作
### 7.1 创建静态PV
```bash
kubectl apply -f pv-mysql-prod-0.yaml
```

### 7.2 查看PV全局状态
```bash
# 查看所有PV
kubectl get pv

# 查看PV绑定PVC、容量、回收策略、节点亲和
kubectl describe pv pv-mysql-prod-0
```

### 7.3 查看PV绑定的PVC
```bash
kubectl get pv,pvc -n prod
```

### 7.4 Released状态PV清理流程（生产标准）
1. 确认对应业务已下线、数据已备份；
2. 删除PV资源：
```bash
kubectl delete pv pv-mysql-prod-0
```
3. 登录存储节点手动清空底层磁盘目录，回收物理空间。

### 7.5 删除PV（高危操作）
生产禁止直接删除在用PV，仅Released空闲PV可人工复核后删除。

## 八、静态PV vs 动态StorageClass PV 选型对比
| 类型 | 创建方式 | 适用场景 | 运维成本 |
|------|----------|----------|----------|
| 静态PV | 管理员手动yaml创建 | 存量老旧磁盘、固定专属数据库节点 | 高，新增磁盘需手工维护PV |
| 动态SC PV | PVC自动触发CSI创建 | 常规业务、新上线集群 | 低，自动分配无需手工维护 |

落地规范：新业务统一使用StorageClass动态供给；存量历史磁盘使用静态PV逐步迁移。

## 九、高频静态PV故障排查
### 1. PVC处于Pending，无法绑定PV
1. PV容量、accessModes、storageClassName不匹配PVC；
2. 所有匹配PV状态为Bound，无空闲Available PV；
3. nodeAffinity节点标签不匹配，Pod无法调度至PV对应节点。

### 2. PV状态Released，无法重新绑定新PVC
静态PV回收策略Retain，Released状态不允许二次绑定；
处理：删除PV，重建新静态PV或切换动态StorageClass。

### 3. Pod启动失败，挂载PV目录权限不足
宿主机local目录权限限制，调整宿主机目录uid/gid，或配置Pod securityContext。

### 4. 静态PV扩容后容量不生效
静态PV不支持在线扩容，需新建大容量PV，迁移数据后切换PVC绑定。

### 5. 多节点Pod无法同时读写Local PV
Local SSD仅支持RWO，不可配置RWX访问模式，改用分布式共享存储。

## 十、生产存储最佳实践
1. 新业务优先使用StorageClass动态供给，静态PV仅存量历史磁盘过渡使用；
2. PROD/UAT统一回收策略Retain，杜绝误删业务数据；
3. Local静态PV必须配置nodeAffinity锁定存储节点，防止跨节点调度挂载失败；
4. 静态PV容量预留冗余，避免磁盘打满导致数据库宕机；
5. 定期巡检Released状态PV，统一登记、备份后清理；
6. 存储变更、新增静态PV前导出PV全量yaml备份；
7. 区分FAT/UAT/PROD三套存储池，静态PV网段、磁盘物理隔离，不混用存储节点。

## 十一、运维速查命令
```bash
# 批量导出集群所有静态PV备份
kubectl get pv -o yaml > all-static-pv-backup-$(date +%Y%m%d).yaml

# 筛选Released闲置PV
kubectl get pv --field-selector status.Released=true

# 查看PV绑定关系
kubectl get pv,pvc -A

# 删除闲置Released PV
kubectl delete pv pv-name
```

## 十二、关联文档
1. 存储资源申请：`02-persistent-volume-claim.md` PVC匹配PV绑定规则
2. 动态存储底座：`03-storageclass.md` StorageClass动态PV对比
3. 有状态负载：`02-workload-management/04-stateful-workloads.md` StatefulSet PVC模板使用静态PV场景
4. 存储配额管控：`02-workload-management/07-resource-management.md` PVC数量Quota限制
5. 存储故障汇总：`06-storage-troubleshooting.md` PV绑定失败、挂载权限不足完整排错SOP
6. 数据备份：`05-backup-and-migration.md` PV内数据库备份规范