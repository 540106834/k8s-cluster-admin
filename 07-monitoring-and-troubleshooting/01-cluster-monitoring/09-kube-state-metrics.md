# 01-cluster-monitoring/09-kube-state-metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/09-kube-state-metrics.md`
- 前置文档：`08-node-exporter-metrics.md`、`01-monitoring-architecture.md`
- 集群基准：Kubernetes 1.32.13、kube-state-metrics v2.12.0、Prometheus 2.45、Prometheus Operator、离线内网
- 观测模型：**资源状态模型**，区别于node-exporter硬件指标、kubelet运行时指标；只暴露K8s API资源元数据、状态、配额、事件，无硬件性能指标
- 文档范围：kube-state-metrics部署配置、API资源指标分层、资源异常告警、集群容量水位、多环境管控、集群资源故障排查

## 二、kube-state-metrics 部署采集规范
### 2.1 端口与抓取参数
1. 默认指标端口：8080 /metrics；健康检查 `/healthz`
2. 全局标准抓取配置
```yaml
interval: 30s
scrape_timeout: 10s
evaluation_interval: 15s
metrics_path: /metrics
scheme: http
```
3. 核心启动参数（生产强制配置）
```
--resources=pods,deployments,statefulsets,daemonsets,jobs,cronjobs,namespaces,nodes,persistentvolumes,persistentvolumeclaims,configmaps,secrets,ingresses,services,horizontalpodautoscalers,resourcequotas,limitranges,replicasets
--metric-labels-allowlist=namespace=[*],pod=[owner_kind,node],deployment=[replicas]
--kubeconfig=/var/run/secrets/kubernetes.io/serviceaccount/kubeconfig
--disable-metrics=kube_secret_labels,kube_configmap_labels  # 屏蔽敏感配置标签
```
4. RBAC权限：必须授予集群级只读权限，读取全集群所有Namespace资源

### 2.2 Deployment 标准生产YAML（精简版）
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-state-metrics
  namespace: kube-monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-state-metrics
  template:
    metadata:
      labels:
        app: kube-state-metrics
    spec:
      serviceAccountName: kube-state-metrics
      containers:
      - name: kube-state-metrics
        image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.12.0
        args:
        - --resources=pods,deployments,statefulsets,daemonsets,jobs,cronjobs,nodes,pv,pvc,ingresses,services,hpa,namespaces,resourcequotas
        - --metric-labels-allowlist=namespace=[*],pod=[node,owner_kind]
        ports:
        - containerPort: 8080
          name: metrics
```

### 2.3 Service & ServiceMonitor
```yaml
# Service
apiVersion: v1
kind: Service
metadata:
  name: kube-state-metrics
  namespace: kube-monitoring
spec:
  selector:
    app: kube-state-metrics
  ports:
  - port: 8080
    targetPort: metrics

# ServiceMonitor
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kube-state-metrics
  namespace: kube-monitoring
spec:
  selector:
    matchLabels:
      app: kube-state-metrics
  endpoints:
  - port: metrics
    interval: 30s
    scrapeTimeout: 10s
```

## 三、核心指标分层（按K8s资源分类）
### 3.1 Pod 核心指标（集群业务可用性核心）
1. `kube_pod_status_phase{phase=Pending/Running/Failed/Unknown}`
Pod生命周期阶段计数
```promql
# 异常Pod总数（Failed+Unknown）
sum by(namespace,pod)(kube_pod_status_phase{phase=~"Failed|Unknown"})
# Pending阻塞Pod
sum by(namespace,pod)(kube_pod_status_phase{phase="Pending"})
```
2. `kube_pod_container_status_waiting_reason{reason=ContainerCreating/ErrImagePull/InvalidImageName}`
Pod阻塞根因定位
3. `kube_pod_container_status_terminated_reason{reason=Error/OOMKilled}`
容器异常退出（OOM、启动报错）
4. `kube_pod_container_resource_limits_cpu_cores / _memory_bytes`
容器Limit配额；`kube_pod_container_resource_requests_*` Request分配
5. `kube_pod_owner{owner_kind=Deployment/StatefulSet/DaemonSet}`
Pod关联上层工作负载

### 3.2 工作负载指标（Deploy/STS/DaemonSet）
1. `kube_deployment_status_replicas_ready`：就绪副本数
`kube_deployment_spec_replicas`：期望副本
```promql
# Deployment就绪副本缺失率
(kube_deployment_spec_replicas - kube_deployment_status_replicas_ready) / kube_deployment_spec_replicas
```
2. `kube_statefulset_status_replicas_ready`：有状态服务就绪副本
3. `kube_daemonset_status_number_unavailable`：节点缺失DaemonSet Pod
4. `kube_deployment_status_updated_replicas`：滚动更新进度监控
5. `kube_deployment_status_replicas_updated != kube_deployment_spec_replicas`：滚动更新卡住

### 3.3 Job/CronJob 批处理任务指标
1. `kube_job_status_failed`：失败Job计数
2. `kube_cronjob_status_last_schedule_time`：上次调度时间，判断定时任务漏跑
3. `kube_cronjob_active`：运行中Job数量，防止并发堆积
4. `kube_job_owner`：Job归属CronJob标签

### 3.4 存储资源 PV/PVC
1. `kube_persistentvolumeclaim_status_phase{phase=Pending/Bound/Lost}`
PVC未绑定、丢失告警核心指标
2. `kube_persistentvolume_status_phase{phase=Available/Bound/Released/Failed}`
PV回收失败、存储故障
3. `kube_persistentvolumeclaim_resource_requests_storage_bytes`
PVC申请存储容量，集群存储容量规划

### 3.5 网络资源 Service/Ingress
1. `kube_service_spec_type{type=ClusterIP/NodePort/LB}`
服务类型统计
2. `kube_ingress_path`：Ingress路由规则；`kube_ingress_tls` TLS证书配置
3. `kube_ingress_class`：区分Ingress Controller（Cilium/Nginx）

### 3.6 节点资源调度指标
1. `kube_node_status_condition{condition=Ready,status=false}`：节点未就绪
2. `kube_node_spec_unschedulable`：节点封锁（不可调度）
3. `kube_node_status_allocatable_cpu_cores/memory_bytes` 节点总可分配资源
4. `kube_node_status_allocatable_{cpu,memory} - sum(kube_pod_container_resource_requests_*)`
节点剩余可调度资源容量

### 3.7 配额、HPA、Namespace 容量管控
1. `kube_resourcequota{resource=cpu,type=hard}`：命名空间资源硬配额上限
`kube_resourcequota_used` 当前已使用配额
```promql
# Namespace CPU配额使用率
kube_resourcequota_used_cpu_cores / kube_resourcequota_hard_cpu_cores
```
2. `kube_horizontalpodautoscaler_spec_max_replicas / status_current_replicas` HPA扩缩容水位
3. `kube_namespace_status_phase{phase=Active/Terminating}`：命名空间删除阻塞

## 四、集群容量规划专用指标
1. 集群总可分配资源
```promql
sum(kube_node_status_allocatable_cpu_cores)
sum(kube_node_status_allocatable_memory_bytes)
```
2. 全集群已申请资源总和
```promql
sum(kube_pod_container_resource_requests_cpu_cores)
sum(kube_pod_container_resource_requests_memory_bytes)
```
3. 集群资源分配率
```promql
sum(kube_pod_container_resource_requests_cpu_cores) / sum(kube_node_status_allocatable_cpu_cores)
```
4. PVC总存储占用、未绑定PVC数量，用于存储扩容规划

## 五、生产统一告警规则（三层分级全局对齐）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-state-rules
  namespace: kube-monitoring
spec:
  groups:
  - name: k8s.resource.rules
    interval: 30s
    rules:
    # ========== Emergency 紧急（7×24短信+企业微信）==========
    - alert: PodOOMKilled
      expr: sum by(namespace,pod,container)(kube_pod_container_status_terminated_reason{reason="OOMKilled"}) > 0
      for: 1m
      labels: {severity: Emergency}
      annotations: {summary: "容器发生OOM杀死，业务中断"}

    - alert: NodeNotReady
      expr: sum by(node)(kube_node_status_condition{condition="Ready",status="false"}) > 0
      for: 2m
      labels: {severity: Emergency}
      annotations: {summary: "节点未就绪，Pod无法调度运行"}

    - alert: PVCLost
      expr: sum by(namespace,persistentvolumeclaim)(kube_persistentvolumeclaim_status_phase{phase="Lost"}) > 0
      for: 1m
      labels: {severity: Emergency}
      annotations: {summary: "PVC存储丢失，数据丢失风险"}

    # ========== Critical 严重（当日必须处理）==========
    - alert: DeploymentReplicaMissing
      expr: (kube_deployment_spec_replicas - kube_deployment_status_replicas_ready) > 0
      for: 3m
      labels: {severity: Critical}
      annotations: {summary: "Deployment就绪副本不足，业务容量不足"}

    - alert: PodImagePullFailed
      expr: sum by(namespace,pod)(kube_pod_container_status_waiting_reason{reason="ErrImagePull"}) > 0
      for: 3m
      labels: {severity: Critical}
      annotations: {summary: "Pod镜像拉取失败，无法启动"}

    - alert: CronJobFailedLastRun
      expr: kube_cronjob_status_last_successful_schedule_time < kube_cronjob_status_last_schedule_time
      for: 5m
      labels: {severity: Critical}
      annotations: {summary: "定时CronJob上一轮执行失败"}

    - alert: PVCUnbound
      expr: sum by(namespace,persistentvolumeclaim)(kube_persistentvolumeclaim_status_phase{phase="Pending"}) > 0
      for: 5m
      labels: {severity: Critical}
      annotations: {summary: "PVC长时间未绑定PV，Pod无法启动"}

    # ========== Warning 预警（工作时段处理）==========
    - alert: ResourceQuotaHighUsage
      expr: kube_resourcequota_used_cpu_cores / kube_resourcequota_hard_cpu_cores > 0.8
      for: 10m
      labels: {severity: Warning}
      annotations: {summary: "命名空间CPU配额使用率超80%，即将达上限"}

    - alert: DaemonSetUnavailablePod
      expr: kube_daemonset_status_number_unavailable > 0
      for: 10m
      labels: {severity: Warning}
      annotations: {summary: "部分节点缺失DaemonSet Pod"}

    - alert: HpaMaxReplicasReached
      expr: kube_horizontalpodautoscaler_status_current_replicas == kube_horizontalpodautoscaler_spec_max_replicas
      for: 10m
      labels: {severity: Warning}
      annotations: {summary: "HPA已扩至最大副本，无法继续扩容"}
```

## 六、Grafana 大盘分层视图
1. 集群总览面板
    - 全集群节点就绪状态、Pod总数（Running/Failed/Pending拆分）
    - 所有工作负载副本缺失汇总、异常PVC/PV计数
    - 集群CPU/内存总分配使用率容量视图
2. Pod异常面板
    - OOM、镜像拉取失败、启动阻塞Pod列表
    - 按Namespace、工作负载分组统计异常数量时序
3. 工作负载可用性面板
    - Deployment/StatefulSet就绪副本率TOP排行
    - 滚动更新卡住、副本数不达标告警视图
4. 存储资源面板
    - Pending/Lost PVC列表、PV回收失败计数
    - 各Namespace存储PVC总占用容量
5. 批任务面板
    - CronJob最近执行成功/失败统计、漏跑定时任务告警
6. 容量规划面板
    - 集群CPU/内存剩余可调度资源、各Namespace配额使用率TOP
7. 网络面板
    - Ingress TLS状态、未就绪LB服务统计

## 七、多环境差异化管控策略
1. DEV开发环境
    - kube-state-metrics单副本部署，采集间隔30s
    - 仅Warning/Critical告警，无短信通知
    - 时序数据保留3天，不做长期容量统计
2. FAT测试环境
    - 标准完整资源采集，开启全量资源指标
    - 关闭Emergency短信，仅企业微信推送
    - 数据保留7天，压测后统计资源水位
3. UAT预发环境
    - 全套采集+完整告警规则，阈值与生产完全对齐
    - 全等级告警启用，仅企业微信通知
    - 数据保存30天，模拟节点故障、存储丢失验证告警链路
4. PROD生产强制约束
    - Thanos归档指标180天，用于业务故障回溯、年度容量规划
    - Deployment、RBAC、ServiceMonitor、PrometheusRule统一GitOps托管
    - Emergency级别短信+企业微信双通道7×24推送
    - Alertmanager告警抑制：节点失联时，抑制该节点所有Pod异常衍生告警
    - 关闭secret/configmap敏感标签采集，规避配置泄露风险

## 八、监控采集 & 集群资源故障标准排查链路
### 8.1 kube-state-metrics 无指标/抓取失败
1. 校验ServiceAccount RBAC集群只读权限，缺失权限会导致资源指标为空
2. Pod内`curl localhost:8080/metrics`验证指标输出
3. 检查启动`--resources`参数是否包含所需资源类型
4. ServiceMonitor标签匹配、抓取间隔超时配置

### 8.2 Pod持续Pending阻塞排查链路
1. `kube_pod_status_phase{phase="Pending"}`确认阻塞Pod
2. 查看`kube_pod_container_status_waiting_reason`区分根因：
   - ErrImagePull：镜像仓库不可达/镜像不存在
   - ContainerCreating：节点磁盘满、containerd异常、CSI挂载失败
   - InsufficientResources：节点CPU/内存资源不足无法调度
3. 联动node-exporter节点资源指标验证调度瓶颈

### 8.3 容器频繁OOM告警下钻
1. `kube_pod_container_status_terminated_reason{reason="OOMKilled"}`定位异常容器
2. 查看容器memory_limit，对比业务实际内存占用（cadvisor容器指标）
3. 调高Pod内存limit，优化应用内存泄漏逻辑

### 8.4 PVC处于Lost/Pending状态排查
1. Lost：底层存储PV被删除、云存储盘销毁，数据丢失
2. Pending：存储类SC不存在、后端存储池容量不足、CSI插件异常
3. 联动node-exporter磁盘指标、CSI日志定位存储后端故障

### 8.5 工作负载副本缺失、滚动更新卡住
1. 对比spec_replicas与ready_replicas差值确认缺失副本
2. 检查更新进度指标`kube_deployment_status_updated_replicas`
3. 查看Pod事件镜像拉取、资源不足、准入控制器拦截问题

## 九、关联文档索引
1. 顶层规范：`01-monitoring-architecture.md` RED/USE/资源状态三层观测模型、全局告警分级标准
2. 底层硬件指标：`08-node-exporter-metrics.md` 节点CPU/内存/磁盘系统指标联动
3. 容器运行时指标：`06-kubelet-metrics.md`、`07-container-runtime-metrics.md` Pod运行时性能指标
4. 故障通用方法论：`03-troubleshooting-methodology.md` 集群业务可用性故障排查流程
5. PromQL速查：`10-monitoring-best-practice.md` kube-state高频查询语句汇总
6. 集群巡检脚本：`02-cluster-health-check` 定时扫描异常Pod、PVC、节点脚本