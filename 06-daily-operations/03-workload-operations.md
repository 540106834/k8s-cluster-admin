# 03-workload-operations.md
## 一、文档基础信息
- 归属目录：`06-daily-operations/`
- 前置阅读：`00-README.md`、`01-kubectl-usage.md`、`02-resource-management.md`、`02-workload-management/`工作负载全套文档
- 集群基准：Kubernetes v1.32.13、Local SSD CSI、内网Harbor、GitOps发布流水线、RBAC最小权限
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：Deployment/StatefulSet/DaemonSet 滚动发布、版本回滚、手动扩缩容、分批重启、暂停/恢复发布、灰度分批发布、生产标准发布全流程、发布故障回滚、发布校验清单

## 二、工作负载操作底层核心原理
### 2.1 资源区分与操作边界
1. **Deployment（无状态微服务）**
    滚动更新机制：逐步销毁旧Pod、新建新版本Pod，支持零停机发布；缩容仅减少副本，PVC无需管理；
2. **StatefulSet（有状态中间件：MySQL/Redis/Kafka）**
    有序发布、有序扩缩容，缩容仅删除Pod、PVC自动保留；更新默认逐序重启Pod，IO敏感业务需手动分批操作；
3. **DaemonSet（节点采集组件：日志、监控、CSI）**
    所有节点同步部署Pod，更新会逐节点滚动重启，影响节点采集链路，必须低峰操作。

### 2.2 发布核心控制参数（统一标准）
```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 最大额外新增副本数
      maxUnavailable: 0  # 运行中不可用副本为0，生产零停机强制配置
```
- `maxUnavailable=0`：发布时不销毁运行Pod，先新建就绪再销毁旧Pod，业务无中断；
- StatefulSet无rollingUpdate参数，更新策略为`OnDelete`/`RollingUpdate`，默认逐序号重启。

### 2.3 操作分类
1. 发布升级：更新镜像/配置/资源限制 → rollout；
2. 回滚：发布异常退回上一稳定版本；
3. 扩缩容：手动调整副本数；
4. 重启：无配置变更，仅重载容器/配置；
5. 暂停/恢复：冻结发布，临时锁住资源变更。

## 三、标准操作完整模板与命令
### 3.1 Deployment 滚动发布（镜像更新）
1. 修改yaml镜像版本，执行下发
```bash
kubectl apply -f deploy-order-prod.yaml -n prod
# 实时观测发布进度
kubectl rollout status deployment order-api -n prod -w
```
2. 观测Pod就绪、业务日志无报错后发布完成。

### 3.2 查看发布历史记录（用于回滚）
```bash
kubectl rollout history deployment order-api -n prod
# 查看某一版本变更详情
kubectl rollout history deployment order-api --revision=2 -n prod
```

### 3.3 紧急回滚上一稳定版本
```bash
# 回滚到上一个revision
kubectl rollout undo deployment order-api -n prod
# 指定回滚至固定版本
kubectl rollout undo deployment order-api --to-revision=1 -n prod
```

### 3.4 手动扩缩容副本
```bash
# 扩容至10副本
kubectl scale deployment order-api --replicas=10 -n prod
# 缩容至3副本
kubectl scale deployment order-api --replicas=3 -n prod
```

### 3.5 仅重启Pod（配置文件挂载更新/热重载）
```bash
kubectl rollout restart deployment order-api -n prod
```

### 3.6 暂停发布（临时冻结变更，用于批量修改配置）
```bash
# 暂停
kubectl rollout pause deployment order-api -n prod
# 批量修改配置后恢复发布
kubectl rollout resume deployment order-api
```

### 3.7 StatefulSet 有序发布说明
1. 修改volumeClaimTemplates仅新扩容Pod生效，存量PVC不自动扩容；
2. STS滚动更新会从最大序号Pod开始重启，数据库业务建议分批手动重启避免IO阻塞；
```bash
# 单独重启指定序号Pod
kubectl delete pod mysql-2 -n prod
```

### 3.8 DaemonSet 节点组件发布
```bash
# 观测DS滚动更新进度
kubectl rollout status daemonset filebeat -n kube-system -w
```

## 四、分批灰度发布规范（PROD核心业务强制）
1. 业务低峰窗口执行；
2. 先缩容至少量副本验证新版本；
3. 分批逐步上调副本，每批间隔5分钟观测指标；
4. 异常立即执行rollout undo回滚；
示例流程：
```bash
# 1. 先缩容临时验证
kubectl scale deploy order-api --replicas=2 -n prod
# 2. 发布新版本
kubectl apply -f deploy-new.yaml -n prod
# 3. 分批扩容
kubectl scale deploy order-api --replicas=5 -n prod
sleep 300
kubectl scale deploy order-api --replicas=10 -n prod
```

## 五、DEV/FAT/UAT/PROD 发布操作分级基线
### DEV本地
无发布审批，可随意重启、重建、删除负载，无分批规范。
### FAT测试
1. 自由全量发布，无需分批灰度；
2. 可强制删除Pod快速调试；
3. 无需发布前备份，每日自动清理废弃负载。
### UAT预生产
1. 发布流程对齐生产，建议低峰执行；
2. 中间件STS分批重启，禁止一次性全量重启；
3. 发布前导出资源yaml备份，出现问题可回滚。
### PROD生产（强制红线）
1. 所有发布统一凌晨低峰窗口（02:00~05:00）；
2. 微服务Deployment强制`maxUnavailable:0`零停机发布；
3. MySQL/Redis等STS中间件分批重启，禁止一次性全量更新；
4. 核心业务执行灰度分批发布，不可一次性扩容全量副本；
5. 发布前校验：存储容量、PVC配额、数据库备份、证书有效期；
6. 发布、回滚、缩容高危操作双人复核，留存工单；
7. 发布全程观测CPU/内存/存储IO、业务日志、审计告警。

## 六、生产标准完整发布SOP
1. **前置校验**
   - 执行`kubectl auth can-i`校验操作权限；
   - 校验命名空间ResourceQuota存储/CPU配额充足；
   - 数据库执行全量逻辑备份/CSI快照；
   - 观测存储池剩余容量、节点资源水位；
2. **下发新版本资源**
   ```bash
   kubectl apply -f deploy-new.yaml -n prod
   ```
3. **实时观测发布进度**
   ```bash
   kubectl rollout status deploy order-api -n prod -w
   kubectl get events -n prod -w
   ```
4. **业务验证**
   - 查看Pod日志无报错；
   - 观测接口成功率、延迟、CPU内存指标；
5. **异常判定与回滚**
   日志大量报错、接口雪崩、存储IO打满 → 立即执行`rollout undo`回滚；
6. **发布完成归档**
   导出当前负载yaml备份，记录工单、发布时间、操作人。

## 七、高频运维操作命令汇总
```bash
# 查看发布历史版本
kubectl rollout history deploy order-api -n prod

# 实时跟踪发布进度
kubectl rollout status deploy order-api -n prod -w

# 回滚上一版本
kubectl rollout undo deploy order-api -n prod

# 扩缩容副本
kubectl scale deploy/sts ${name} --replicas=${num} -n ${ns}

# 仅重启所有Pod，不修改配置
kubectl rollout restart deploy order-api -n prod

# 暂停/恢复发布
kubectl rollout pause deploy order-api -n prod
kubectl rollout resume deploy order-api -n prod

# 查看StatefulSet与配套PVC
kubectl get sts,pvc -n prod
```

## 八、发布常见故障排查
### 1. 滚动发布卡住，新Pod无法就绪
1. 镜像拉取失败（Harbor密钥错误、镜像Tag不存在）；
2. PVC存储容量不足、准入控制PSS安全规则拦截；
3. 资源limits/requests超出节点可分配资源，调度失败。
### 2. 发布后业务大量报错，需要回滚
执行`kubectl rollout undo`快速退回上一稳定版本，同步排查代码/配置变更点。
### 3. StatefulSet更新后数据丢失
人工删除PVC，缩容STS不会自动清理PVC，正常发布不会丢失数据。
### 4. DaemonSet发布后节点采集中断
多节点同时重启采集Pod，业务低峰分批滚动更新DS。
### 5. rollout pause后发布不生效
未执行resume，变更被冻结，恢复后才会触发滚动更新。
### 6. maxUnavailable未配置为0，发布过程业务5xx突增
修改滚动策略`maxUnavailable:0`，重新下发资源，低峰重新发布。

## 九、生产发布最佳实践
1. 微服务统一配置`maxUnavailable:0`实现零停机滚动更新；
2. 数据库等有状态组件禁止一次性全量重启，分批操作错开IO高峰；
3. 核心业务采用灰度分批发布，降低故障影响范围；
4. 发布前执行全量数据备份，预留回滚方案；
5. 区分pause/resume用于批量配置修改，避免多次滚动重启；
6. 发布全程观测日志、指标、审计告警，异常立即回滚；
7. 所有发布操作纳入GitOps，禁止本地临时kubectl apply发布。

## 十、关联文档
1. 客户端工具：`01-kubectl-usage.md` 发布前权限预校验、dry-run模拟发布
2. 资源标签管理：`02-resource-management.md` 发布前后资源Label/Annotation更新规范
3. 配置管理：`02-workload-management/11-configuration-management.md` ConfigMap更新触发rollout restart流程
4. 存储管理：`04-storage-management/04-volume-operations.md` STS PVC扩容与发布操作配合规范
5. 日志调试：`06-daily-operations/04-logs-and-debug.md` 发布日志、事件排查手段
6. 安全准入：`05-security-management/03-admission-control.md` 违规镜像/安全上下文拦截导致发布失败
7. 运维巡检：`06-daily-operations/07-production-checklist.md` 发布前置校验完整清单