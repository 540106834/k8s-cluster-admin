# docs/01-overview/02-component-overview.md
# kube-prometheus-stack 全组件明细、职责、数据流与依赖说明
## 基础元信息
- 集群Kubernetes：v1.32
- Chart版本：kube-prometheus-stack-65.1.0
- 持久化存储：NFS StorageClass `nfs-sc`
- 交付模式：离线MinIO托管Chart包，Git统一管控配置
- 文档等级：★★★★★ 核心配套架构文档
- 前置阅读：01-architecture.md（平台五层整体架构）

## 目录
1. 组件整体分类
2. 管控平面：Prometheus Operator
3. 基础设施指标采集组件
    3.1 kube-state-metrics
    3.2 node-exporter
    3.3 cAdvisor（内置kubelet）
4. 时序存储与规则引擎：Prometheus
5. 告警收敛分发：Alertmanager
6. 可视化面板：Grafana
7. CRD 自定义资源（Operator驱动核心）
8. 离线交付配套支撑组件（MinIO / Harbor / Git）
9. 组件依赖、启停顺序清单
10. 关联文档索引

---

## 1. 组件整体分类
按五层架构划分，所有组件由 `kube-prometheus-stack-65.1.0` Helm Chart 统一编排部署：
1. **管控层**：Prometheus Operator（控制器，所有CRD协调中枢）
2. **采集层**：node-exporter / kube-state-metrics / cAdvisor / 业务Exporter
3. **存储&规则层**：Prometheus（TSDB时序库、Recording/Alert规则引擎）
4. **告警层**：Alertmanager（告警分组、路由、降噪、通知下发）
5. **可视化层**：Grafana（指标查询、大盘展示、用户权限）
6. **外部支撑层**：MinIO(Chart离线仓库)、Harbor(镜像仓库)、Git(配置仓库)、NFS(持久存储)

统一约束：所有有状态组件挂载 `nfs-sc` PVC，数据持久化；配置、CRD、大盘全部Git托管，遵循GitOps。

---

## 2. 管控平面：Prometheus Operator
### 核心定位
整个监控平台的控制核心，K8s自定义控制器，监听5类监控CRD资源，自动维护Prometheus、Alertmanager、采集任务全生命周期。
### 核心职责
1. 集群安装时自动创建5种监控CRD资源定义：
   `Prometheus` / `Alertmanager` / `ServiceMonitor` / `PodMonitor` / `PrometheusRule`
2. 持续watch CRD变更，动态渲染Prometheus/Alertmanager配置文件，热重载无需重启Pod；
3. 自动创建对应StatefulSet/Deployment、Service、Headless Service、RBAC权限、PVC持久卷；
4. 组件故障自愈：Pod异常驱逐/崩溃时重建，绑定原有NFS存储，数据不丢失；
5. 自动发现kubelet cAdvisor接口，生成容器资源抓取任务；
6. 管理组件内部服务发现、证书自签发、端口通信权限。
### 资源形态
- Deployment（无状态控制器，单副本运行）
- 内置集群管理员RBAC ClusterRole/ClusterRoleBinding
### 依赖关系
所有监控组件**强依赖Operator**，必须第一个部署启动。

---

## 3. 基础设施指标采集组件

### 3.1 kube-state-metrics

#### 定位

Kubernetes集群元数据指标采集器，**不采集CPU/内存，只采集集群资源对象状态**。

#### 采集指标范围

- Node：节点就绪状态、污点、标签、资源分配上限
- Deployment/StatefulSet/DaemonSet：期望副本、就绪副本、更新进度
- Pod：运行状态、重启次数、容器OOM、调度节点
- PVC/PV：存储容量、挂载状态、StorageClass绑定关系
- HPA、Ingress、ConfigMap、Secret、Job/CronJob、Event事件

#### 运行形态

Deployment，单副本；通过ServiceMonitor自动接入Prometheus抓取。

#### 存储：无持久化，纯内存指标。

### 3.2 node-exporter

#### 定位
宿主机硬件、操作系统指标采集器，DaemonSet部署，每个节点一个实例。
#### 采集指标范围
CPU使用率、内存、磁盘使用率、磁盘IO读写、网络带宽、TCP连接、系统负载、文件句柄、硬件温度、磁盘smart状态。
#### 运行形态
DaemonSet，HostNetwork+HostPID权限读取宿主机硬件；
#### 存储：无持久化。

### 3.3 cAdvisor（kubelet内置，无需独立部署）
#### 定位
容器运行时指标采集，内置在每个节点kubelet，暴露`/metrics/cadvisor`端点。
#### 采集指标范围
单个容器CPU、内存使用、磁盘读写、网络IO、容器生命周期、OOM Kill记录。
#### 接入方式
Operator自动生成抓取任务，无需手动创建ServiceMonitor。

### 3.4 业务自定义Exporter（非Chart内置，扩展层）
MySQL Exporter、Redis Exporter、Kafka Exporter、自定义业务Metrics；
通过Git托管ServiceMonitor/PodMonitor完成自动接入，详见 `08-extension/02-custom-exporter.md`。

---

## 4. 时序存储与规则引擎：Prometheus
### 定位
平台核心时序数据库TSDB，统一存储全量采集指标，内置PromQL查询引擎与规则调度器。
### 核心能力
1. **指标抓取**：读取Operator生成的scrape配置，周期性拉取各Exporter/业务metrics；
2. **时序存储**：本地块存储TSDB，挂载NFS PVC持久化，配置数据保留周期retention；
3. **RecordingRule（预计算规则）**：预聚合高频指标（集群总QPS、节点平均负载），降低Grafana查询开销；
4. **AlertingRule（告警规则）**：匹配指标阈值异常，生成告警事件推送至Alertmanager；
5. **内置自监控**：抓取自身抓取延迟、TSDB块写入、内存占用、target失联数量；
6. **高可用支持**：StatefulSet多副本部署，共享NFS存储，无单点故障。
### 资源形态
StatefulSet，绑定`nfs-sc` PVC持久化时序数据；Headless Service供Grafana查询。
### 关键存储目录（NFS挂载）
- `/prometheus`：TSDB时序原始数据块
- `/prometheus/rules`：动态加载PrometheusRule告警/预计算规则文件

---

## 5. 告警收敛分发：Alertmanager
### 定位
独立告警处理组件，不做指标判断，仅接收Prometheus推送的告警事件，做降噪与路由分发。
### 核心能力
1. **告警分组**：按namespace、app、severity对同类型告警聚合，避免刷屏；
2. **路由分流**：不同业务/严重级别告警推送至钉钉/企业微信/邮件/自定义Webhook；
3. **告警抑制**：根故障触发时屏蔽下游衍生告警（如节点宕机屏蔽所有Pod失联告警）；
4. **静默窗口**：定时维护窗口自动屏蔽告警，支持临时手动静默；
5. **状态持久化**：NFS存储告警静默记录、通知历史，Pod重建不丢失配置。
### 资源形态
StatefulSet，挂载`nfs-sc` PVC存储告警状态；
### 数据流：Prometheus → Alertmanager → 外部通知渠道

---

## 6. 可视化面板：Grafana
### 定位
时序数据可视化终端，对接Prometheus数据源，统一承载集群/业务监控大盘、报表、视图权限管控。
### 核心能力
1. 内置K8s Node/Pod/Deployment官方Dashboard模板；
2. Git托管自定义业务大盘JSON，部署自动导入；
3. 多租户RBAC权限：只读/编辑/管理员分级访问；
4. 内置告警视图，可直接查看Prometheus告警列表；
5. HTTPS Ingress对外提供Web访问，TLS证书由Secret管理。
### 资源形态
Deployment，挂载`nfs-sc` PVC持久化：
- 用户账号、权限配置
- 数据源连接配置
- 所有Dashboard面板JSON
- 告警通知渠道配置

---

## 7. CRD 自定义资源（Operator驱动核心）
所有监控能力均通过声明式CRD管理，全部Git存储，禁止集群内直接kubectl edit：
### 7.1 Prometheus CRD
定义Prometheus实例副本数、存储大小、抓取超时、数据保留周期、高可用配置、外部标签。
对应文档：04-monitoring-components/01-prometheus.md

### 7.2 Alertmanager CRD
定义告警集群副本、存储、路由规则、抑制、静默配置。
对应文档：04-monitoring-components/03-alertmanager.md

### 7.3 ServiceMonitor CRD
匹配集群Service标签，自动发现后端Pod `/metrics` 端点，用于常规有Service的业务/中间件采集。
对应文档：05-prometheus-operator/01-servicemonitor.md

### 7.4 PodMonitor CRD
直接匹配Pod标签，跳过Service，适用于无Service裸Pod、Job临时任务采集。
对应文档：05-prometheus-operator/02-podmonitor.md

### 7.5 PrometheusRule CRD
统一管理Recording预计算规则 + Alert告警阈值规则，热加载无需重启Prometheus。
对应文档：05-prometheus-operator/03-prometheusrule.md、05-prometheus-operator/04-recordingrule.md

---

## 8. 离线交付配套支撑组件（外部依赖）
不属于kube-prometheus-stack Chart内置，但平台运行强依赖：
1. **MinIO**：离线存储Helm Chart二进制包 `kube-prometheus-stack-65.1.0.tgz`，Helm客户端拉取Chart来源；
2. **私有Harbor**：存储所有监控组件离线镜像，集群无外网，仅从Harbor拉取镜像；
3. **Git仓库**：统一管理values.yaml、CRD清单、Grafana大盘、NetworkPolicy、RBAC配置，GitOps唯一配置源；
4. **NFS服务端 + StorageClass `nfs-sc`**：统一持久存储层，承载Prometheus TSDB、Alertmanager状态、Grafana面板。

---

## 9. 组件依赖、标准启停顺序（部署/升级严格遵循）
### 部署启动顺序
1. 前置底座：NFS StorageClass、Harbor、MinIO、Git仓库就绪
2. Prometheus Operator（控制器核心）
3. 采集层：kube-state-metrics → node-exporter
4. Prometheus StatefulSet（时序存储、规则引擎）
5. Alertmanager StatefulSet（告警接收分发）
6. Grafana Deployment（可视化展示）
7. 业务自定义Exporter + ServiceMonitor/PodMonitor（业务接入）

### 关停/缩容顺序（维护、升级）
1. 业务Exporter、自定义ServiceMonitor
2. Grafana
3. Alertmanager
4. Prometheus
5. node-exporter、kube-state-metrics
6. Prometheus Operator（最后关停）

---

## 10. 关联文档索引
1. 上层架构：01-architecture.md 平台五层整体架构
2. 离线部署：02-deployment/01-installation.md Chart离线完整安装流程
3. 存储持久化：03-storage/01-storage-design.md NFS PVC规划
4. 各组件深度详解：
   - 04-monitoring-components/01-prometheus.md
   - 04-monitoring-components/02-grafana.md
   - 04-monitoring-components/03-alertmanager.md
   - 04-monitoring-components/04-exporters.md
5. CRD资源使用手册：05-prometheus-operator/ 目录全套文档
6. 日常运维：06-operations/01-daily-operation.md 组件日常巡检、扩缩容
7. 故障排查：09-troubleshooting/ 组件失联、存储异常、抓取失败处理
8. 平台规范：10-best-practices/03-monitoring-standard.md 指标与组件接入标准