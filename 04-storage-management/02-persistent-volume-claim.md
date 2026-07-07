# 02-persistent-volume-claim.md
## 一、文档基础信息
- 归属目录：`04-storage-management/`
- 前置阅读：`00-README.md`、`01-persistent-volume.md`、`02-workload-management/07-resource-management.md`
- 集群基准：Kubernetes v1.32.13、CSI驱动、Local SSD/分布式存储、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：PVC底层原理、PV绑定匹配规则、普通PVC模板、StatefulSet volumeClaimTemplates、命名空间PVC配额、分环境生命周期管控、故障排查

## 二、PVC 底层核心理论
### 2.1 定位
PersistentVolumeClaim（持久卷申请）是**命名空间级存储申请资源**，业务侧声明存储容量、访问模式、StorageClass，由集群匹配对应PV（静态/动态SC自动创建），Pod通过挂载PVC实现持久化数据存储。
1. PVC归属单一Namespace，PV是集群全局资源；
2. 一对一绑定：一个PVC仅能绑定一个PV，绑定后不可更换；
3. 无状态Deployment使用独立PVC；StatefulSet依靠`volumeClaimTemplates`自动批量生成PVC。

### 2.2 PV与PVC绑定匹配优先级
匹配条件必须全部满足才会绑定：
1. storageClassName 完全一致；
2. accessModes 访问模式匹配；
3. PV容量 ≥ PVC申请存储容量；
4. 静态PV额外匹配nodeAffinity节点调度约束。

### 2.3 两种PVC生成方式
1. **手动创建PVC**：Deployment、一次性Job、临时测试使用；
2. **volumeClaimTemplates（StatefulSet专属）**：STS扩容/缩容自动创建/保留PVC，每个Pod独占一套存储，重建Pod自动复用原有PVC。

## 三、标准PVC模板
### 3.1 普通PVC（Deployment业务使用）
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: order-data-pvc
  namespace: prod
  labels:
    app: order-api
    env: prod
    business: order
spec:
  # 申请存储容量
  resources:
    requests:
      storage: 50Gi
  # 访问模式
  accessModes:
  - ReadWriteOnce
  # 指定动态存储类
  storageClassName: local-ssd-prod
```

### 3.2 StatefulSet volumeClaimTemplates 自动生成PVC模板
```yaml
spec:
  volumeClaimTemplates:
  - metadata:
      name: mysql-data
      labels:
        app: mysql
        env: prod
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: local-ssd-prod
      resources:
        requests:
          storage: 50Gi
```
机制：STS每扩容一个Pod，自动生成 `mysql-data-mysql-N` 格式PVC；缩容仅删除Pod，PVC永久保留，防止数据丢失。

## 四、PVC生命周期联动规则
1. 创建PVC：调度匹配可用PV，动态SC自动触发CSI创建PV；
2. 绑定Bound：PVC与PV一一关联，Pod可挂载使用；
3. 删除PVC：
   - PV回收策略`Retain`：PV进入Released状态，数据留存；
   - PV回收策略`Delete`：同步删除PV与底层存储数据；
4. StatefulSet删除：仅删除Pod，PVC不会自动删除，人工确认无业务后再清理。

## 五、命名空间存储配额约束（ResourceQuota）
PVC数量、总存储容量计入Namespace ResourceQuota硬限制：
```yaml
# quota示例
hard:
  persistentvolumeclaims: 15
  requests.storage: 800Gi
```
创建PVC报错`exceeded quota`代表存储数量/容量已达上限，需清理闲置PVC或上调配额。

## 六、DEV/FAT/UAT/PROD 分环境PVC管控规范
| 环境 | PVC创建方式 | 存储容量标准 | PV回收策略 | PVC清理规则 |
|------|-------------|--------------|------------|-------------|
| DEV本地 | 本地EmptyDir，不使用集群PVC | 无要求 | - | 无需清理 |
| FAT测试 | 手动PVC，临时调试 | 10~30Gi | Delete | 每日定时批量清理废弃PVC |
| UAT预生产 | 手动PVC + STS模板 | 对齐生产容量 | Retain | 下线业务人工审核后清理 |
| PROD生产 | STS强制volumeClaimTemplates，业务手动PVC | ≥50Gi核心数据库 | Retain | 删除PVC双人复核，提前全量备份数据 |

### 生产强制红线
1. 数据库、Redis等StatefulSet组件必须使用volumeClaimTemplates自动生成PVC，禁止手工创建PVC绑定STS；
2. PROD环境PV回收策略统一Retain，杜绝误删业务数据；
3. 所有PVC绑定SSD StorageClass，禁止机械盘承载业务持久数据；
4. 发布、扩容前校验命名空间PVC剩余配额，避免创建失败。

## 七、PVC 标准运维操作
### 7.1 创建PVC
```bash
kubectl apply -f pvc-order-prod.yaml -n prod
```

### 7.2 查看PVC绑定状态
```bash
# 查看所有PVC
kubectl get pvc -n prod

# 关联查看绑定PV
kubectl get pv,pvc -n prod

# 完整事件、绑定失败原因、存储类校验
kubectl describe pvc order-data-pvc -n prod
```

### 7.3 批量清理废弃PVC（FAT专用）
```bash
# 清理未使用、无Pod挂载PVC
kubectl delete pvc -n fat --field-selector status.phase=Released
```

### 7.4 删除PVC（高危操作）
```bash
# 标准删除
kubectl delete pvc order-data-pvc -n prod
```
PROD操作前置：确认业务已下线、数据库完成全量备份，双人复核。

### 7.5 StatefulSet扩容PVC逻辑
1. 修改sts volumeClaimTemplates存储容量；
2. 扩容新Pod自动生成大容量PVC；
3. 存量Pod原有PVC容量不变，需单独迁移数据或在线扩容PV。

## 八、PVC与StatefulSet完整配套流程
1. 部署Headless Service；
2. 编写StatefulSet配置volumeClaimTemplates；
3. 部署STS，自动生成有序Pod与对应PVC；
4. Pod重建自动绑定原有PVC，业务数据不丢失；
5. 缩容仅销毁Pod，PVC永久保留。

## 九、高频PVC故障排查
### 1. PVC一直Pending，无法绑定PV
1. storageClassName与PV不匹配；
2. 集群无空闲容量、PV accessModes不兼容；
3. ResourceQuota pvc数量/存储容量打满；
4. Local PV nodeSelector节点不匹配。

### 2. StatefulSet Pod Pending，PVC创建失败
Namespace PVC配额耗尽、StorageClass CSI驱动异常无法创建PV。

### 3. 删除STS后数据丢失
手动删除PVC，Retain策略下仅删除STS不会删除PVC。

### 4. 修改volumeClaimTemplates容量后存量PVC容量不变
模板仅控制新扩容Pod，存量PVC不会自动扩容，需单独执行卷扩容操作。

### 5. Pod挂载PVC目录权限不足
存储卷SecurityContext未配置运行用户，调整Pod securityContext。

### 6. 创建PVC报错 exceeded quota
命名空间ResourceQuota存储硬上限耗尽，清理闲置PVC或上调quota。

## 十、运维最佳实践
1. 有状态中间件统一使用volumeClaimTemplates自动生成PVC，管理有序Pod专属存储；
2. 区分FAT自动清理、UAT/PROD人工审核PVC删除流程；
3. 业务发布、扩容前校验Namespace剩余PVC配额；
4. PVC变更前导出yaml备份，集群升级前执行etcd快照；
5. 禁止共用PVC给多套业务，避免文件锁、数据覆盖冲突；
6. NetworkPolicy限制定时备份Job仅允许读写业务PVC存储地址。

## 十一、运维速查命令
```bash
# 导出当前命名空间PVC完整备份
kubectl get pvc -n prod -o yaml > pvc-prod-backup.yaml

# 筛选未绑定PV的PVC
kubectl get pvc -n fat --field-selector status.phase=Pending

# 查看STS自动生成PVC列表
kubectl get sts,pvc -n prod

# 批量清理测试环境废弃PVC
kubectl delete pvc -n fat --field-selector status.phase=Released
```

## 十二、关联文档
1. 静态PV基础：`01-persistent-volume.md` PV匹配、回收策略规范
2. 动态存储底座：`03-storageclass.md` CSI动态供给PV逻辑
3. 有状态负载：`02-workload-management/04-stateful-workloads.md` StatefulSet配套模板
4. 资源配额管控：`02-workload-management/07-resource-management.md` PVC数量&存储Quota
5. 卷扩容：`04-volume-operations.md` PVC绑定PV在线扩容流程
6. 存储故障汇总：`06-storage-troubleshooting.md` PVC绑定失败、挂载异常完整排错SOP