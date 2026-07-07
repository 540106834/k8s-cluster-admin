# 05-backup-and-migration.md
## 一、文档基础信息
- 归属目录：`04-storage-management/`
- 前置阅读：`00-README.md`、`02-persistent-volume-claim.md`、`04-volume-operations.md`
- 集群基准：Kubernetes v1.32.13、CSI分布式存储、VolumeSnapshot快照、内网Harbor镜像仓库
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心覆盖：持久化数据备份方案、定时备份CronJob标准模板、快照备份、跨环境数据迁移、数据恢复完整流程、备份介质分级管控、多环境数据流转约束、备份故障排查

## 二、数据备份与迁移底层理论
### 2.1 两类备份方案
1. **文件逻辑备份（CronJob）**
   数据库dump、文件归档，生成独立备份文件存放持久PVC，适合小型库、日常定时全量备份；
2. **存储层快照备份（VolumeSnapshot）**
   CSI底层块设备快照，秒级生成，适合大容量数据库、Redis持久化磁盘，不占用业务CPU；
### 2.2 数据迁移两种场景
1. 同集群环境迁移：FAT ↔ UAT、UAT ↔ PROD只读数据复制；
2. 跨集群迁移：存量业务整体迁移、机房切换、新旧集群割接；
### 2.3 数据流转安全红线
1. PROD生产数据**禁止主动同步至FAT测试环境**，防止脏写、数据泄露；
2. UAT仅允许单向同步PROD只读备份数据，禁止反向回写；
3. 所有备份文件加密存储，禁止明文存放敏感业务数据。

## 三、定时逻辑备份 CronJob 标准模板（MySQL全量备份）
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mysql-prod-daily-backup
  namespace: prod
  labels:
    task: mysql-backup
    env: prod
    business: order
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid # 禁止并发备份锁库
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 3
      activeDeadlineSeconds: 1800
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: OnFailure
          tolerations:
          - key: node-role.kubernetes.io/control-plane
            operator: Exists
        containers:
        - name: backup
          image: harbor.jinshaoyong.com/k8s/mysql-client:8.0
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
          command: ["sh","-c","/scripts/mysql_full_backup.sh"]
          env:
          - name: DB_ADDR
            value: mysql.prod.svc.cluster.local
          - name: BACKUP_RETENTION_DAY
            value: "7"
          volumeMounts:
          - name: backup-script
            mountPath: /scripts
          - name: backup-storage-pvc
            mountPath: /backup-data
        volumes:
        - name: backup-script
          configMap:
            name: mysql-backup-script
        - name: backup-storage-pvc
          persistentVolumeClaim:
            claimName: prod-backup-pvc
```
### 关键配置说明
1. `concurrencyPolicy: Forbid`：同一时间仅运行一份备份，避免多任务并发锁表；
2. `activeDeadlineSeconds: 1800`：备份超时自动终止，防止任务卡死；
3. 备份脚本自动清理7天前过期备份文件，防止PVC存储耗尽。

## 四、存储快照备份流程（大容量中间件专用）
1. 业务低峰创建VolumeSnapshot；
2. 快照就绪后校验快照完整性；
3. 定时清理过期快照，PROD保留7天快照；
4. 故障恢复时从快照克隆全新PVC，挂载临时数据库验证数据。
```yaml
# 每日凌晨3点自动快照CronJob调用快照创建脚本
kubectl apply -f cronjob-mysql-snapshot.yaml -n prod
```

## 五、数据恢复标准操作流程
### 5.1 逻辑备份文件恢复
1. 暂停业务流量，Ingress临时关闭路由；
2. 进入备份Pod下载dump文件；
3. 新建临时Job执行导入SQL；
4. 校验数据行数、索引完整性；
5. 恢复正常流量。

### 5.2 快照克隆恢复
1. 基于历史快照创建新PVC；
2. 临时StatefulSet挂载克隆PVC启动数据库；
3. 数据校验无误后切换业务PVC；
4. 故障根因复盘，清理临时恢复资源。

## 六、跨环境数据迁移规范（FAT/UAT/PROD单向流转）
### 6.1 允许流转方向
1. PROD → UAT（只读备份数据，单向）；
2. FAT ↔ UAT（测试数据互通，仅用于功能验证）；
### 6.2 严格禁止
FAT主动拉取/写入PROD业务库、UAT反向回写PROD生产数据。
### 6.3 迁移标准步骤
1. PROD执行全量备份/快照；
2. 将备份文件同步至UAT专属备份PVC；
3. UAT临时Job执行数据导入；
4. 迁移完成清理临时备份文件，记录迁移日志。

## 七、DEV/FAT/UAT/PROD 差异化备份管控标准
| 环境 | 备份方式 | 备份周期 | 备份保留时长 | 数据跨环境流转 |
|------|----------|----------|--------------|----------------|
| DEV本地 | 无集群备份，本地手动导出 | 无定时 | 本地临时存放 | 不接入集群数据流转 |
| FAT测试 | 逻辑备份，简化定时 | 每4小时调试备份 | 3天自动清理 | 可自由与UAT互导测试数据 |
| UAT预生产 | 逻辑备份+快照双方案 | 每日凌晨2点 | 7天 | 仅可接收PROD只读备份，禁止反向写入 |
| PROD生产（强约束） | 逻辑定时备份 + 存储层快照双重兜底 | 每日凌晨2点逻辑备份；每日3点快照 | 逻辑备份7天、快照7天 | 禁止FAT主动访问生产备份库，仅UAT只读放行 |

### 生产强制约束
1. 核心业务同时开启**逻辑文件备份+CSI快照**双重灾备；
2. 备份任务避开业务高峰，统一凌晨低峰执行；
3. 备份存储独立PVC，与业务存储物理隔离；
4. 数据库账号、备份脚本存放Secret/ConfigMap，禁止硬编码；
5. 备份文件开启加密，敏感业务禁止明文存储；
6. 备份变更双人复核，定时任务修改前导出CronJob yaml+etcd快照；
7. NetworkPolicy限制定时备份Job仅访问对应命名空间中间件。

## 八、备份&迁移核心运维命令
```bash
# 手动执行一次数据库备份（应急）
kubectl create job --from=cronjob/mysql-prod-daily-backup temp-manual-backup-$(date +%m%d) -n prod

# 查看定时备份执行状态、失败日志
kubectl get jobs -n prod | grep mysql-prod-daily-backup
kubectl logs job/temp-manual-backup -n prod

# 查看快照列表
kubectl get volumesnapshots -n prod

# 从快照克隆PVC用于恢复
kubectl apply -f pvc-restore-from-snap.yaml -n prod

# 批量清理FAT过期备份Job
kubectl delete jobs -n fat --field-selector status.successful=1
```

## 九、高频备份&迁移故障排查
### 1. CronJob定时备份执行失败，状态Failed
1. 数据库账号密码Secret配置错误；
2. 备份PVC无写入权限、磁盘空间耗尽；
3. 数据库长事务锁表，dump中断。
### 2. 快照创建失败
CSI驱动不支持快照、存储池容量不足、PVC处于读写繁忙状态。
### 3. 备份文件丢失、自动被删除
ttlSecondsAfterFinished自动清理Job，或脚本自动清理过期备份；调大保留时长。
### 4. UAT导入PROD备份数据报错权限拒绝
NetworkPolicy拦截UAT备份Pod访问PROD备份PVC，放开白名单策略。
### 5. 备份任务并发执行，数据库锁冲突
CronJob未配置`concurrencyPolicy: Forbid`，修改为禁止并发。
### 6. 跨环境迁移数据超时
存储网络带宽不足、快照克隆IO打满存储池，业务低峰执行迁移。

## 十、生产灾备最佳实践
1. 核心业务采用「逻辑定时备份+块设备快照」双备份机制，防止单一备份失效；
2. 备份存储独立PVC，与业务存储物理隔离，避免业务磁盘故障连带丢失备份；
3. 监控CronJob执行状态、快照创建失败告警，备份失败第一时间通知运维；
4. 定期执行数据恢复演练，验证备份文件可用性；
5. 严格单向数据流转，阻断测试环境直连生产数据库；
6. 备份脚本、数据库密钥统一托管Secret，禁止明文暴露；
7. 集群大版本升级前执行全量业务备份，升级失败可完整回滚数据。

## 十一、关联文档
1. PVC持久存储：`02-persistent-volume-claim.md` 备份文件PVC存储规范
2. 卷快照能力：`04-volume-operations.md` VolumeSnapshot快照创建、克隆恢复流程
3. 定时批任务：`02-workload-management/06-batch-workloads.md` CronJob并发、超时、重试配置
4. 存储动态供给：`03-storageclass.md` 备份存储SC容量规划
5. 网络隔离：`03-network-management/06-network-policy.md` 备份Pod访问中间件白名单策略
6. 存储故障排错：`06-storage-troubleshooting.md` 备份PVC挂载失败、磁盘满故障SOP
7. 集群迁移：`cluster-migration.md` 跨集群数据完整迁移适配方案