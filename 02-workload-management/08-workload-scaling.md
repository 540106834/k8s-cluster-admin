# 08-workload-scaling.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`03-deployment-management.md`、`07-resource-management.md`
- 集群环境：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：手动扩缩容、HPA自动伸缩（CPU/内存/自定义指标）、StatefulSet扩缩容、伸缩保护、分环境规范、伸缩故障排查

## 二、扩缩容底层理论
### 2.1 两种伸缩模式
1. **手动伸缩**：人工指定固定副本数，适用于流量平稳、预估变更场景；
2. **自动伸缩 HPA(HorizontalPodAutoscaler)**：根据监控指标动态调整副本，适配流量波动、突发峰值。

### 2.2 伸缩核心约束
1. 调度依据为 Pod `resources.requests`，limits 不参与调度计算；
2. 伸缩上限受命名空间 ResourceQuota `pods` 硬限制；
3. 滚动更新配合伸缩时，遵循 RollingUpdate maxSurge/maxUnavailable 策略；
4. StatefulSet有序伸缩，Deployment并行伸缩，DaemonSet无副本伸缩逻辑。

### 2.3 HPA 指标类型
1. 内置基础指标：CPU利用率、内存利用率（依赖metrics-server）；
2. 自定义指标：QPS、连接数、队列长度（需Prometheus Adapter）。

## 三、手动扩缩容操作（Deployment/StatefulSet）
### 3.1 Deployment 手动伸缩
```bash
# 临时扩容至5副本（仅临时生效，无版本管理）
kubectl scale deploy order-api --replicas=5 -n prod

# 标准规范：修改yaml文件apply持久保存（推荐）
kubectl apply -f deploy-order-prod.yaml
```

### 3.2 StatefulSet 手动伸缩（中间件）
```bash
# 扩容MySQL集群至4节点
kubectl scale sts mysql --replicas=4 -n prod
# 缩容至3节点（从大序号Pod依次销毁）
kubectl scale sts mysql --replicas=3 -n prod
```
> 中间件缩容前置校验：主从同步完成、无未同步数据，避免数据丢失。

### 3.3 查看副本变更进度
```bash
kubectl get deploy -n prod -w
kubectl get sts -n prod -w
```

## 四、HPA 自动伸缩完整模板
### 4.1 基础CPU+内存HPA模板（通用无状态服务）
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-api-hpa
  namespace: prod
  labels:
    app: order-api
    env: prod
spec:
  # 绑定目标Deployment
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-api
  # 副本上下限
  minReplicas: 3
  maxReplicas: 10
  # 冷却窗口：伸缩后等待5分钟再触发下一次伸缩，防止抖动
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 60
  # 指标阈值
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

### 4.2 自定义QPS指标HPA（流量网关/API服务）
```yaml
metrics:
- type: Pods
  pods:
    metric:
      name: http_requests_per_second
    target:
      type: AverageValue
      averageValue: 100m
```

### 4.3 StatefulSet HPA（中间件集群）
```yaml
scaleTargetRef:
  apiVersion: apps/v1
  kind: StatefulSet
  name: redis-cluster
```

## 五、HPA behavior 伸缩防抖配置说明
1. `scaleUp.stabilizationWindowSeconds`：扩容冷却，默认60s，突发流量快速扩容；
2. `scaleDown.stabilizationWindowSeconds`：缩容冷却，生产统一300s（5分钟），防止流量瞬间回落反复缩容；
3. 可配置伸缩速率限制：`policies` 控制单次最多增减副本数量。

## 六、分环境伸缩标准化规范
| 环境 | 伸缩方式 | minReplicas | maxReplicas | 缩容冷却窗口 | HPA启用 |
|------|----------|-------------|-------------|--------------|---------|
| DEV本地 | 仅手动scale | 1 | 2 | 无 | 关闭 |
| FAT测试 | 手动+HPA调试 | 2 | 5 | 120s | 可开启 |
| UAT预生产 | 对齐生产HPA配置 | 3 | 8 | 300s | 开启，模拟流量峰值 |
| PROD生产 | HPA自动伸缩为主，手动应急 | ≥3（核心服务5） | 业务峰值上限 | 300s强制 | 强制开启 |

### 生产硬性约束
1. 所有Web/API无状态服务必须配置HPA，禁止固定副本不弹性；
2. minReplicas保障基础承载，maxReplicas防止峰值无限扩容打满集群Quota；
3. 缩容冷却窗口统一5分钟，避免流量抖动频繁销毁Pod；
4. 数据库、Redis等StatefulSet不建议开启HPA，人工评估后手动伸缩。

## 七、HPA 运维操作命令
```bash
# 创建/更新HPA
kubectl apply -f hpa-order-prod.yaml -n prod

# 快速命令行创建基础HPA（临时调试）
kubectl autoscale deploy order-api --min=3 --max=10 --cpu-percent=70 -n prod

# 查看HPA实时指标、当前副本数
kubectl get hpa -n prod -w

# 查看HPA详细伸缩事件、指标采集情况
kubectl describe hpa order-api-hpa -n prod

# 临时关闭自动伸缩（调高min=max锁定副本）
kubectl patch hpa order-api-hpa -n prod -p '{"spec":{"minReplicas":5,"maxReplicas":5}}'

# 删除HPA（关闭自动伸缩）
kubectl delete hpa order-api-hpa -n prod
```

## 八、伸缩联动约束（Quota+滚动更新）
1. ResourceQuota `pods` 达到上限时，HPA无法扩容，事件抛出超限报错；
2. 扩容时遵循RollingUpdate maxSurge，瞬时副本可短暂高于max；
3. 缩容时执行pod驱逐，配合preStop优雅关闭，不中断存量请求；
4. LimitRange限制单Pod最大资源，扩容不会创建超规格容器。

## 九、高频伸缩故障排查
1. **HPA 副本数无变化，指标正常**
   - metrics-server异常，无CPU/内存指标；
   - ResourceQuota Pod数量打满；
   - maxReplicas已达上限。
2. **流量下降但不自动缩容**
   缩容冷却窗口未结束，等待stabilizationWindowSeconds到期；或内存指标持续高位。
3. **扩容瞬间大量Pod同时创建，节点压力飙升**
   配置scaleUp扩容速率策略，限制单次新增副本数量。
4. **StatefulSet HPA扩容卡死**
   PVC数量Quota耗尽，无法创建新存储卷。
5. **手动scale不生效，yaml apply后副本回弹**
   HPA锁定副本，min/max相等覆盖手动配置，需临时锁定HPA。
6. **HPA显示unknown指标**
   metrics-server Pod异常、kubelet鉴权失败、网络策略拦截metrics采集。

## 十、生产伸缩运维最佳实践
1. 业务低峰期下调maxReplicas，高峰前上调扩容上限；
2. 大促/活动提前人工扩容兜底，配合HPA双重保障；
3. 中间件StatefulSet扩容前校验存储池容量、主从同步机制；
4. 伸缩操作记录审计日志，HPA变更前导出yaml备份；
5. 监控HPA伸缩事件，频繁伸缩触发告警，排查流量抖动根源；
6. FAT环境每日自动缩容至最小副本节省资源，PROD维持min基础副本。

## 十一、运维速查命令
```bash
# 批量导出所有命名空间HPA备份
kubectl get hpa --all-namespaces -o yaml > all-hpa-backup.yaml

# 查看所有HPA实时指标
kubectl get hpa -A

# 查看伸缩事件日志
kubectl get events -n prod | grep HorizontalPodAutoscaler
```

## 十二、关联文档
1. 前置资源基础：`07-resource-management.md` requests/limits、ResourceQuota配额
2. 无状态负载：`03-deployment-management.md` 滚动更新策略
3. 有状态负载：`04-stateful-workloads.md` StatefulSet有序伸缩规则
4. 监控依赖：metrics-server部署文档（HPA指标数据源）
5. 发布迭代：`09-rollout-and-rollback.md` 伸缩配合版本发布流程
6. 故障汇总：`10-workload-troubleshooting.md` HPA无指标、扩容受限排错