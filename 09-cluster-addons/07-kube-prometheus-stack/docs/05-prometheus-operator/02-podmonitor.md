# docs/05-prometheus-operator/02-podmonitor.md
# PodMonitor 直采Pod指标配置规范手册
## 文档基础信息
- K8s 集群：v1.32
- Chart基线：kube-prometheus-stack-65.1.0
- 管控模式：GitOps + Helm + Prometheus Operator CRD
- 文档等级：★★★☆☆ 特殊场景采集规范
- 前置阅读：05-prometheus-operator/01-servicemonitor.md、04-workload/01-prometheus.md

## 目录
1. PodMonitor 原理与适用场景
2. PodMonitor 与 ServiceMonitor 核心差异对比
3. Prometheus 全局PodMonitor筛选规则
4. 标准完整PodMonitor YAML模板
5. 进阶采集配置（多端口、鉴权、TLS、自定义路径）
6. Relabel 分层处理规范（relabelings / metricRelabelings）
7. 典型落地场景模板（DaemonSet、宿主机Exporter、无Service负载）
8. 多环境差异化采集控制
9. 调试与故障排查流程
10. 最佳实践与禁止反模式
11. 关联文档索引

---

# 1. PodMonitor 原理与适用场景
## 1.1 工作数据流
```
Prometheus Operator 监听全集群 PodMonitor CRD
    ↓ 匹配 podMonitorSelector / podMonitorNamespaceSelector 筛选资源
        ↓ 根据PodMonitor标签规则直接匹配Pod资源（跳过Service/Endpoints）
            ↓ 读取Pod容器IP+容器端口生成采集目标
                ↓ Prometheus 周期性拉取 /metrics
```
## 1.2 适用场景（仅以下场景使用，其余统一ServiceMonitor）
1. DaemonSet组件：node-exporter、cadvisor、宿主机采集类组件，无业务Service；
2. 临时Job/CronJob：批量任务、一次性运行Pod，无需创建Service；
3. 网络隔离负载：Pod使用HostNetwork，无法通过Service转发访问metrics；
4. 无Service轻量化应用：测试Pod、Sidecar日志采集器，不对外提供业务端口；
5. 网格直采需求：ServiceMesh场景下需要直接访问Pod侧指标端口。

## 1.3 不适用场景
常规Deployment/StatefulSet业务应用、具备标准Service资源的中间件，统一使用ServiceMonitor。

# 2. PodMonitor vs ServiceMonitor 核心差异对比
| 对比项 | PodMonitor | ServiceMonitor |
|--------|------------|----------------|
| 发现源 | Pod 原生IP，直连容器 | Service → Endpoint → PodIP，四层转发 |
| 依赖资源 | 仅Pod，无需Service | 必须存在Service资源 |
| 端口匹配 | 匹配**容器端口名** | 匹配Service内部port名称 |
| HostNetwork适配 | 完美支持，直接采集宿主机IP | HostNetwork场景易出现端口冲突、转发异常 |
| 推荐优先级 | 特殊场景专用 | 业务标准首选 |
| 元标签 | `__meta_kubernetes_pod_*` 完整，无service标签 | 自带service、service_name标签，便于业务分组 |

# 3. Prometheus 全局PodMonitor筛选规则（values固化配置）
与ServiceMonitor隔离两套筛选器，互不干扰：
```yaml
prometheus:
  prometheusSpec:
    # 仅匹配带平台采集标签的PodMonitor
    podMonitorSelector:
      matchLabels:
        platform: monitor
    # 仅采集开启监控的命名空间
    podMonitorNamespaceSelector:
      matchLabels:
        monitor-enabled: "true"
    # 全局排除系统命名空间
    podMonitorNamespaceSelectorMatchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: [kube-system, kube-public]
```
约束：Namespace必须打标 `monitor-enabled: "true"`，否则该ns下所有PodMonitor失效。

# 4. 标准完整PodMonitor YAML模板
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ds-node-exporter-pm
  namespace: monitoring
  labels:
    platform: monitor # 强制匹配podMonitorSelector
    component: node-exporter
spec:
  # 匹配当前命名空间带标签的Pod
  selector:
    matchLabels:
      app: node-exporter
  # 限定采集命名空间
  namespaceSelector:
    matchNames:
      - monitoring
  # 采集端点配置
  podMetricsEndpoints:
    - port: metrics # 容器内端口名称，禁止数字硬编码
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      sampleLimit: 5000
      # 目标发现阶段标签处理
      relabelings:
        # 注入基础K8s元数据标签
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node_name
      # 指标落盘前过滤，控制存储容量
      metricRelabelings:
        - action: drop
          regex: ".*_bucket|.*_sum|.*_count"
          sourceLabels: [__name__]
```
## 强制字段约束
1. metadata.labels 必须携带 `platform: monitor`；
2. podMetricsEndpoints.port 使用容器端口名，禁止直接填写端口数字；
3. 必须配置relabelings注入node/pod/namespace元标签；
4. 默认开启metricRelabelings丢弃直方图桶指标。

# 5. 进阶采集配置
## 5.1 多容器端口同时采集
```yaml
podMetricsEndpoints:
  - port: metrics
    path: /metrics
  - port: admin-metrics
    path: /internal/metrics
```
## 5.2 SpringBoot非标准指标路径
```yaml
podMetricsEndpoints:
  - port: metrics
    path: /actuator/prometheus
```
## 5.3 Metrics接口BasicAuth鉴权
Secret存放于PodMonitor同命名空间：
```yaml
podMetricsEndpoints:
  - port: metrics
    basicAuth:
      username:
        name: metrics-auth
        key: username
      password:
        name: metrics-auth
        key: password
```
## 5.4 HTTPS TLS自签证书采集
```yaml
podMetricsEndpoints:
  - port: metrics
    scheme: https
    tlsConfig:
      insecureSkipVerify: true
```
## 5.5 高频自定义抓取间隔（10s）
```yaml
podMetricsEndpoints:
  - port: metrics
    interval: 10s
    scrapeTimeout: 3s
```

# 6. Relabel 分层处理规范
## 6.1 relabelings（目标发现阶段，抓取执行前）
作用：筛选Pod、注入节点/Pod/命名空间元标签、过滤测试实例Pod；
示例：过滤env=test标签的Pod，不采集测试实例
```yaml
relabelings:
  - sourceLabels: [__meta_kubernetes_pod_label_env]
    regex: test
    action: drop
```

## 6.2 metricRelabelings（指标抓取完成，写入TSDB前）
作用：丢弃大体积直方图指标、过滤无用临时指标，降低NFS存储压力；
全局统一规则，所有PodMonitor必须配置：
```yaml
metricRelabelings:
  - action: drop
    sourceLabels: [__name__]
    regex: '.*_bucket$'
```

# 7. 典型落地场景模板
## 7.1 DaemonSet node-exporter 宿主机采集
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: node-exporter-pm
  namespace: monitoring
  labels:
    platform: monitor
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-exporter
  namespaceSelector:
    matchNames: [monitoring]
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
```

## 7.2 HostNetwork 宿主机日志采集Sidecar
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: filebeat-pm
  namespace: logging
  labels:
    platform: monitor
spec:
  selector:
    matchLabels:
      app: filebeat
  podMetricsEndpoints:
    - port: metrics
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_annotation_kubernetes_io_hostname]
          targetLabel: host
```

## 7.3 CronJob定时任务临时Pod采集
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cronjob-task-pm
  namespace: batch
  labels:
    platform: monitor
spec:
  selector:
    matchLabels:
      job-type: data-sync
  podMetricsEndpoints:
    - port: metrics
      interval: 60s # 低频抓取，减少资源消耗
```

# 8. 多环境差异化采集控制
## 8.1 Dev环境低频抓取、精简指标
```yaml
podMetricsEndpoints:
  - port: metrics
    interval: 30s
    relabelings:
      - sourceLabels: [__meta_kubernetes_namespace]
        regex: dev-.*
        action: replace
        targetLabel: scrape_interval
        replacement: 60s
    metricRelabelings:
      # Dev环境丢弃所有直方图指标
      - sourceLabels: [env]
        regex: dev
        action: drop
        sourceLabels: [__name__]
        regex: ".*_bucket|.*_sum|.*_count"
```

# 9. 调试与故障排查完整流程
## 9.1 校验PodMonitor资源是否被Operator识别
```bash
# 查看集群所有PodMonitor，确认platform:monitor标签存在
kubectl get podmonitor -A --show-labels

# 校验命名空间监控开关标签
kubectl get ns --show-labels | grep monitor-enabled
```
## 9.2 Prometheus UI目标状态校验
访问 Prometheus UI → Status → Targets：
1. UP：采集正常；
2. DOWN：Pod端口未开放、网络策略拦截、鉴权失败；
3. Dropped：被relabel规则过滤。

## 9.3 实时日志定位抓取报错
```bash
kubectl logs -f statefulset/kube-monitor-prometheus-0 -n monitoring | grep scrape
```

## 9.4 集群内手动连通性测试
```bash
# 临时测试Pod，直接访问Pod IP metrics端口
kubectl run curl-test --image=curlimages/curl --rm -it -n monitoring
curl http://10.244.1.10:9100/metrics
```

# 10. 最佳实践与禁止反模式
## 10.1 强制最佳实践
1. 仅无Service、DaemonSet、HostNetwork场景使用PodMonitor，业务应用优先ServiceMonitor；
2. 所有PodMonitor统一携带 `platform: monitor` 标签；
3. podMetricsEndpoints使用容器端口名，不硬编码数字端口；
4. 全部配置relabelings注入node/pod/namespace元标签；
5. 默认启用metricRelabelings丢弃直方图bucket指标；
6. 一个PodMonitor只匹配一类组件，不混用多业务Pod筛选规则。

## 10.2 严格禁止反模式
1. 常规Deployment业务负载使用PodMonitor；
2. PodMonitor缺失 `platform: monitor` 标签，无法被Prometheus发现；
3. podMetricsEndpoints.port直接填写数字（port: 9100）；
4. 单PodMonitor匹配数十种不同业务Pod，配置臃肿；
5. 不配置metricRelabelings，无限制存储海量直方图指标；
6. 直接采集kube-system系统Pod，系统组件单独维护独立PodMonitor。

# 11. 关联文档索引
1. 标准业务采集规范 ServiceMonitor：05-prometheus-operator/01-servicemonitor.md
2. Prometheus全局抓取、筛选配置：04-workload/01-prometheus.md
3. 告警规则 PrometheusRule：05-prometheus-operator/03-prometheusrule.md
4. TSDB存储与数据留存策略：03-storage/02-data-retention.md
5. 采集目标故障排查手册：09-troubleshooting/02-prometheus-error.md