# docs/05-prometheus-operator/01-servicemonitor.md
# ServiceMonitor 标准化采集配置规范手册
## 文档基础信息
- K8s 集群：v1.32
- Chart：kube-prometheus-stack-65.1.0
- 管控模式：GitOps + Helm + PrometheusOperator CRD
- 文档等级：★★★★★ 业务采集核心规范
- 前置阅读：04-workload/01-prometheus.md

## 目录
1. ServiceMonitor 核心原理与数据流
2. 全局匹配过滤规则（Prometheus侧Selector）
3. 标准完整 ServiceMonitor YAML 模板
4. 多采集端口、多路径、TLS/基础鉴权配置
5. Relabel 标签预处理分层规范
6. 业务侧 Service 规范约束（metrics端口命名、标签）
7. PodMonitor vs ServiceMonitor 选型区分
8. 多环境差异化采集控制
9. 采集调试排障流程
10. 最佳实践与禁用反模式
11. 关联文档索引

---

# 1. ServiceMonitor 核心原理与数据流
## 1.1 工作链路
```
PrometheusOperator
  监听全集群 ServiceMonitor CRD
    ↓ 筛选符合 serviceMonitorSelector 的资源
      ↓ 根据 ServiceMonitor 定义匹配后端 Service
        ↓ 获取 Service 关联 Endpoints/Pod IP
          ↓ 生成 Prometheus 原生 scrape target 配置
            ↓ Prometheus 周期性拉取 /metrics
```
## 1.2 核心优势
1. 声明式CRD，无需手写prometheus.yml；
2. 动态发现Pod扩缩容，自动更新采集目标；
3. 统一鉴权、TLS、抓取间隔配置，复用模板；
4. GitOps统一管控，业务无需修改Prometheus主配置。
## 1.3 依赖前置条件
1. 业务必须创建Service资源；
2. Service暴露metrics专用端口；
3. Namespace/ServiceMonitor携带匹配标签，放行Prometheus发现。

# 2. 全局匹配过滤规则（Prometheus侧）
## 2.1 Prometheus CRD 顶层筛选配置（values固定）
```yaml
prometheus:
  prometheusSpec:
    # 只匹配带 platform: monitor 标签的 ServiceMonitor
    serviceMonitorSelector:
      matchLabels:
        platform: monitor
    # 只采集带 monitor-enabled=true 的命名空间
    serviceMonitorNamespaceSelector:
      matchLabels:
        monitor-enabled: "true"
    # 排除指定命名空间，兜底拦截集群内部组件
    serviceMonitorNamespaceSelectorMatchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: [kube-system, kube-public]
```
## 2.2 命名空间标签下发
业务Namespace创建时必须打标签：
```yaml
metadata:
  labels:
    monitor-enabled: "true"
```
未打标命名空间下所有ServiceMonitor直接被忽略，不生成采集目标。

# 3. 标准完整 ServiceMonitor YAML 模板
## 3.1 通用业务标准模板
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: business-api-sm
  namespace: business
  labels:
    platform: monitor  # 必须匹配Prometheus serviceMonitorSelector
    app: business-api
spec:
  # 匹配当前命名空间内带标签的Service
  selector:
    matchLabels:
      app: business-api
  # 仅当前命名空间
  namespaceSelector:
    matchNames:
      - business
  # 采集端口定义
  endpoints:
    - port: metrics          # Service内端口名，禁止直接写端口号
      path: /metrics
      interval: 30s          # 抓取周期，与全局保持一致
      scrapeTimeout: 10s
      sampleLimit: 5000      # 单目标采样上限，防Exporter爆量
      # 发现阶段标签重标记
      relabelings:
        - sourceLabels: [__meta_kubernetes_service_name]
          targetLabel: service_name
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
      # 写入前过滤无用指标
      metricRelabelings:
        - action: drop
          regex: ".*_bucket|.*_sum|.*_count"
          sourceLabels: [__name__]
```
## 3.2 字段强制约束
1. metadata.labels 必须包含 `platform: monitor`；
2. endpoints.port 使用端口名称，禁止硬编码数字；
3. 必须配置 relabelings 注入service/pod/ns业务标签；
4. 默认开启metricRelabelings丢弃直方图桶指标，降低存储压力。

# 4. 进阶采集配置场景
## 4.1 多端口同时采集（业务端口 + metrics端口分离）
```yaml
endpoints:
  - port: metrics
    path: /metrics
  - port: admin-metrics
    path: /internal/metrics
```
## 4.2 非标准metrics路径
```yaml
endpoints:
  - port: metrics
    path: /actuator/prometheus # SpringBoot Actuator专用路径
```
## 4.3 metrics接口开启BasicAuth鉴权
密钥存放当前命名空间Secret：
```yaml
endpoints:
  - port: metrics
    basicAuth:
      username:
        name: metrics-auth
        key: username
      password:
        name: metrics-auth
        key: password
```
## 4.4 TLS加密metrics端点
```yaml
endpoints:
  - port: metrics
    scheme: https
    tlsConfig:
      insecureSkipVerify: true # 内部自签证书使用
```
## 4.5 自定义抓取间隔（高频业务10s）
```yaml
endpoints:
  - port: metrics
    interval: 10s
    scrapeTimeout: 3s
```

# 5. Relabel 分层规范（两层严格区分）
## 5.1 relabelings：目标发现阶段（抓取前）
作用：修改/过滤采集目标，注入K8s元数据标签
常用规则：
- 注入namespace/service/pod标签用于区分业务；
- 按标签drop不需要采集的Pod副本；
示例：过滤测试实例Pod
```yaml
relabelings:
  - sourceLabels: [__meta_kubernetes_pod_label_env]
    regex: test
    action: drop
```
## 5.2 metricRelabelings：指标落盘前（抓取成功后）
作用：过滤、修改时序指标，减少TSDB存储开销
标准规则统一启用：丢弃直方图bucket指标
```yaml
metricRelabelings:
  - action: drop
    sourceLabels: [__name__]
    regex: '.*_bucket$'
```

# 6. 业务侧 Service 规范约束
## 6.1 Service 端口命名强制规范
metrics端口统一命名为 `metrics`，禁止随意命名：
```yaml
ports:
  - name: metrics
    port: 9090
    targetPort: 9090
```
## 6.2 Service 标签规范
必须携带业务标识标签，用于ServiceMonitor匹配：
```yaml
metadata:
  labels:
    app: business-api
    env: prod
```
## 6.3 应用Pod规范
容器必须暴露metrics端口，容器args启动开启prometheus指标输出；
禁止仅宿主机网络模式无法通过Service访问metrics。

# 7. PodMonitor vs ServiceMonitor 选型区分
| 类型 | 适用场景 | 底层发现对象 | 推荐优先级 |
|------|----------|--------------|------------|
| ServiceMonitor | 常规Deployment/StatefulSet，已部署标准Service | Service → Endpoints | ★★★★★ 默认首选 |
| PodMonitor | DaemonSet、无Service临时Pod、宿主机Exporter、网络不通Service场景 | Pod直连IP | ★★☆☆☆ 特殊场景使用 |

## 切换规则
无Service、无法创建Service资源时使用PodMonitor；其余业务统一使用ServiceMonitor。

# 8. 多环境差异化采集控制
## 8.1 按环境标签过滤目标
开发环境缩短采集、丢弃全量直方图：
```yaml
relabelings:
  - sourceLabels: [__meta_kubernetes_namespace]
    regex: "dev-.*"
    targetLabel: env
    replacement: dev
metricRelabelings:
  - sourceLabels: [env]
    regex: dev
    action: drop
    sourceLabels: [__name__]
    regex: ".*"
```
## 8.2 UAT环境独立抓取间隔
```yaml
endpoints:
  - port: metrics
    interval: 30s
    relabelings:
      - sourceLabels: [__meta_kubernetes_namespace]
        regex: uat-.*
        action: replace
        targetLabel: scrape_interval
        replacement: 60s
```

# 9. 采集调试排障完整流程
## 9.1 校验资源是否被Operator识别
```bash
# 查看所有ServiceMonitor，确认标签platform:monitor存在
kubectl get servicemonitor -A --show-labels

# 查看命名空间是否携带 monitor-enabled=true
kubectl get ns --show-labels
```
## 9.2 查看Prometheus生效Targets页面
访问Prometheus UI → Status → Targets，分三种状态：
1. UP：采集正常；
2. DOWN：网络不通/端口未开放/鉴权失败；
3. Dropped：被relabel规则过滤。
## 9.3 实时日志排查抓取报错
```bash
kubectl logs -f sts/kube-monitor-prometheus-0 -n monitoring | grep scrape
```
## 9.4 手动curl验证metrics连通性
```bash
# 集群内临时Pod测试访问
kubectl run curl-test --image=curlimages/curl --rm -it --namespace business
curl http://business-api:9090/metrics
```

# 10. 最佳实践与禁用反模式
## 10.1 强制最佳实践
1. 全业务统一端口名 `metrics`；
2. 所有SM注入ns/service/pod标签；
3. 默认丢弃直方图bucket指标控制存储；
4. 区分relabelings/metricRelabelings两层逻辑；
5. 每个业务独立ServiceMonitor，禁止一个SM匹配全量Service。

## 10.2 严格禁止反模式
1. ServiceMonitor不携带 `platform: monitor` 标签；
2. endpoints.port直接写数字（如port: 9090）；
3. 单SM匹配数十个不同业务Service，配置混乱；
4. 不配置metricRelabelings，无限制存储海量直方图指标；
5. 直接采集kube-system命名空间内部组件（系统组件单独监控CR）。

# 11. 关联文档索引
1. Prometheus全局抓取配置：04-workload/01-prometheus.md
2. PodMonitor 规范：05-prometheus-operator/02-podmonitor.md
3. 告警规则 PrometheusRule：05-prometheus-operator/03-prometheusrule.md
4. 存储TSDB留存策略：03-storage/02-data-retention.md
5. 采集故障排查手册：09-troubleshooting/02-prometheus-error.md