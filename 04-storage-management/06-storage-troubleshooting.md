# 06-storage-troubleshooting.md
## 一、文档基础信息
- 归属目录：`04-storage-management/`
- 前置阅读：00~05 全套存储管理文档、`02-workload-management/10-workload-troubleshooting.md`
- 集群基准：Kubernetes v1.32.13、CSI驱动、Local SSD/分布式存储、VolumeSnapshot、内网Harbor镜像仓库
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心定位：全链路存储故障标准化排查SOP，覆盖PV、PVC、StorageClass、CSI、卷扩容、快照、挂载、IO性能问题，包含故障定位命令、根因拆解、分级处置流程、生产应急规范

## 二、统一存储故障分层排查SOP
1. **第一步：查看PVC/PV基础状态**
```bash
kubectl get pv,pvc -n ${ns} -o wide
kubectl describe pvc ${pvc-name} -n ${ns}
```
重点观测：Phase状态、StorageClass、绑定PV、事件报错（容量/匹配/CSI报错）

2. **第二步：校验CSI驱动组件运行状态**
```bash
# 查看CSI控制器、节点DaemonSet
kubectl get ds,deploy -n kube-system -l app=csi
kubectl logs -n kube-system ds/csi-node
kubectl logs -n kube-system deploy/csi-controller
```

3. **第三步：存储容量与配额校验**
```bash
# 查看命名空间PVC存储配额上限
kubectl describe resourcequota -n ${ns}
# 查看底层存储池剩余容量（存储平台/节点磁盘df -h）
kubectl exec -it test-pod -n ${ns} -- df -h
```

4. **第四步：卷扩容/快照专项校验**
```bash
# 查看扩容状态
kubectl get pvc -n ${ns}
# 查看快照资源
kubectl get volumesnapshots -n ${ns}
kubectl describe volumesnapshot ${snap-name} -n ${ns}
```

5. **第五步：Pod挂载与文件系统校验**
```bash
kubectl get pods -n ${ns} -o wide
kubectl describe pod ${pod-name} -n ${ns}
kubectl exec -it ${pod-name} -n ${ns} -- mount
```

## 三、PV / PVC 绑定类故障
### 3.1 PVC 持续 Pending，无法绑定PV
**根因清单**
1. PVC容量、accessModes、storageClassName与所有Available PV不匹配；
2. 集群无空闲PV，静态PV全部Bound；动态SC存储池磁盘耗尽；
3. Namespace ResourceQuota `persistentvolumeclaims` / requests.storage 达到硬上限；
4. Local PV配置nodeAffinity，Pod调度节点与PV绑定节点不匹配；
5. CSI Controller异常，无法动态创建PV。
**修复方案**
1. 清理废弃PVC释放存储，或上调Quota硬限制；
2. 核对PVC与SC/PV的访问模式、容量、存储类名称；
3. 扩容底层存储池，修复CSI异常Pod；
4. 调整Pod节点标签匹配Local PV nodeAffinity。

### 3.2 PV状态 Released，无法重新绑定新PVC
**根因**
PV回收策略为Retain，PVC删除后PV进入Released锁定状态，不允许二次绑定。
**修复**
1. 确认数据已备份、业务下线；
2. 删除Released PV；
3. 新建PVC自动触发SC生成全新PV。

### 3.3 StatefulSet扩容Pod时报错无法创建PVC
1. 命名空间PVC数量Quota耗尽；
2. CSI驱动故障，无法动态生成PV；
3. StorageClass存储池容量不足。
**修复**
清理闲置PVC，扩容存储池，重启CSI控制器。

## 四、PVC在线扩容相关故障
### 4.1 修改PVC容量后报错 Forbidden
**根因**
对应StorageClass未开启 `allowVolumeExpansion: true`。
**修复**
编辑StorageClass开启扩容开关，重新apply PVC。

### 4.2 PVC状态显示 FileSystemResizePending，但Pod磁盘容量不变
1. Pod未重启，文件系统未执行resize；
2. 文件系统类型不支持在线扩容（老旧ext3等）；
3. CSI节点扩容脚本卡死无响应。
**修复**
1. 滚动重启负载重建Pod自动扩容文件系统；
2. 手动进入容器执行扩容命令 `xfs_growfs /mountpath` / `resize2fs /dev/vdx`；
3. 重启CSI-node刷新存储规则。

### 4.3 扩容后数据库写入IO飙升、响应卡顿
扩容瞬间批量重建大量Pod，存储IO打满；业务低峰分批扩容，提前扩容存储节点分担IO压力。

## 五、VolumeSnapshot 快照相关故障
### 5.1 CronJob定时快照不生成Snapshot资源
1. 当前CSI驱动为Local SSD，不支持快照能力；
2. VolumeSnapshotClass未配置、快照脚本cron表达式错误；
3. 存储池剩余容量不足，无法分配快照空间。

### 5.2 快照状态 Failed，创建失败
1. 源PVC业务正在大量写入，IO繁忙无法打快照；
2. 存储池副本策略不满足快照要求；
3. CSI Controller鉴权、权限不足。
**修复**
业务低峰重新执行快照，扩容存储池，重启CSI控制器。

### 5.3 从快照克隆PVC Pending恢复失败
1. 快照损坏、状态非ReadyToUse；
2. 克隆PVC容量小于快照源PVC；
3. accessModes与快照源不匹配。

## 六、Pod 挂载存储故障
### 6.1 Pod创建Pending，报错 FailedMount / timeout waiting for volume
1. CSI-node DaemonSet未就绪、异常Crash；
2. Local PV宿主机目录不存在、磁盘未格式化；
3. 节点防火墙/SELinux拦截CSI挂载操作；
4. PVC处于Released状态，无可用PV绑定。

### 6.2 Pod启动成功，但读写目录权限拒绝
1. 宿主机本地目录uid/gid与容器运行用户不匹配；
2. 未配置Pod securityContext运行用户；
3. 存储卷只读挂载。
**修复**
配置Pod securityContext.runAsUser，调整宿主机目录权限。

### 6.3 Pod重启后数据丢失
1. 使用emptyDir临时存储而非PVC持久卷；
2. 手动删除PVC，PV同步删除（SC回收策略Delete）；
3. StatefulSet未配置volumeClaimTemplates。

### 6.4 Pod挂载PVC后df看不到扩容后容量
文件系统未自动resize，重启Pod或手动扩容文件系统。

## 七、CSI 存储驱动底层故障
### 7.1 CSI-node CrashLoopBackOff
1. 内网Harbor CSI镜像拉取失败；
2. 宿主机磁盘目录权限不足；
3. 存储平台API地址不通、账号Secret配置错误。

### 7.2 动态SC创建PVC一直Pending，CSI无日志输出
CSI Controller Pod未正常调度，重启CSI Deployment等待同步。

### 7.3 升级CSI后所有存储挂载异常
新旧CSI CRD不兼容，回滚至稳定旧版本，采用递进式小版本升级。

## 八、存储IO性能差、业务慢通用故障
### 8.1 数据库频繁卡顿、大量io_wait
1. 使用机械盘而非SSD StorageClass；
2. 存储池磁盘满，IO阻塞；
3. 多业务共享同一存储节点，IO资源抢占；
4. 快照、备份任务并发抢占IO。
**修复**
切换SSD存储类，拆分存储节点，备份任务错开业务高峰，配置`concurrencyPolicy: Forbid`。

### 8.2 批量写入数据触发磁盘打满OOM killed
PVC绑定PV容量不足，扩容PV或清理过期备份文件。

## 九、DEV/FAT/UAT/PROD 故障分级处置规范
### DEV本地
直接删除重建Pod、PVC，无需备份、无需审批，快速调试。
### FAT测试
故障优先清理负载重建；存储资源可批量清空，自动清理机制兜底。
### UAT预生产
故障先导出PV/PVC yaml备份，再执行回滚/重建；故障用于验证生产应急预案。
### PROD生产（最高优先级约束）
1. 存储故障第一时间暂停业务写入、暂停定时备份Job；
2. 有状态中间件禁止强制删除PVC，优先回滚快照/备份；
3. 操作双人复核，重大故障先执行etcd快照；
4. 禁止直接删除数据库绑定的PVC/PV；
5. 故障复盘优化存储容量监控、快照备份规范。

## 十、存储应急排查速查命令合集
```bash
# 1. 查看PV/PVC绑定、Phase状态
kubectl get pv,pvc -n ${ns} -o wide

# 2. 查看PVC完整事件（扩容/配额/CSI报错）
kubectl describe pvc ${pvc-name} -n ${ns}

# 3. 查看CSI组件运行状态与日志
kubectl get ds,deploy -n kube-system -l app=csi
kubectl logs -n kube-system ds/csi-node -f

# 4. 查看快照创建失败详情
kubectl describe volumesnapshot ${snap-name} -n ${ns}

# 5. 批量清理FAT环境废弃PVC
kubectl delete pvc -n fat --field-selector status.phase=Released

# 6. 查看命名空间存储配额占用
kubectl describe resourcequota -n ${ns}

# 7. 临时暂停定时备份Job防止IO打满存储
kubectl patch cronjob backup-task -n prod -p '{"spec":{"suspend":true}}'
```

## 十一、关联文档
1. 存储全套前置：01-persistent-volume ~ 05-backup-and-migration 存储运维规范
2. 工作负载排错：`02-workload-management/10-workload-troubleshooting.md` Pod通用故障
3. 网络底层：`03-network-management/08-network-troubleshooting.md` CSI存储平台网络不通排查
4. 集群备份：`etcd-backup.md` 存储资源变更前置快照规范
5. 集群迁移：`cluster-migration.md` 跨集群存储数据故障恢复方案