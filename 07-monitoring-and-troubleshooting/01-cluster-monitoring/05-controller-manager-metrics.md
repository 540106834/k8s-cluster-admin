# 01-cluster-monitoring/05-controller-manager-metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/05-controller-manager-metrics.md`
- 前置文档：`01-monitoring-architecture.md`、`02-api-server-metrics.md`、`04-scheduler-metrics.md`
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Prometheus‑2.45、Prometheus Operator、离线内网部署
- 适用环境：DEV/FAT/UAT/PROD，管控平面组件统一使用 **RED模型** 观测
- 文档范围：kube-controller-manager指标采集配置、控制器队列分层指标、同步延迟/失败率、各类内置控制器细分指标、工作队列饱和度、生产告警规则、Grafana大盘、控制器卡顿故障排查、多环境差异化策略

## 二、kube-controller-manager指标采集配置
### 2.1 Metrics端点基础信息
1. 指标地址：`https://<master>:10257/metrics`
2. 认证方式：TLS双向证书，Prometheus Operator自动挂载SA凭证鉴权
3. 全局标准抓取参数
```yaml
interval: 15s
scrape_timeout: 10s
evaluation_interval: 15s
metrics_path: /metrics
scheme: https
```
4. 健康探针（仅存活校验，不采集时序指标）
- `/livez`：控制器进程存活
- `/readyz`：各控制器队列正常同步、APIServer/etcd通信正常

### 2.2 ServiceMonitor GitOps标准YAML
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kube-controller-manager
  namespace: kube-monitoring
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      app: kube-controller-manager
  endpoints:
  - port: https-metrics
    scheme: https
    metricsPath: /metrics
    interval: 15s
    scrapeTimeout: 10s
    tlsConfig:
      serverName: kube-controller-manager.kube-system.svc.cluster.local
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabelings:
    - sourceLabels: [__meta_kubernetes_endpoint_port_name]
      action: keep
      regex: https-metrics
```
> 说明：kube-controller-manager为Master静态Pod，kube-system自动生成Service与Endpoint，无需静态抓取配置。

## 三、核心指标分层（RED模型）
### 3.1 Rate 控制器同步吞吐（工作队列处理速率）
核心指标：`workqueue_adds_total`
标签：name（控制器队列名称，deployment、replicaset、node、pvc等）
```promql
# 所有控制器5分钟入队速率
sum by(name)(rate(workqueue_adds_total[5m]))
# Deployment控制器同步任务速率
sum(rate(workqueue_adds_total{name="deployment"}[5m]))
```
配套吞吐指标：
- `workqueue_process_duration_seconds_bucket`：任务处理总耗时直方图
- `workqueue_queue_duration_seconds_bucket`：任务在队列等待耗时

### 3.2 Errors 控制器同步失败（故障定位核心）
1. 队列处理失败总指标 `workqueue_process_errors_total`
```promql
# 各控制器同步失败速率
sum by(name)(rate(workqueue_process_errors_total[5m]))
# 失败任务占比
sum(rate(workqueue_process_errors_total[5m])) / sum(rate(workqueue_adds_total[5m]))
```
2. 重入队指标 `workqueue_retries_total`：任务处理失败后重新放回队列重试
重试持续上涨代表控制器逻辑异常、API/etcd超时、资源权限缺失
3. 资源同步失败细分指标
- `deployment_status_update_failure_total`：Deployment状态更新失败
- `replicaset_sync_failure_total`：副本集同步失败
- `persistentvolume_sync_error_total`：PV/PVC存储控制器同步报错
- `node_controller_eviction_failed_total`：节点驱逐失败

### 3.3 Duration 同步延迟（P50/P90/P99分位）
基线阈值（所有控制器统一标准）
| 百分位 | 正常基线 | Warning阈值 | Critical阈值 |
|--------|----------|-------------|--------------|
| P50    | <0.05s   | >0.2s       | >0.5s        |
| P90    | <0.1s    | >0.5s       | >1s          |
| P99    | <0.3s    | >1s         | >3s          |

核心PromQL：
```promql
# Deployment控制器任务P99处理延迟
histogram_quantile(0.99, sum(rate(workqueue_process_duration_seconds_bucket{name="deployment"}[5m])) by (le))
# 队列等待P99延迟（堆积核心判断依据）
histogram_quantile(0.99, sum(rate(workqueue_queue_duration_seconds_bucket[5m])) by (le,name))
```

## 四、工作队列饱和度指标（USE模型核心）
### 4.1 队列深度（实时积压任务）
`workqueue_depth{name=~".+"}`
判定标准：单一控制器队列持续>100，维持3分钟以上 → 控制器处理能力不足，资源同步停滞
### 4.2 未完成任务总耗时
`workqueue_unfinished_work_seconds`
数值持续走高代表大量任务长时间阻塞未处理
### 4.3 队列长等待告警指标
`workqueue_longest_running_processor_seconds`
单任务处理超时，卡住整个控制器队列消费

## 五、内置控制器细分业务指标
### 5.1 Deployment/ReplicaSet 副本控制器
1. `deployment_status_replicas_updated`：已更新就绪副本数
2. `deployment_status_replicas_unavailable`：不可用副本数量
3. `replicaset_orphan_replicas_total`：孤立未清理副本集（资源泄露）
### 5.2 Node节点控制器
1. `node_controller_node_evictions_total`：节点驱逐Pod总数
2. `node_controller_unreachable_nodes`：失联未就绪节点计数
3. `node_lease_update_failure_total`：节点Lease续约失败
### 5.3 PV/PVC存储控制器
1. `persistentvolume_bind_failure_total`：PVC绑定PV失败
2. `storageclass_provision_failure_total`：存储类动态扩容失败
3. `volume_attach_error_total`：存储卷挂载失败
### 5.4 命名空间/垃圾回收控制器
1. `namespace_terminating_seconds`：命名空间删除滞留时长
2. `garbage_collector_orphan_objects_total`：未清理孤儿资源
### 5.5 HPA自动扩缩容控制器
1. `hpa_sync_failure_total`：HPA状态同步失败
2. `hpa_replica_adjustment_total`：副本调整次数
3. `hpa_target_metric_fetch_failure_total`：指标拉取失败

## 六、进程资源USE指标（容器层）
由kubelet metrics采集，绑定kube-controller-manager Pod
1. `container_cpu_usage_seconds_total`：控制器CPU占用，大量队列重试会持续打满CPU
2. `container_memory_usage_bytes`：内存占用，长时间队列堆积易造成内存持续上涨
3. `container_file_descriptors`：文件句柄，大量Watch API消耗句柄资源

## 七、生产PrometheusRule告警规则（三层告警对齐顶层规范）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-controller-manager-rules
  namespace: kube-monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  groups:
  - name: kube-controller-manager.rules
    interval: 15s
    rules:
    # ========== Emergency 紧急（短信+企业微信双通道 7×24）==========
    - alert: KubeControllerManagerDown
      expr: up{job="kube-controller-manager"} == 0
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "控制器管理器实例离线"
        message: "Master {{$labels.instance}} controller-manager失联，副本、存储、节点驱逐全部失效"

    - alert: ControllerMassQueueBacklog
      expr: max(workqueue_depth) by (name) > 500
      for: 3m
      labels:
        severity: Emergency
      annotations:
        summary: "控制器队列严重堆积"
        message: "队列 {{$labels.name}} 积压任务 {{$value}}，资源同步完全停滞"

    # ========== Critical 严重（当日必须处理，业务发布/存储故障）==========
    - alert: ControllerProcessErrorHigh
      expr: sum by(name)(rate(workqueue_process_errors_total[5m])) > 20
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "控制器同步任务频繁失败"
        message: "队列 {{$labels.name}} 同步错误持续发生，副本更新、存储绑定失效"

    - alert: ControllerP99ProcessLatencyHigh
      expr: histogram_quantile(0.99, sum(rate(workqueue_process_duration_seconds_bucket[5m])) by (le,name)) > 3
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "控制器任务P99延迟超3s"

    - alert: StorageProvisionFailed
      expr: sum(rate(storageclass_provision_failure_total[5m])) > 5
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "存储动态供给频繁失败，PVC无法绑定PV"

    # ========== Warning 预警（工作时段处理，无阻断影响）==========
    - alert: ControllerQueueBacklogWarning
      expr: max(workqueue_depth) by (name) > 100
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "控制器队列轻度积压 {{$value}}"

    - alert: ControllerP90LatencyWarning
      expr: histogram_quantile(0.90, sum(rate(workqueue_process_duration_seconds_bucket[5m])) by (le,name)) > 0.5
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "控制器任务P90延迟预警"

    - alert: ControllerCpuHighWarning
      expr: sum(rate(container_cpu_usage_seconds_total{namespace="kube-system",container="kube-controller-manager"}[5m])) / sum(kube_pod_container_resource_limits_cpu_cores{namespace="kube-system",container="kube-controller-manager"}) > 0.85
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "controller-manager CPU使用率超85%"
```

## 八、Grafana大盘观测维度
1. 控制器总览面板
    - 所有队列入队/处理/失败QPS趋势
    - 实例存活状态、CPU/内存资源占用曲线
    - 全队列P50/P90/P99延迟总曲线
2. 队列饱和度面板
    - 各控制器实时队列深度TOP10排行
    - 未完成任务总耗时、最长阻塞任务时长
    - 任务重试次数趋势
3. 细分控制器业务面板
    - Deployment副本更新/不可用副本曲线
    - PV/PVC绑定、存储供给失败计数
    - 节点驱逐、失联节点数量
    - HPA扩缩容失败次数
4. 故障定位面板
    - 按控制器拆分同步失败原因、失败占比
    - 孤立副本、孤儿资源、滞留命名空间计数

## 九、多环境差异化配置（统一对齐顶层架构）
1. DEV环境
    - 无Prometheus Operator，仅metrics-server，无控制器时序指标采集
    - 故障人工查看`kubectl describe deploy/pvc/node`排查同步异常
2. FAT环境
    - 部署controller-manager ServiceMonitor，无Thanos长期归档
    - 仅Warning/Critical告警，关闭Emergency短信，仅企业微信推送
    - 时序数据保留7天，不做长期容量观测
3. UAT环境
    - 完整采集+全套PrometheusRule，告警阈值与生产完全一致
    - 全等级告警开启，仅企业微信通知，无短信
    - 数据保存30天，模拟发布扩容、存储故障验证告警触发
4. PROD强制约束
    - Thanos归档控制器指标至MinIO，存储180天，用于发布故障回溯
    - ServiceMonitor、PrometheusRule全部GitOps托管，禁止临时修改
    - Emergency等级短信+企业微信双通道7×24推送
    - Alertmanager告警抑制：controller-manager离线时，抑制PVC绑定失败、副本更新失败衍生告警
    - 定期巡检高延迟控制器队列，拆分重负载控制器、调大队列并发worker

## 十、监控采集与故障完整排查链路
### 10.1 controller-manager指标抓取失败 up=0
根因清单
1. Master节点NetworkPolicy拦截kube-monitoring访问10257端口
2. ServiceMonitor标签selector与controller-manager Service不匹配
3. TLS证书serverName配置错误，证书校验失败
4. kube-controller-manager静态Pod崩溃、进程异常退出

排查测试命令
```bash
# Prometheus Pod内手动连通测试
curl -k https://kube-controller-manager.kube-system.svc.cluster.local:10257/metrics -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
# 查看控制器Pod运行日志
kubectl logs -n kube-system kube-controller-manager-master-0
# 校验kube-system命名空间网络策略放行监控组件
kubectl get netpol -n kube-system
```

### 10.2 控制器队列大量积压故障下钻流程
1. 定位积压队列名称（workqueue_depth TOP10）
2. 查看workqueue_process_errors_total、workqueue_retries_total，判断是否持续重试失败
3. 分层定位根因：
    - API/etcd延迟高 → 查看apiserver/etcd监控指标
    - RBAC权限缺失 → 控制器日志报权限拒绝
    - 存储CSI异常 → 存储控制器挂载失败指标上涨
4. 优化手段：调大控制器并发worker、拆分高负载控制器、修复API访问权限

### 10.3 PVC无法绑定、存储供给失败排查链路
1. 查看`storageclass_provision_failure_total`失败速率
2. 联动node-exporter磁盘IO指标，确认存储节点磁盘饱和
3. 核查CSI控制器日志、StorageClass配置参数、云存储API连通性

### 10.4 告警误报优化方案
1. 全局抓取间隔统一15s，禁止5s高频抓取增加控制器API压力
2. 所有告警`for`延时最低3分钟，过滤批量发布瞬时队列峰值
3. 发布时段配置Alertmanager静默规则，抑制临时副本同步抖动告警

## 十一、关联文档
1. 顶层架构：`01-monitoring-architecture.md` RED/USE模型、统一告警分层规范
2. 管控依赖：`02-api-server-metrics.md` 控制器与APIServer Watch交互链路
3. 对象状态指标：`09-kube-state-metrics.md` Deployment/PVC/Node静态资源指标
4. 存储监控：后续`storage-monitoring` CSI/PV/PVC监控文档
5. 故障方法论：`03-troubleshooting-methodology.md` 资源同步类故障通用排查流程
6. PromQL速查：`10-cheatsheet/01-monitoring-cheatsheet.md` controller-manager专用查询汇总
7. 集群健康巡检：`02-cluster-health-check` 定时检测滞留PVC、不可用副本脚本