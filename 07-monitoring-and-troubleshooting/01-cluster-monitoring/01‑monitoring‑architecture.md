# 01‑cluster‑monitoring/01‑monitoring‑architecture.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/01-monitoring-architecture.md`
- 前置文档：`06‑daily‑operations/05‑resource‑monitoring.md`
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Prometheus‑2.45、Alertmanager、Grafana、kube‑state‑metrics、node‑exporter、ServiceMonitor/PodMonitor、内网持久存储，离线部署，不依赖外网。
- 适用环境：DEV、FAT、UAT、PROD
- 文档内容：指标来源分类、完整采集链路、Prometheus组件架构、服务发现、数据持久化、告警分层、USE/RED模型、生产部署模式、区分metrics‑server和Prometheus定位。

## 二、集群指标四大来源（核心分层）
### 1. 组件原生内置指标（/metrics HTTP接口）
kube‑apiserver、etcd、kube‑scheduler、kube‑controller‑manager、kubelet、calico‑node、CoreDNS、Ingress‑Controller、containerd，组件内置暴露`/metrics`，格式为Prometheus标准格式。
> 访问方式：HTTP GET，默认端口各不相同。
> - apiserver：6443（https）
> - kubelet：10250（https）
> - etcd：2379（https）
> - calico‑node：9099

### 2. node‑exporter（宿主机系统指标）
部署为DaemonSet，在每个节点采集操作系统层面指标：CPU、内存、磁盘使用率、inode、%iowait、TCP连接、网卡收发包、磁盘读写延迟、内核报错信息；弥补容器看不到宿主机内核指标的短板。

### 3. kube‑state‑metrics（K8s对象状态指标）
把Kubernetes API资源转换成时序指标，本身不采集CPU内存：
- Pod：pod_status_phase、pod_ready、pod_restart_count
- Deployment：副本就绪数、更新进度
- Node：节点Ready状态、Lease续约状态、节点三种压力标记
- PVC/PV：pvc_phase、快照状态、StorageClass信息
- Secret、证书剩余有效期、RBAC绑定状态。
> 本质是调用apiserver读取对象，输出metrics供Prometheus抓取。

### 4. 业务自定义指标（应用内部暴露）
业务程序自身提供`/metrics`接口，暴露业务层指标：接口QPS、错误码分布、响应耗时、队列堆积、数据库连接数；用于HPA扩容和业务监控。

### 补充：metrics‑server 与 Prometheus 职责划分（重点区分）
1. metrics‑server：轻量级，只提供CPU、内存瞬时值，只给`kubectl top`和HPA基础扩容使用；数据内存存放，不持久化历史数据，**不能做趋势分析、告警**。
2. Prometheus：全量时序数据库，保存长期历史时序数据，做趋势分析、告警、大盘展示、故障回溯，生产监控核心。

## 三、完整指标采集链路（自上而下）
1. 各个组件开启metrics接口；
2. ServiceMonitor/PodMonitor（CRD资源）配置抓取规则：命名空间、标签匹配、端口、抓取间隔、超时时间、tls证书；
3. Prometheus‑Operator基于ServiceMonitor生成 scrape‑config；
4. Prometheus发起HTTP请求获取指标；
5. Prometheus将时序数据写入本地磁盘或者远端持久存储（Thanos）；
6. 两条分支：
    - 分支1：Grafana读取Prometheus数据绘制大盘（节点、控制平面、Pod、存储、网络大盘）；
    - 分支2：Prometheus评估AlertRules，命中阈值发送告警至Alertmanager；
7. Alertmanager：告警分组、降噪、抑制告警、路由分发到企业微信、短信、邮件；
8. 日志体系Filebeat‑ELK独立于监控体系，只处理日志，时序指标由Prometheus负责。

### 采集参数生产标准值
```yaml
interval: 15s        # 默认抓取间隔15s
scrape_timeout: 10s  # 超时10s
evaluation_interval:15s #告警规则计算周期15s
```

## 四、Prometheus整体组件架构（生产落地架构）
### 4.1 组件清单
1. prometheus‑operator：管理Prometheus、Alertmanager、ServiceMonitor、PodMonitor、PrometheusRule CRD，统一声明式配置，GitOps管理；
2. prometheus：时序数据库核心，存储metrics；
3. alertmanager：告警收敛与分发；
4. kube‑state‑metrics：对象指标；
5. node‑exporter：节点指标；
6. blackbox‑exporter：探测组件，探测TCP、HTTP连通性，探测Service、Ingress连通性；
7. thanos（PROD必选）：解决Prometheus单副本问题，实现高可用、长期存储、跨集群聚合；
    - sidecar：和Prometheus同Pod，上传块对象至MinIO；
    - query：统一查询入口；
    - store‑gateway：读取历史归档数据。

### 4.2 资源部署拓扑
- kube‑state‑metrics：Deployment；
- node‑exporter：DaemonSet，每个节点运行一个；
- prometheus、alertmanager：StatefulSet搭配PVC持久化存储；
- 所有组件部署在`kube‑monitoring`命名空间。

## 五、服务发现4种模式（K8s环境）
1. **ServiceMonitor（生产首选）**
    通过匹配Service标签，后端自动发现对应Pod Endpoint；推荐全部组件使用该方式。
    ```yaml
    spec:
      selector:
        matchLabels:
          app: coredns
    ```
2. PodMonitor：直接匹配Pod标签，不依赖Service，适合没有Service的组件（calico‑node）。
3. kubernetes‑sd（原生服务发现）：Prometheus内置发现Node、Service、Pod、Endpoint、Ingress，老式用法，生产优先ServiceMonitor。
4. 静态配置static‑config：仅用于外部组件（Harbor、数据库、NFS）。

## 六、数据持久化方案（分环境）
1. FAT环境：Prometheus本地PVC存储，保留7天数据即可；
2. UAT环境：PVC存储，保存30天；
3. PROD生产（强制）：Prometheus短期数据本地磁盘保留15天；Thanos将历史时序数据归档至MinIO对象存储，保存90‑180天；满足故障回溯和合规要求。
> Prometheus数据分block（2h一个数据块），Thanos sidecar在block完成之后上传至对象存储。

## 七、两大监控模型（后续各个指标判断依据）
### 7.1 USE模型（硬件、基础设施层面：Node、etcd、磁盘、CPU）
- Utilization：使用率（CPU使用率、磁盘使用率、内存使用率）
- Saturation：饱和度（队列堆积、等待IO、排队请求）
- Errors：错误（磁盘报错、连接失败、进程崩溃）
> 适用对象：节点、etcd、kubelet、CSI、网络设备。

### 7.2 RED模型（业务层面：API‑Server、微服务、Service）
- Rate：请求速率 QPS
- Errors：错误率（4xx、5xx）
- Duration：请求延迟分布（p50/p90/p99）
> 适用对象：apiserver、CoreDNS、Ingress、业务微服务。

## 八、告警分层设计（统一规范，后续各个指标告警阈值遵守这套标准）
### 告警等级划分
1. Warning（预警）：指标到达阈值，暂时不影响业务，工作时段处理；
    - CPU/内存70‑85%，磁盘使用率80‑85%；
2. Critical（严重）：业务性能下降，必须当日处理；
    - CPU/内存＞85%，磁盘＞90%，etcd同步延迟升高；
3. Emergency（紧急）：业务中断，短信+消息双通知，7×24响应；
    - 节点NotReady、etcd Leader丢失、大量Pod Crash、Ingress全部无法访问。

### 告警优化原则
1. 告警聚合：同一故障产生多条告警合并成一条；
2. 告警抑制：etcd宕机后，后续Pod异常告警全部抑制，只报根因；
3. 延时告警：瞬时峰值不触发告警，持续3‑5分钟指标超标才触发告警，消除抖动误报。

## 九、DEV/FAT/UAT/PROD部署差异化
1. DEV：只部署metrics‑server，不部署Prometheus‑Operator，仅kubectl top查看瞬时资源；
2. FAT：部署Prometheus基础组件，无Thanos；告警仅消息通知，历史数据保存7天；
3. UAT：完整部署Prometheus‑Operator，开启PrometheusRule；告警规则和生产一致，数据保存30天；
4. PROD（强制约束）
    - 启用Thanos实现高可用+长期归档；
    - 严格按照USE、RED模型配置告警阈值；
    - ServiceMonitor、PrometheusRule全部交由GitOps管理；
    - 开启blackbox‑exporter定期探测Ingress、Service连通性；
    - 定期检查Prometheus自身CPU、内存、磁盘占用，防止监控组件抢占资源。

## 十、常见故障（监控层面问题）
1. Prometheus抓取失败：
    - 组件metrics端口未开放；
    - TLS证书配置错误；
    - NetworkPolicy阻止Prometheus访问目标Pod；
    - 目标Pod标签不匹配ServiceMonitor选择器。
2. 指标缺失：kube‑state‑metrics权限不足，没有读取集群资源的RBAC权限；
3. 告警频繁误报：scrape‑timeout太短、抓取间隔太短，适当调整为15s。

## 十一、关联文档
1. 后续对应指标文档：`02‑api‑server‑metrics.md`、`03‑etcd‑metrics.md`、`06‑kubelet‑metrics.md`；
2. 节点健康检查：`02‑cluster‑health‑check`；
3. 故障排查：`03‑troubleshooting‑methodology.md`，利用监控指标缩小故障范围；
4. 速查文档：`10‑cheatsheet/01‑monitoring‑cheatsheet.md` 常用PromQL语句。