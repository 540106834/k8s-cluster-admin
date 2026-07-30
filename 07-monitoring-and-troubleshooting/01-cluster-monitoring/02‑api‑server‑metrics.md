# 01‑cluster‑monitoring/02‑api‑server‑metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/02-api-server-metrics.md`
- 前置文档：`01-monitoring-architecture.md`、`06‑daily‑operations/05‑resource‑monitoring.md`
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Prometheus‑2.45、Prometheus Operator、离线内网部署
- 适用环境：DEV/FAT/UAT/PROD，统一遵循RED模型做指标观测
- 文档范围：apiserver指标采集配置、RED分层核心指标、内部队列/etcd交互/准入控制细分指标、生产PrometheusRule告警、Grafana大盘维度、故障排查链路、多环境差异化配置

## 二、APIServer指标采集配置（ServiceMonitor标准清单）
### 2.1 原生Metrics端点基础信息
1. 暴露地址：`https://<master-ip>:6443/metrics`
2. 认证方式：TLS客户端证书（Prometheus Operator内置集群SA证书自动签发）
3. 抓取标准参数（全局统一）
```yaml
interval: 15s
scrape_timeout: 10s
evaluation_interval: 15s
metrics_path: /metrics
scheme: https
tlsConfig:
  caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  serverName: kubernetes
```
4. 健康辅助端点（不进时序指标，用于探针）
    - `/livez`：存活探针，判断apiserver进程是否正常运行
    - `/readyz`：就绪探针，校验etcd连通、鉴权、准入控制器就绪状态
    - 弃用`/healthz`（K8s 1.16+废弃）

### 2.2 ServiceMonitor标准YAML（GitOps托管）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kube-apiserver
  namespace: kube-monitoring
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      app: kube-apiserver
  endpoints:
  - port: https
    scheme: https
    metricsPath: /metrics
    interval: 15s
    scrapeTimeout: 10s
    tlsConfig:
      serverName: kubernetes
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabelings:
    - sourceLabels: [__meta_kubernetes_endpoint_port_name]
      action: keep
      regex: https
```
> 采集说明：控制平面静态Pod自动生成Service Endpoint，无需静态配置；离线环境无需外网证书，复用集群内置SA凭证。

## 三、核心指标分层（严格遵循RED模型）
### 3.1 Rate 请求速率（QPS层）
核心指标：`apiserver_request_total`
标签维度：
- verb：GET/LIST/POST/PUT/DELETE/PATCH
- resource：pod/deployment/node/pvc/configmap等资源类型
- code：HTTP响应码 2xx/4xx/5xx
- namespace：请求所属命名空间（集群级资源为空）
- user：请求客户端账号（kubelet、controller-manager、业务sa）
- dry_run：是否为预提交请求

常用PromQL：
```promql
# 全量API总QPS（5分钟速率）
sum(rate(apiserver_request_total[5m]))

# 各资源LIST请求占比（高频慢请求元凶）
sum by(resource,verb)(rate(apiserver_request_total{verb="LIST"}[5m]))

# kubelet节点同步QPS
sum by(node)(rate(apiserver_request_total{user="system:kubelet"}[5m]))
```

### 3.2 Errors 错误率（故障识别核心）
1. 客户端错误（4xx：权限不足、资源不存在、参数非法）
```promql
# 4xx错误占比
sum(rate(apiserver_request_total{code=~"4.."}[5m])) / sum(rate(apiserver_request_total[5m]))
```
典型场景：RBAC权限缺失、非法yaml提交、删除不存在资源
2. 服务端错误（5xx：etcd超时、准入Webhook崩溃、内部panic）
```promql
# 5xx错误占比（核心告警指标）
sum(rate(apiserver_request_total{code=~"5.."}[5m])) / sum(rate(apiserver_request_total[5m]))
```
3. 请求拒绝指标：`apiserver_request_terminations_total`
    - label: termination_reason：TooLarge、Timeout、Canceled、WebhookError
4. 连接拒绝指标：`apiserver_rejected_requests_total`（限流、证书非法、IP黑名单）

### 3.3 Duration 请求延迟（分百分位P50/P90/P99/P999）
核心直方图指标：`apiserver_request_duration_seconds_bucket`
标准分层延迟阈值（生产基线）
| 百分位 | 正常基线 | Warning阈值 | Critical阈值 |
|--------|----------|-------------|--------------|
| P50    | <0.1s    | >0.3s       | >0.8s        |
| P90    | <0.3s    | >0.8s       | >1.5s        |
| P99    | <0.8s    | >1.5s       | >3s          |
| P999   | <1.5s    | >3s         | >5s          |

标准PromQL示例：
```promql
# API请求P99延迟
histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket[5m])) by (le,resource,verb))
# LIST操作P99延迟（最容易卡顿）
histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket{verb="LIST"}[5m])) by (le,resource))
```

## 四、APIServer内部细分关键指标（非RED，底层瓶颈定位）
### 4.1 工作队列 WorkQueue（请求堆积根因）
1. `workqueue_queue_duration_seconds_bucket`：队列等待耗时
2. `workqueue_unfinished_work_seconds`：队列积压未处理任务总耗时
3. `workqueue_depth`：当前队列堆积长度
> 生产判断标准：workqueue_depth持续>200 3分钟以上 → apiserver线程池耗尽，请求排队阻塞

### 4.2 ETCD交互指标（存储层瓶颈）
1. `etcd_request_duration_seconds_bucket`：etcd读写延迟，区分GET/PUT/DELETE
2. `etcd_client_go_sender_failed_total`：etcd连接失败、同步超时
3. `etcd_db_total_size_in_bytes`：etcd存储总容量，配合磁盘使用率做容量告警
4. `apiserver_storage_objects`：集群总资源对象数量（监控集群膨胀）

### 4.3 准入控制 Webhook 指标
1. `apiserver_admission_webhook_request_total`：Webhook调用总次数，区分success/fail
2. `apiserver_admission_webhook_latency_seconds_bucket`：Webhook回调延迟
3. `apiserver_admission_step_reject_total`：准入校验拒绝请求总数
> 故障特征：Webhook P99>2s → API全量请求延迟飙升

### 4.4 限流&并发控制指标
1. `apiserver_flowcontrol_current_inqueue_requests`：流量控制排队请求数
2. `apiserver_flowcontrol_rejected_requests_total`：流量控制拒绝请求（突发流量打满apiserver）
3. `apiserver_current_inflight_requests`：当前并发请求总数

### 4.5 进程资源指标（USE模型补充）
由kubelet metrics采集，关联apiserver Pod：
1. container_cpu_usage_seconds_total：apiserver CPU占用
2. container_memory_usage_bytes：内存占用（内存泄露观测）
3. container_file_descriptors：文件句柄数（大量长连接导致句柄耗尽）

## 五、生产级告警规则 PrometheusRule（全环境统一阈值）
遵循顶层文档`01-monitoring-architecture.md`三级告警分层：Warning/Critical/Emergency
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-apiserver-rules
  namespace: kube-monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  groups:
  - name: kube-apiserver.rules
    interval: 15s
    rules:
    # ========== Emergency 紧急（短信+企业微信双通知，7×24响应）==========
    - alert: KubeAPIServerDown
      expr: up{job="kube-apiserver"} == 0
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "API Server实例离线"
        message: "Master节点 {{ $labels.instance }} apiserver抓取失败，集群管控中断风险"

    - alert: KubeAPIServer5xxErrorHigh
      expr: sum(rate(apiserver_request_total{code=~"5.."}[5m])) / sum(rate(apiserver_request_total[5m])) > 0.05
      for: 3m
      labels:
        severity: Emergency
      annotations:
        summary: "API服务端错误率超5%"
        message: "API 5xx错误占比{{ $value }}, etcd故障/准入Webhook崩溃"

    - alert: APIServerFlowControlReject
      expr: sum(rate(apiserver_flowcontrol_rejected_requests_total[5m])) > 10
      for: 2m
      labels:
        severity: Emergency
      annotations:
        summary: "API流量控制大量拒绝请求"
        message: "突发流量超出apiserver并发上限，大量请求被限流丢弃"

    # ========== Critical 严重（当日必须处理，业务性能受损）==========
    - alert: KubeAPIServerP99LatencyHigh
      expr: histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket[5m])) by (le)) > 3
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "API P99延迟超3s"
        message: "API P99延迟{{ $value }}s，LIST请求/etcd慢查询导致管控卡顿"

    - alert: APIServerWorkQueueBacklog
      expr: sum(workqueue_depth{job="kube-apiserver"}) > 200
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "API工作队列堆积"
        message: "apiserver内部队列堆积{{ $value }}个任务，线程处理饱和"

    - alert: APIServerWebhookFailure
      expr: sum(rate(apiserver_admission_webhook_request_total{success="false"}[5m])) > 5
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "准入Webhook调用失败"
        message: "Webhook {{ $labels.name }} 大量回调失败，资源创建/更新被拦截"

    # ========== Warning 预警（工作时段处理，无业务影响）==========
    - alert: KubeAPIServerP90LatencyWarning
      expr: histogram_quantile(0.90, sum(rate(apiserver_request_duration_seconds_bucket[5m])) by (le)) > 0.8
      for: 5m
      labels:
        severity: Warning
      annotations:
        summary: "API P90延迟预警"
        message: "API P90延迟{{ $value }}s，基线上浮，需提前优化LIST查询"

    - alert: APIServer4xxErrorWarning
      expr: sum(rate(apiserver_request_total{code=~"4.."}[5m])) / sum(rate(apiserver_request_total[5m])) > 0.03
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "API客户端错误率偏高"
        message: "4xx错误占比{{ $value }}，检查RBAC权限、客户端非法请求"

    - alert: APIServerHighCpuWarning
      expr: sum(rate(container_cpu_usage_seconds_total{namespace="kube-system",container="kube-apiserver"}[5m])) / sum(kube_pod_container_resource_limits_cpu_cores{namespace="kube-system",container="kube-apiserver"}) > 0.85
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "API Server CPU使用率超85%"
```

## 六、Grafana大盘标准观测维度（生产固定看板）
1. 总览面板
    - API总QPS趋势、错误率（4xx/5xx分曲线）、P50/P90/P99延迟分位曲线
    - apiserver实例存活状态、CPU/内存资源使用率
2. 请求细分面板
    - 按verb（GET/LIST/POST）拆分QPS与延迟
    - 按资源类型（pod/deployment/node）拆分慢请求TOP10
    - 客户端账号（kubelet/控制器/业务SA）请求量排行
3. 底层瓶颈面板
    - WorkQueue队列深度、积压耗时趋势
    - ETCD读写延迟、失败请求数
    - 准入Webhook延迟与失败次数
    - 流量控制并发数、限流丢弃请求
4. 容量面板
    - 集群总资源对象数量增长曲线
    - etcd存储容量、文件句柄使用量

## 七、多环境差异化配置（对齐顶层文档DEV/FAT/UAT/PROD规范）
1. DEV环境
    - 不部署Prometheus Operator，仅metrics-server，无apiserver时序指标采集
    - 仅`kubectl top node/pod`查看瞬时资源，无告警、无大盘
2. FAT环境
    - 部署基础ServiceMonitor抓取apiserver指标，无Thanos
    - 仅开启Warning/Critical告警，关闭Emergency短信通知，仅企业微信推送
    - 时序数据保留7天，不做长期趋势回溯
3. UAT环境
    - 完整部署ServiceMonitor+PrometheusRule，告警阈值与生产完全一致
    - 开启全部告警等级，仅企业微信通知，无短信
    - 数据保存30天，复现生产监控行为用于预验证
4. PROD强制约束
    - 启用Thanos高可用，apiserver指标归档MinIO存储180天
    - ServiceMonitor、PrometheusRule全部GitOps托管，禁止本地修改
    - Emergency等级告警短信+企业微信双通道7×24推送
    - 搭配blackbox-exporter探测`/readyz`端点，补充指标监控盲区
    - 定期巡检apiserver LIST慢请求，提前优化控制器List/Watch缓存

## 八、监控采集常见故障与排查链路
### 8.1 APIServer指标抓取失败（up=0）
1. 根因清单
    - NetworkPolicy拦截kube-monitoring命名空间Pod访问6443端口
    - ServiceMonitor标签selector与apiserver Service标签不匹配
    - TLS证书过期、serverName配置错误
    - Master节点防火墙封禁6443端口
2. 排查链路
    ```bash
    # 1. 在prometheus pod内手动测试连通性
    curl -k https://kubernetes.default.svc:6443/metrics -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    # 2. 检查NetworkPolicy放行kube-monitoring
    kubectl get netpol -n kube-system
    # 3. 校验ServiceMonitor匹配标签
    kubectl get servicemonitor kube-apiserver -n kube-monitoring -o yaml
    ```

### 8.2 API延迟突增故障排查链路（RED模型下钻）
1. 第一步：区分错误类型
    - 5xx飙升 → 下钻etcd指标、准入Webhook失败数
    - 无5xx仅延迟上涨 → 查看LIST请求P99延迟、workqueue堆积
2. 第二步：定位慢请求资源
    PromQL筛选TOP慢资源：
    ```promql
    topk(10, histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket[5m])) by (le,resource,verb)))
    ```
3. 第三步：区分瓶颈层
    - Webhook延迟高 → 校验自定义准入控制器性能
    - etcd延迟高 → 查看etcd磁盘IO、快照同步状态
    - workqueue堆积 → apiserver线程池不足，调大并发参数

### 8.3 告警频繁误报优化方案
1. 抓取间隔统一15s，禁止5s高频抓取加重apiserver负载
2. 所有告警for延时最低3m，过滤瞬时流量抖动
3. 对每日定时控制器List峰值添加告警抑制规则（Alertmanager配置）

## 九、关联文档
1. 顶层架构：`01-monitoring-architecture.md`（监控整体框架、告警分层标准）
2. 存储层指标：`03-etcd-metrics.md`（etcd完整监控与告警）
3. 节点组件：`06-kubelet-metrics.md`
4. 故障方法论：`03-troubleshooting-methodology.md`
5. PromQL速查：`10-cheatsheet/01-monitoring-cheatsheet.md`（apiserver常用查询语句汇总）
6. 集群健康巡检：`02-cluster-health-check`（apiserver就绪探针巡检脚本）