# 03-storageclass.md
## 一、文档基础信息
- 归属目录：`04-storage-management/`
- 前置阅读：`00-README.md`、`01-persistent-volume.md`、`02-persistent-volume-claim.md`
- 集群基准：Kubernetes v1.32.13、CSI存储驱动、Local SSD/分布式存储、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：StorageClass底层原理、CSI驱动工作流程、本地SSD SC、分布式存储SC完整模板、离线部署、分环境存储类隔离、SC扩容、故障排查

## 二、StorageClass + CSI 底层理论
### 2.1 StorageClass 定位
StorageClass 是集群动态存储供给模板，定义**存储介质类型、PV回收策略、绑定模式、CSI驱动参数**；
PVC不指定静态PV时，自动匹配StorageClass，由CSI驱动自动创建PV，无需管理员手工维护静态PV，是业务持久存储标准方案。

### 2.2 CSI（Container Storage Interface）存储驱动
1. 组件组成
   - CSI Driver DaemonSet：节点侧，负责卷挂载/卸载、格式化；
   - CSI Controller Deployment：控制平面，负责创建/删除/扩容PV、快照；
2. 完整供给流程
   1. 用户创建PVC并指定storageClassName；
   2. K8s调用对应SC配置，下发请求至CSI Controller；
   3. CSI驱动对接底层存储池，自动创建PV；
   4. PV状态变为Bound，Pod可挂载PVC读写数据。

### 2.3 动态供给优势
1. 无需手工创建海量静态PV，降低运维成本；
2. 扩容副本自动生成PVC/PV，适配StatefulSet弹性扩缩容；
3. 统一管理存储介质：SSD高速盘、普通机械盘、分布式共享存储；
4. 支持在线扩容、快照、克隆高级存储能力。

### 2.4 与静态PV选型对比
| 供给方式 | 维护方式 | 适用场景 |
|----------|----------|----------|
| StorageClass动态CSI | 自动创建PV，无需人工维护 | 新集群、线上业务、StatefulSet中间件 |
| 静态PV | 管理员手工提前创建PV | 存量老旧本地磁盘、固定独占存储节点 |

## 三、两类标准StorageClass完整模板
### 3.1 Local SSD 本地固态存储（PROD数据库专用）
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-ssd-prod
  labels:
    env: prod
    storage: ssd
provisioner: kubernetes.io/no-provisioner # 本地盘无自动供给，需local-static-provisioner
volumeBindingMode: WaitForFirstConsumer # 等待Pod调度后再绑定PV，匹配节点
reclaimPolicy: Retain # 生产强制保留数据
allowVolumeExpansion: true # 开启在线卷扩容
```
配套组件：local-static-provisioner自动扫描节点宿主机 `/mnt/local-ssd` 目录生成静态PV。

### 3.2 分布式共享存储SC（RWX多节点读写）
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: dist-storage-uat
  labels:
    env: uat
    storage: distributed
provisioner: csi.jinshaoyong.com/dist-csi
volumeBindingMode: Immediate # PVC创建立刻创建PV
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  pool: uat-data-pool
  replica: 2
```

### 关键参数说明
1. `volumeBindingMode`
   - `WaitForFirstConsumer`（Local SSD必选）：PV延迟绑定，等待Pod调度到目标节点后再分配，避免跨节点挂载失败；
   - `Immediate`：PVC创建立即生成PV，分布式共享存储使用；
2. `reclaimPolicy`：PVC删除后PV处置策略；
3. `allowVolumeExpansion: true`：开启在线扩容，无需重建PV；
4. `provisioner`：CSI驱动标识，区分本地/分布式存储。

## 四、DEV/FAT/UAT/PROD 分环境SC隔离规范
### 全局隔离原则
三套业务环境独立StorageClass，底层存储物理池完全隔离，不共用磁盘资源，防止FAT峰值抢占PROD存储IO。

| 环境 | SC名称 | reclaimPolicy | allowVolumeExpansion | volumeBindingMode | 介质规格 |
|------|--------|---------------|----------------------|-------------------|----------|
| DEV本地 | local-dev | Delete | false | Immediate | 本地小容量磁盘 |
| FAT测试 | local-ssd-fat | Delete | true | WaitForFirstConsumer | 10~30Gi SSD |
| UAT预生产 | local-ssd-uat / dist-uat | Retain | true | WaitForFirstConsumer | 对齐生产容量规格 |
| PROD生产 | local-ssd-prod / dist-prod | Retain（强制） | true（强制） | WaitForFirstConsumer | 50Gi+高性能SSD |

### 生产强制约束
1. 数据库、Redis等核心有状态组件统一使用独立SSD StorageClass；
2. 所有PROD SC开启`allowVolumeExpansion`，支持在线扩容；
3. reclaimPolicy固定Retain，防止误删业务数据；
4. Local存储统一`WaitForFirstConsumer`延迟绑定，规避跨节点挂载报错；
5. 禁止业务Pod使用机械盘SC，仅日志临时中转使用。

## 五、CSI驱动离线部署规范（内网Harbor）
### 5.1 前置准备
1. 下载CSI官方yaml，替换镜像地址为内网仓库 `harbor.jinshaoyong.com/k8s/csi/*`；
2. 所有节点导入CSI镜像tar包至containerd；
3. 提前创建SC所需ConfigMap、Secret（存储池账号密码）；
4. 预留宿主机本地SSD目录 `/mnt/local-ssd`，格式化磁盘。

### 5.2 离线部署步骤
```bash
# 部署CSI控制器与节点DaemonSet
kubectl apply -f csi-local-offline.yaml -n kube-system

# 等待CSI组件全部就绪
kubectl get ds,deploy -n kube-system -l app=csi-local

# 应用对应环境StorageClass资源
kubectl apply -f sc-local-ssd-prod.yaml
```

### 5.3 升级CSI驱动规范
1. 业务低峰窗口执行升级；
2. 升级前导出SC、PVC、PV全量备份；
3. 滚动更新CSI DaemonSet，观测Pod就绪状态；
4. 异常立即回滚旧版本CSI yaml。

## 六、StorageClass 标准运维操作
```bash
# 创建/更新存储类
kubectl apply -f sc-local-ssd-prod.yaml

# 查看集群所有StorageClass
kubectl get storageclasses

# 查看SC完整配置、回收策略、扩容开关
kubectl describe storageclass local-ssd-prod

# 快速修改SC开启/关闭扩容
kubectl patch storageclass local-ssd-prod -p '{"allowVolumeExpansion":true}'

# 删除存储类（不会删除已创建PV/PVC）
kubectl delete storageclass local-ssd-fat
```

### 设为默认StorageClass
```bash
kubectl patch storageclass local-ssd-prod -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```
无指定storageClassName的PVC自动匹配默认SC。

## 七、存储池容量规划规范
1. FAT/UAT/PROD底层存储池物理隔离，磁盘互不共享；
2. 提前预留30%空闲磁盘空间，应对业务扩容；
3. Local SSD按节点拆分独立磁盘组，单一节点磁盘打满不影响全局；
4. 分布式存储多副本机制，计算可用容量时扣除副本占用空间。

## 八、高频StorageClass & CSI 故障排查
### 1. PVC Pending，CSI Controller无响应
1. CSI DaemonSet/Controller CrashLoopBackOff；
2. 内网Harbor CSI镜像拉取失败；
3. 存储池账号Secret配置错误，无法对接底层存储。

### 2. Local SSD Pod跨节点调度挂载失败
volumeBindingMode未设置`WaitForFirstConsumer`，PV提前绑定其他节点磁盘。

### 3. PVC扩容报错 Forbidden
SC未开启`allowVolumeExpansion: true`，修改SC开启扩容开关。

### 4. 删除PVC后PV同步丢失数据
SC reclaimPolicy配置为Delete，生产必须改为Retain。

### 5. 新增节点无法自动生成Local PV
local-static-provisioner DS异常，宿主机/mnt/local-ssd目录不存在或权限不足。

### 6. 分布式存储PV创建超时
存储池磁盘满、CSI节点网络不通、存储服务不可达。

## 九、生产存储最佳实践
1. 业务持久数据统一使用StorageClass动态供给，逐步淘汰静态PV；
2. 多环境独立SC，底层存储池物理隔离，禁止FAT流量占用PROD存储IO；
3. PROD全部SC开启在线扩容，规避停机迁移磁盘；
4. Local存储强制延迟绑定模式，杜绝跨节点挂载故障；
5. CSI组件部署在kube-system，资源配置requests/limits防止抢占业务节点；
6. StorageClass、CSI变更前导出yaml备份，集群升级前执行etcd快照；
7. 监控存储池剩余容量、CSI Pod状态、PV创建失败告警。

## 十、运维速查命令
```bash
# 导出所有StorageClass完整备份
kubectl get storageclasses -o yaml > all-sc-backup.yaml

# 查看CSI组件运行状态
kubectl get ds,deploy -n kube-system -l app=csi-local

# 查看CSI控制器日志（PV创建失败定位）
kubectl logs -n kube-system deploy/csi-local-controller -f

# 查看所有PVC关联StorageClass
kubectl get pvc --all-namespaces -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,STORAGE:.spec.storageClassName
```

## 十一、关联文档
1. PV/PVC基础：`01-persistent-volume.md` / `02-persistent-volume-claim.md` 绑定、回收策略
2. 有状态负载：`02-workload-management/04-stateful-workloads.md` StatefulSet volumeClaimTemplates动态PV供给
3. 卷扩容操作：`04-volume-operations.md` SC开启扩容后的PVC在线扩容流程
4. 存储故障汇总：`06-storage-troubleshooting.md` CSI异常、PVC无法创建、扩容失败排错SOP
5. 集群部署：集群离线部署文档 CSI镜像离线导入规范
6. 集群升级：`cluster-upgrade-theory-guide.md` CSI驱动升级兼容规则