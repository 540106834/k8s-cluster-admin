# 06-batch-workloads.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`01-namespace-management.md`、`02-pod-lifecycle.md`
- 集群环境：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：Job一次性批任务、CronJob定时调度、并发/重试/超时控制、清理策略、分环境模板、定时表达式、故障排查

## 二、批处理控制器底层理论
### 2.1 适用场景
Job：一次性短期批处理任务，执行完成即结束；
CronJob：基于 cron 表达式周期调度，底层自动创建 Job 执行任务。
典型业务：数据同步、数据库备份、日志清理、报表统计、缓存刷新、定时巡检。

### 2.2 Job 核心特性
1. 支持**重试策略**：任务异常退出自动重建Pod；
2. 支持**并发控制**：串行/并行执行多副本任务；
3. 支持**执行超时**：防止任务卡死永久占用资源；
4. 重启策略固定使用 `restartPolicy: Never / OnFailure`，禁止 Always；
5. 任务执行完成后Pod保留，用于查看日志，可配置自动清理TTL。

### 2.3 CronJob 核心特性
1. 标准 Linux cron 五分位表达式调度；
2. 每个调度周期生成独立Job，任务隔离互不干扰；
3. 支持并发策略：禁止并发/允许并发/替换旧任务；
4. 限制历史成功/失败Job保留数量，避免堆积大量Pod；
5. 支持调度超时、错过调度窗口容错配置。

### 2.4 四类控制器横向对比
| 控制器 | 运行模式 | 生命周期 | 典型用途 |
|--------|----------|----------|----------|
| Deployment | 常驻持续运行 | 永久在线 | Web/API无状态服务 |
| StatefulSet | 常驻有序副本 | 永久在线 | MySQL/Redis中间件 |
| DaemonSet | 节点常驻采集 | 永久在线 | 日志、监控节点组件 |
| Job/CronJob | 一次性/周期短时执行 | 执行完毕终止 | 定时备份、数据批处理 |

## 三、Job 一次性任务标准模板（数据库备份示例）
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: mysql-backup-once
  namespace: prod
  labels:
    task: mysql-backup
    env: prod
    business: order
spec:
  # 任务失败最大重试次数
  backoffLimit: 3
  # 任务总执行超时，超时强制终止
  activeDeadlineSeconds: 1800
  # 并行副本数，1=串行单任务
  parallelism: 1
  # 期望完成成功副本数
  completions: 1
  # 任务完成后Pod自动清理时长
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: OnFailure # 失败重启，成功不再重启
      containers:
      - name: backup
        image: harbor.jinshaoyong.com/k8s/mysql-client:8.0
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 1Gi
        command: ["sh","-c","/scripts/mysql_backup.sh"]
        env:
        - name: DB_HOST
          value: mysql.prod.svc.cluster.local
        volumeMounts:
        - name: script
          mountPath: /scripts
        - name: backup-storage
          mountPath: /backup
      volumes:
      - name: script
        configMap:
          name: backup-script
      - name: backup-storage
        persistentVolumeClaim:
          claimName: backup-pvc
```

## 四、CronJob 定时任务标准模板（每日凌晨2点数据库备份）
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mysql-daily-backup
  namespace: prod
  labels:
    task: mysql-backup
    env: prod
spec:
  # cron表达式：分 时 日 月 周
  schedule: "0 2 * * *"
  # 错过调度窗口是否允许延后执行
  startingDeadlineSeconds: 3600
  # 并发策略：Forbid=禁止并发，同一时间只运行一个任务
  concurrencyPolicy: Forbid
  # 保留成功/失败历史Job数量
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  # Job模板，同独立Job配置
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 1800
      ttlSecondsAfterFinished: 43200
      template:
        spec:
          restartPolicy: OnFailure
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
            command: ["sh","-c","/scripts/mysql_backup.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
            - name: backup-storage
              mountPath: /backup
          volumes:
          - name: script
            configMap:
              name: backup-script
          - name: backup-storage
            persistentVolumeClaim:
              claimName: backup-pvc
```

### Cron 五分位表达式规范
格式：`分 时 日 月 星期`
- `0 2 * * *` 每日凌晨2点
- `0 */1 * * *` 每小时整点
- `30 */6 * * *` 每6小时30分执行
- `0 1 * * 0` 每周日凌晨1点

### concurrencyPolicy 三种并发策略
1. `Forbid`（生产推荐）：上一轮任务未完成，跳过本次调度，避免多任务并发抢占数据库
2. `Replace`：直接杀死正在运行的旧任务，启动新任务
3. `Allow`：允许多任务同时并发执行，仅无状态清理类任务可用

## 五、分环境标准化配置规范（DEV/FAT/UAT/PROD）
| 环境 | restartPolicy | backoffLimit | activeDeadlineSeconds | concurrencyPolicy | 历史Job保留数 |
|------|---------------|--------------|-----------------------|-------------------|---------------|
| DEV本地 | Never | 1 | 600 | Allow | 1 |
| FAT测试 | OnFailure | 2 | 1200 | Allow | 2 |
| UAT预生产 | OnFailure | 2 | 1800 | Forbid | 3 |
| PROD生产 | OnFailure | 3 | 1800 | Forbid | 成功3个 / 失败5个 |

统一约束：
1. PROD定时任务强制 `concurrencyPolicy: Forbid`，防止多备份并发锁库；
2. 所有批任务配置 `activeDeadlineSeconds`，卡死任务自动终止释放资源；
3. 配置 `ttlSecondsAfterFinished` 自动清理完成Pod，避免堆积；
4. 生产定时任务避开业务高峰，优先凌晨低峰执行。

## 六、Job & CronJob 标准运维操作
### 6.1 一次性Job管理
```bash
# 创建一次性批任务
kubectl apply -f job-mysql-backup.yaml -n prod

# 查看Job执行状态
kubectl get jobs -n prod

# 查看任务Pod日志（定位失败原因）
kubectl logs job/mysql-backup-once -n prod

# 手动删除Job（连带删除Pod）
kubectl delete job mysql-backup-once -n prod
```

### 6.2 CronJob 定时任务管理
```bash
# 创建定时任务
kubectl apply -f cronjob-mysql-backup.yaml -n prod

# 查看所有定时任务
kubectl get cronjobs -n uat

# 手动立即触发一次调度（无需等待定时周期）
kubectl create job --from=cronjob/mysql-daily-backup manual-backup-$(date +%Y%m%d) -n prod

# 查看定时任务下所有历史Job
kubectl get jobs -n prod | grep mysql-daily-backup

# 暂停定时调度（不删除资源）
kubectl patch cronjob mysql-daily-backup -n prod -p '{"spec":{"suspend":true}}'

# 恢复调度
kubectl patch cronjob mysql-daily-backup -n prod -p '{"spec":{"suspend":false}}'

# 删除定时任务（历史Job不会自动删除，需手动清理）
kubectl delete cronjob mysql-daily-backup -n prod
```

### 6.3 批量清理完成/失败Job
```bash
# 清理所有已完成Job
kubectl delete jobs -n fat --field-selector status.successful=1
# 清理所有失败Job
kubectl delete jobs -n prod --field-selector status.failed=1
```

## 七、生产安全规范
1. 数据库备份、数据同步类定时任务**禁止并发**，统一使用 `Forbid`；
2. 必须配置执行超时 `activeDeadlineSeconds`，防止任务死循环占用存储/CPU；
3. 任务脚本、数据库账号存放于ConfigMap/Secret，禁止硬编码在yaml；
4. 备份文件持久化至PVC，禁止EmptyDir临时存储；
5. 定时任务变更前导出CronJob yaml备份，核心备份任务变更前执行etcd快照；
6. FAT环境定时任务可缩短周期频繁测试，PROD固定凌晨低峰执行；
7. NetworkPolicy限制定时任务仅访问对应中间件，禁止跨环境访问生产库。

## 八、高频故障排查
1. **CronJob 到点不生成Job**
   检查 `suspend=true` 暂停调度、cron表达式书写错误、startingDeadlineSeconds过期错过调度。
2. **Job反复失败，持续重启**
   backoffLimit未耗尽，查看Pod日志：SQL语句错误、数据库连接失败、存储PVC无写入权限。
3. **多任务并发导致数据库锁冲突**
   concurrencyPolicy未设置Forbid，修改为禁止并发策略。
4. **任务执行超时被强制杀死**
   activeDeadlineSeconds时长不足，调大超时阈值或优化任务执行效率。
5. 大量历史Job堆积占用集群资源
   successfulJobsHistoryLimit/failedJobsHistoryLimit数值过大，调小并批量清理旧Job。
6. **手动触发任务失败，镜像拉取失败**
   内网Harbor镜像缺失，核对镜像地址与标签。

## 九、运维速查命令
```bash
# 导出定时任务完整备份
kubectl get cronjob mysql-daily-backup -n prod -o yaml > cronjob-backup.yaml

# 查看所有命名空间失败Job
kubectl get jobs --all-namespaces --field-selector status.failed>=1

# 临时手动执行一次定时任务
kubectl create job --from=cronjob/mysql-daily-backup temp-job-$(date +%H%M) -n prod
```

## 十、关联文档
1. 前置基础：`02-pod-lifecycle.md` Pod重启策略、生命周期退出码
2. 资源管控：`07-resource-management.md` 批任务CPU/内存配额限制
3. 存储规范：PVC持久化存储文档（备份文件持久化）
4. 故障汇总：`10-workload-troubleshooting.md` Job启动失败、定时任务不调度排错