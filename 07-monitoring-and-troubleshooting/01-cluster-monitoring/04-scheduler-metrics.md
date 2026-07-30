# 01-cluster-monitoring/04-scheduler-metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/04-scheduler-metrics.md`
- 前置文档：`01-monitoring-architecture.md`、`02-api-server-metrics.md`、`03-etcd-metrics.md`
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Prometheus‑2.45、Prometheus Operator、离线内网部署
- 适用环境：DEV/FAT/UAT/PROD，管控平面组件遵循 **RED模型** 观测
- 文档范围：kube-scheduler指标采集配置、调度全链路分层指标、调度延迟/失败/排队指标、抢占/亲和性/驱逐细分指标、生产PrometheusRule告警、Grafana大盘、调度卡顿故障排查、多环境差异化配置

## 二、kube-scheduler指标采集配置（ServiceMonitor标准清单）
### 2.1 Metrics端点基础信息
1. 暴露地址：`https://<master>:10259/metrics`
2. 认证：TLS客户端证书，Prometheus Operator复用集群SA自动鉴权
3. 全局统一抓取参数
```yaml
interval: 15s
scrape_timeout: 10s
evaluation_interval: 15s
metrics_path: /metrics
scheme: https
```
4. 健康探针端点（仅存活校验，不采集时序指标）
- `/livez`：调度进程存活状态
- `/readyz`：可正常接收Pod调度请求

### 2.2 ServiceMonitor标准YAML（GitOps托管）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kube-scheduler
  namespace: kube-monitoring
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      app: kube-scheduler
  endpoints:
  - port: https-metrics
    scheme: https
    metricsPath: /metrics
    interval: 15s
    scrapeTimeout: 10s
    tlsConfig:
      serverName: kube-scheduler.kube-system.svc.cluster.local
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabelings:
    - sourceLabels: [__meta_kubernetes_endpoint_port_name]
      action: keep
      regex: https-metrics
```
> 说明：kube-scheduler为Master静态Pod，kube-system自动生成对应Service & Endpoint，无需静态抓取配置。

## 三、核心指标分层（RED模型标准划分）
### 3.1 Rate 调度速率（Pod调度吞吐）
核心指标：`scheduler_schedule_attempts_total`
标签维度：
- result：scheduled（调度成功）、unscheduled（调度失败）、error（调度异常）
- profile：调度器配置名称（默认default-scheduler）

常用PromQL：
```promql
# 5分钟总调度尝试速率
sum(rate(scheduler_schedule_attempts_total[5m]))
# 成功调度Pod QPS
sum(rate(scheduler_schedule_attempts_total{result="scheduled"}[5m]))
# 调度失败Pod总量速率
sum(rate(scheduler_schedule_attempts_total{result="unscheduled"}[5m]))
```

补充吞吐指标：
1. `scheduler_pod_queue_workers_seconds`：调度队列处理速率
2. `scheduler_pending_pods`：当前待调度Pending Pod实时数量（瞬时队列长度）

### 3.2 Errors 调度失败/拒绝（故障识别核心）
1. 调度失败细分原因指标 `scheduler_unscheduled_reason_total`
标签reason对应常见阻塞原因：
- NodeSelectorMismatch：节点标签不匹配
- InsufficientCPU/InsufficientMemory：资源不足
- TaintsTolerationsNotMatch：污点容忍不匹配
- PodToleratesNodeTaints：节点不可调度污点
- NodeAffinityViolation：节点亲和性不满足
- VolumeNodeConflict：存储卷节点绑定冲突
- MaxPodLimitExceeded：节点Pod数量上限打满

```promql
# 各类原因调度失败5分钟速率
sum by(reason)(rate(scheduler_unscheduled_reason_total[5m]))
# 资源不足类失败占比
sum(rate(scheduler_unscheduled_reason_total{reason=~"Insufficient.*"}[5m])) / sum(rate(scheduler_schedule_attempts_total[5m]))
```
2. 抢占失败指标 `scheduler_preemption_attempts_total{result="failed"}`
高优先级Pod无法抢占低优先级Pod资源
3. 内部调度错误 `scheduler_schedule_attempts_total{result="error"}`
调度器panic、API交互异常、准入校验崩溃

### 3.3 Duration 调度全链路延迟（直方图分位P50/P90/P99）
核心直方图：`scheduler_scheduling_algorithm_duration_seconds_bucket`
标准延迟基线阈值
| 百分位 | 正常基线 | Warning阈值 | Critical阈值 |
|--------|----------|-------------|--------------|
| P50    | <0.02s   | >0.1s       | >0.3s        |
| P90    | <0.05s   | >0.3s       | >0.8s        |
| P99    | <0.1s    | >0.8s       | >2s          |

分层延迟细分指标：
1. `scheduler_queue_wait_duration_seconds_bucket`：Pod在调度队列排队耗时
2. `scheduler_preemption_duration_seconds_bucket`：抢占计算耗时
3. `scheduler_predicate_evaluation_seconds_bucket`：预选Predicate过滤耗时
4. `scheduler_priority_evaluation_seconds_bucket`：优选Priority打分耗时

标准PromQL示例：
```promql
# 整体调度P99延迟
histogram_quantile(0.99, sum(rate(scheduler_scheduling_algorithm_duration_seconds_bucket[5m])) by (le))
# Predicate预选阶段P99耗时（节点过滤瓶颈）
histogram_quantile(0.99, sum(rate(scheduler_predicate_evaluation_seconds_bucket[5m])) by (le))
```

## 四、调度器专属细分关键指标（瓶颈定位）
### 4.1 Pending Pod队列（饱和度判断核心）
`scheduler_pending_pods`：实时未调度Pod总数
判定标准：持续>50 3分钟以上 → 调度拥堵，业务Pod无法启动

### 4.2 抢占调度指标（优先级业务）
1. `scheduler_preemption_attempts_total{result="succeeded"}`：抢占成功次数
2. `scheduler_preemption_victims`：每次抢占驱逐Pod数量
3. `scheduler_preemption_pod_violations_total`：抢占冲突约束计数

### 4.3 预选/优选性能拆分（调度卡顿根因）
1. Predicate预选（过滤不合格节点）
`scheduler_predicate_evaluation_seconds_bucket`，自定义复杂污点/标签/卷规则会大幅拉高耗时
2. Priority优选（节点打分排序）
`scheduler_priority_evaluation_seconds_bucket`，多权重打分插件（资源、亲和、反亲和）拉高延迟

### 4.4 调度器进程资源（USE模型补充）
kubelet容器采集指标，关联kube-scheduler Pod：
1. `container_cpu_usage_seconds_total`：调度器CPU占用，大规模集群Predicate计算会CPU打满
2. `container_memory_usage_bytes`：内存占用，大量缓存Node/Pod元数据易内存上涨
3. `container_file_descriptors`：文件句柄，大规模集群Watch API占用大量句柄

### 4.5 集群节点资源快照指标（配合kube-state-metrics）
联动指标：`kube_node_status_allocatable_cpu_cores` / `kube_node_status_allocatable_memory_bytes`
用于判断集群整体资源水位，区分是调度器性能瓶颈还是集群资源耗尽

## 五、生产级告警规则 PrometheusRule（对齐三层告警分层）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-scheduler-rules
  namespace: kube-monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  groups:
  - name: kube-scheduler.rules
    interval: 15s
    rules:
    # ========== Emergency 紧急（短信+企业微信双通知 7×24响应）==========
    - alert: KubeSchedulerDown
      expr: up{job="kube-scheduler"} == 0
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "kube-scheduler实例离线"
        message: "Master节点 {{ $labels.instance }} 调度器失联，新Pod全部无法调度"

    - alert: SchedulerMassUnscheduledPods
      expr: scheduler_pending_pods > 200
      for: 3m
      labels:
        severity: Emergency
      annotations:
        summary: "大量Pod处于Pending未调度"
        message: "待调度Pod总数{{ $value }}，集群资源耗尽/调度规则阻塞"

    # ========== Critical 严重（当日处理，业务扩容受阻）==========
    - alert: SchedulerP99LatencyHigh
      expr: histogram_quantile(0.99, sum(rate(scheduler_scheduling_algorithm_duration_seconds_bucket[5m])) by (le)) > 2
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "调度算法P99延迟超2s"
        message: "预选/优选逻辑卡顿，新建Pod调度缓慢"

    - alert: SchedulerHighUnscheduledRate
      expr: sum(rate(scheduler_unscheduled_reason_total[5m])) / sum(rate(scheduler_schedule_attempts_total[5m])) > 0.3
      for: 5m
      labels:
        severity: Critical
      annotations:
        summary: "调度失败占比超30%"
        message: "大量Pod无法匹配可用节点，检查资源、污点、亲和策略"

    - alert: SchedulerPreemptionFailedHigh
      expr: sum(rate(scheduler_preemption_attempts_total{result="failed"}[5m])) > 10
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "高优先级Pod抢占失败次数过多"

    # ========== Warning 预警（工作时段处理，无阻断影响）==========
    - alert: SchedulerPendingPodsWarning
      expr: scheduler_pending_pods > 50
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "Pending待调度Pod超过50个"

    - alert: SchedulerP90LatencyWarning
      expr: histogram_quantile(0.90, sum(rate(scheduler_scheduling_algorithm_duration_seconds_bucket[5m])) by (le)) > 0.3
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "调度P90延迟预警，调度性能缓慢上浮"

    - alert: SchedulerCpuHighWarning
      expr: sum(rate(container_cpu_usage_seconds_total{namespace="kube-system",container="kube-scheduler"}[5m])) / sum(kube_pod_container_resource_limits_cpu_cores{namespace="kube-system",container="kube-scheduler"}) > 0.85
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "kube-scheduler CPU使用率超85%"
```

## 六、Grafana大盘标准观测维度
1. 调度总览面板
    - 调度成功/失败总QPS趋势、实时Pending Pod数量
    - 调度器实例存活状态、CPU/内存资源使用率
    - P50/P90/P99整体调度延迟曲线
2. 调度失败细分面板
    - 按reason拆分调度失败TOP原因柱状图
    - 资源不足、污点、亲和性冲突失败占比
3. 性能拆分面板
    - 队列等待耗时、Predicate预选、Priority优选分位延迟
    - 抢占调度成功/失败次数、驱逐Pod数量
4. 集群资源水位面板
    - 节点总可分配CPU/内存、已分配占比
    - 节点不可调度污点数量、节点Pod上限占用
5. 容量观测面板
    - 每日新增调度Pod总量、长期Pending Pod增长趋势

## 七、多环境差异化配置（对齐顶层架构规范）
1. DEV环境
    - 无Prometheus Operator，仅metrics-server，无调度时序指标采集
    - 仅通过`kubectl get pods -A | grep Pending`人工查看未调度Pod
2. FAT环境
    - 部署kube-scheduler ServiceMonitor，无Thanos归档
    - 仅Warning/Critical告警，关闭Emergency短信，仅企业微信推送
    - 时序数据保留7天，不做长期容量趋势分析
3. UAT环境
    - 完整采集+全套PrometheusRule，告警阈值与生产完全一致
    - 全等级告警开启，仅企业微信通知，无短信
    - 数据保存30天，模拟业务扩容、抢占场景验证调度监控告警
4. PROD强制约束
    - Thanos归档调度指标至MinIO，存储180天，用于扩容故障回溯
    - ServiceMonitor、PrometheusRule统一GitOps托管，禁止临时修改
    - Emergency等级短信+企业微信双通道7×24推送
    - Alertmanager告警抑制：scheduler离线时，抑制所有Pod Pending相关衍生告警
    - 定期巡检调度Predicate耗时，清理冗余污点、复杂亲和规则降低调度延迟

## 八、监控采集与调度故障完整排查链路
### 8.1 kube-scheduler指标抓取失败 up=0
根因清单
1. Master NetworkPolicy拦截kube-monitoring命名空间访问10259端口
2. ServiceMonitor标签selector与kube-scheduler Service标签不匹配
3. TLS证书serverName配置错误，证书校验失败
4. kube-scheduler静态Pod崩溃、进程未正常启动

排查命令
```bash
# Prometheus Pod内手动连通测试
curl -k https://kube-scheduler.kube-system.svc.cluster.local:10259/metrics -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
# 查看调度器Pod运行状态
kubectl get pod -n kube-system -l app=kube-scheduler
# 校验kube-system网络策略放行监控组件
kubectl get netpol -n kube-system
```

### 8.2 大量Pod Pending调度故障下钻流程
1. 第一步：查看`scheduler_unscheduled_reason_total`，定位阻塞根因
    - 资源不足：扩容节点/调整Pod request
    - 污点不匹配：调整Pod tolerations或节点污点
    - 亲和冲突：修正Pod nodeAffinity/podAntiAffinity规则
2. 第二步：观测`scheduler_pending_pods`持续上涨，区分两类场景
    - 集群资源耗尽：查看节点allocatable资源水位
    - 调度性能瓶颈：Predicate/Priority延迟过高，简化调度规则
3. 第三步：抢占失败场景
    查看`scheduler_preemption_attempts_total{result="failed"}`，检查低优先级Pod驱逐约束、PodDisruptionBudget

### 8.3 调度延迟突增、CPU打满排查链路
1. 拆分Predicate/Priority阶段延迟，确认是过滤还是打分瓶颈
2. 清理冗余自定义污点、复杂反亲和规则、多存储卷绑定逻辑
3. 调高kube-scheduler CPU资源limit，拆分多调度器profile分担压力
4. 检查API Server LIST请求延迟，元数据拉取缓慢拖慢调度器

### 8.4 告警频繁误报优化方案
1. 全局抓取间隔统一15s，禁止高频抓取加重调度器API请求压力
2. 所有告警`for`延时最低3分钟，过滤瞬时批量创建Pod导致的抖动
3. Alertmanager配置定时批量创建Pod（CI/CD发布时段）告警静默规则

## 九、关联文档
1. 顶层架构：`01-monitoring-architecture.md` RED/USE模型、统一告警分层规范
2. 管控面依赖：`02-api-server-metrics.md` 调度器与APIServer Watch交互链路
3. 对象状态指标：`09-kube-state-metrics.md` Node/Pod资源分配状态指标
4. 故障方法论：`03-troubleshooting-methodology.md` 集群扩容、调度阻塞通用排查流程
5. PromQL速查：`10-cheatsheet/01-monitoring-cheatsheet.md` scheduler专用查询语句汇总
6. 集群健康巡检：`02-cluster-health-check` 定时检测Pending Pod脚本