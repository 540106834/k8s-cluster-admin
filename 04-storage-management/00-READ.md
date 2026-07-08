# 04-storage-management/00-README.md

## 一、文档基础信息

### 目录归属

路径：`04-storage-management/`
前置依赖：`02-workload-management/` 工作负载全套文档、`03-network-management/` 网络文档、集群初始化、containerd运行时
集群基准：Kubernetes v1.32.13、CSI存储驱动、Local SSD/分布式存储、内网Harbor镜像仓库
环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
配套关联：`etcd-backup.md`、`cluster-migration.md`、`10-workload-troubleshooting.md`

### 模块核心定位

集群存储是业务持久数据的底层载体，区分临时存储与持久化存储，本目录完整覆盖**PV/PVC静态存储、StorageClass CSI动态供给、卷扩容/快照、数据备份迁移、存储全链路故障排错**标准化运维规范。
严格区分四层环境存储策略：DEV本地临时存储、FAT测试可自动清理、UAT预生产仿真生产存储规格、PROD生产高可靠持久化存储，对数据库、缓存、备份文件等核心数据做分级管控。

## 二、子文档功能总览

| 文件名称 | 核心覆盖内容 |
|--------|------------|
| 01-persistent-volume.md | PV静态存储资源、生命周期、回收策略、访问模式、静态PV手工创建规范 |
| 02-persistent-volume-claim.md | PVC资源申请、PV绑定逻辑、StatefulSet volumeClaimTemplates、命名空间存储配额、分环境PVC管控 |
| 03-storageclass.md | StorageClass动态供给、CSI驱动原理、本地SSD/分布式存储SC配置、分环境存储类隔离、离线部署 |
| 04-volume-operations.md | 在线卷扩容、PV快照、克隆、存储卷生命周期、缩容PVC保留机制、存储扩容操作流程 |
| 05-backup-and-migration.md | 数据库/文件持久化数据备份、定时备份Job规范、跨环境数据迁移、备份恢复流程、备份存储介质管控 |
| 06-storage-troubleshooting.md | PV/PVC绑定失败、卷扩容报错、快照失效、Pod挂载失败、存储IO性能差、存储故障应急SOP |

## 三、核心存储分层理论认知

### 3.1 临时非持久存储（禁止存放业务数据）

1. emptyDir：Pod销毁数据直接删除，FAT临时缓存、日志中转使用；
2. hostPath：宿主机目录挂载，仅DaemonSet采集组件使用，业务Pod禁止挂载根目录；

### 3.2 持久化存储（业务核心数据唯一载体）

1. 静态PV：管理员提前创建固定存储卷，PVC静态绑定；
2. 动态供给StorageClass：PVC自动触发CSI创建PV，生产主流方案；
3. StatefulSet专属volumeClaimTemplates：每个Pod自动生成独立PVC，一一绑定PV；

### 3.3 存储三层联动关系

StorageClass → PV（动态/静态） ← PVC → Pod VolumeMount

## 四、PV访问模式与回收策略统一规范
### 4.1 三种访问模式
1. ReadWriteOnce(RWO)：单节点读写，本地SSD标准模式；
2. ReadWriteMany(RWX)：多节点同时读写，分布式共享存储；
3. ReadOnlyMany(ROM)：多节点只读，配置文件静态资源。
### 4.2 PV回收策略（生产强制区分）
1. Retain（PROD默认）：删除PVC后PV保留，人工审核后手动清理，防止数据误删；
2. Delete（FAT默认）：删除PVC同步删除PV，测试环境自动释放存储；
3. Recycle：旧版清空复用，集群新版本废弃不再使用。

## 五、四层环境存储标准化约束（DEV/FAT/UAT/PROD）
1. **DEV本地**
   本地Docker/Kind临时存储emptyDir，无持久PV/PVC；数据仅本地自测，不落地集群存储。
2. **FAT功能测试**
   - StorageClass宽松配置，PV回收策略Delete；
   - PVC可每日定时批量清理，测试数据无需长期留存；
   - 数据库可使用小容量本地存储，不限制存储销毁；
3. **UAT预生产**
   - SC规格、存储容量对齐生产；
   - PV回收策略Retain，删除PVC人工复核；
   - 每周定时备份仿真业务数据，禁止自动清理中间件PVC；
4. **PROD生产（强安全约束）**
   - 核心业务统一SSD高性能StorageClass，禁用机械盘；
   - PV回收策略强制Retain，删除PVC双人复核；
   - MySQL/Redis等StatefulSet使用volumeClaimTemplates自动生成独立PVC；
   - 开启卷扩容、快照能力，定期全量数据备份；
   - 禁止自动清理任何业务PVC，存储池容量持续监控告警；
   - NetworkPolicy限制定时备份任务仅访问生产存储服务。

## 六、标准化运维操作统一约束
1. 业务持久数据统一使用PVC绑定PV，禁止emptyDir承载业务库、缓存数据；
2. 集群初始化预先规划StorageClass，FAT/UAT/PROD存储池物理隔离；
3. 所有存储资源采用`kubectl apply -f`声明式管理，纳入Git版本；
4. StatefulSet有状态中间件必须使用volumeClaimTemplates自动生成PVC；
5. 生产环境存储卷扩容操作避开业务高峰，扩容前执行数据备份；
6. 核心数据库变更、存储资源删除前导出PV/PVC yaml备份，执行etcd快照；
7. 存储故障优先使用`06-storage-troubleshooting.md`分层定位CSI/PV/PVC/挂载问题。

## 七、推荐阅读&实操顺序
1. 存储底层基础：01-persistent-volume.md（静态PV原理）
2. 资源申请入口：02-persistent-volume-claim.md（PVC绑定、配额管控）
3. 动态供给底座：03-storageclass.md（CSI、SC集群存储初始化）
4. 存储运维能力：04-volume-operations.md（扩容、快照、卷生命周期）
5. 数据安全兜底：05-backup-and-migration.md（备份、跨环境迁移）
6. 故障应急排查：06-storage-troubleshooting.md

## 八、上下游文档关联
### 上游前置
1. `00-README.md` 集群整体规划文档（存储池、磁盘资源规划）
2. `02-workload-management/04-stateful-workloads.md` StatefulSet PVC模板规范
3. `02-workload-management/07-resource-management.md` Namespace PVC数量配额管控

### 下游配套
1. `etcd-backup.md` 集群存储配置变更前置快照备份规范
2. `cluster-migration.md` 跨集群存储数据迁移适配方案
3. `02-workload-management/10-workload-troubleshooting.md` Pod挂载存储崩溃通用排错
4. `cluster-upgrade-theory-guide.md` CSI驱动、StorageClass升级兼容规则

## 九、适用业务场景清单
1. 微服务临时缓存、短期日志中转 → emptyDir
2. 数据库/Redis持久业务数据 → PVC+StorageClass动态PV
3. MySQL/ES/Kafka有序集群存储 → StatefulSet volumeClaimTemplates
4. 存储容量不足在线扩容 → 04-volume-operations.md卷扩容流程
5. 业务数据定期备份、灾备恢复、FAT→UAT数据同步 → 05-backup-and-migration.md
6. PVC一直Pending无法绑定PV、卷扩容失败、Pod挂载目录权限报错、CSI插件异常 → 06-storage-troubleshooting.md
7. 静态存量存储资源手工管理、回收策略管控 → PV管理文档