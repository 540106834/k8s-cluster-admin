# 07‑monitoring‑and‑troubleshooting/00‑README.md
## 一、文档基础信息
- 目录路径：`07-monitoring-and-troubleshooting/`
- 前置依赖文档：
  - `00-README.md`（项目总目录）
  - `02‑workload‑management/` 工作负载体系
  - `03‑network‑management/` 网络原理与Calico
  - `04‑storage‑management/` PV‑PVC‑CSI存储体系
  - `05‑security‑management/` 安全与审计体系
  - `06‑daily‑operations/` 日常运维命令与巡检清单
- 集群环境基准：Kubernetes v1.32.13、containerd‑2.1.5、Calico‑3.30.4、Prometheus+Grafana、kube‑state‑metrics、node‑exporter、CSI存储、etcd集群、Lease模式节点心跳、内网Harbor。
- 环境分层：DEV / FAT / UAT / PROD。
- 文档目标：建立**事前监控预警、事中分层排障、事后复盘**整套体系；统一指标判定标准、标准化故障排查思路、生产级应急处置流程，解决集群组件、节点、Pod、网络、存储、控制平面故障。

## 二、模块整体架构分层
本目录划分为10个子模块，遵循：**监控体系 → 集群健康校验 → 排障方法论 → 分组件故障分析 → 真实生产场景演练 → 速查手册**由浅入深的学习路径：
1. `01‑cluster‑monitoring`：监控体系，明确每一类组件暴露指标、采集链路、RED/USE模型、告警阈值；
2. `02‑cluster‑health‑check`：集群健康检查，给出节点、控制平面、网络、存储常态化检查项；
3. `03‑troubleshooting‑methodology`：排障方法论，统一问题定位逻辑、请求链路排查顺序、全套调试工具；
4. `04‑node‑failures`：节点层面问题：Node NotReady、节点宕机、资源压力、节点深度排障；
5. `05‑pod‑and‑workload‑failures`：Pod和工作负载问题：Pending、CrashLoopBackOff、镜像拉取失败、Pod驱逐、StatefulSet故障；
6. `06‑network‑failures`：网络故障：DNS解析异常、Service访问不通、Ingress异常、CNI问题；
7. `07‑storage‑failures`：存储故障：PVC Pending、卷挂载失败、CSI控制器异常；
8. `08‑control‑plane‑failures`：控制平面故障：apiserver、etcd、scheduler、controller‑manager问题；
9. `09‑production‑scenarios`：真实生产事故场景，模拟节点宕机、API‑Server不可用、etcd磁盘打满、集群资源耗尽、脑裂网络分区以及事故复盘模板；
10. `10‑cheatsheet`：速查清单，Prometheus常用指标、故障‑根因‑对应命令、生产应急SOP，可复制落地。

## 三、各个子目录内容概述
### 01‑cluster‑monitoring（监控体系）
核心目标：理清**指标来源、采集链路、指标含义、告警阈值**。
1. `01-monitoring-architecture.md`
   整体监控架构：四层指标来源（组件原生metrics、kube‑state‑metrics、node‑exporter、业务自定义指标）；Prometheus时序数据库、ServiceMonitor/PodMonitor、抓取规则、持久化配置、Alertmanager告警通道。
2. `02‑api‑server‑metrics.md`
   apiserver指标：请求QPS、请求延迟（apiserver_request_duration_seconds）、4xx/5xx错误率、长连接数量、工作队列长度、in‑flight请求数；判定集群API拥堵、认证失败、准入Webhook耗时过高。
3. `03‑etcd‑metrics.md`
   etcd关键指标：DB大小、Leader状态、raft‑proposal‑commit‑duration、磁盘fsync耗时、raft节点同步延迟、快照生成耗时；重点识别磁盘IO瓶颈、集群leader频繁切换。
4. `04‑scheduler‑metrics.md`
   调度指标：调度延迟、调度成功/失败计数、Predicate过滤失败原因（资源不足、节点亲和、污点、端口冲突）；解决大量Pod长期Pending问题。
5. `05‑controller‑manager‑metrics.md`
   controller队列长度queue_depth、副本同步耗时、node控制器、pv控制器、endpoint控制器延迟；队列堆积代表控制器处理不过来。
6. `06‑kubelet‑metrics.md`
   kubelet指标：PLEG循环延迟（PLEG relist interval过高是高频故障）、容器启停耗时、volume挂载耗时、探针执行时长、镜像清理状态。
7. `07‑container‑runtime‑metrics.md`
   containerd指标：容器创建耗时、镜像拉取耗时、sandbox创建失败、gc清理镜像、运行时错误；排查镜像拉取超时、sandbox创建失败问题。
8. `08‑node‑exporter‑metrics.md`
   操作系统指标：CPU空闲、内存可用、inode使用率、磁盘读写延迟%iowait、网络丢包、TCP连接状态。
9. `09‑kube‑state‑metrics.md`
   把K8s对象状态转为指标：pod_status_phase、deployment_replicas_ready、node_status、pvc_phase、secret过期、证书剩余天数。
10. `10‑monitoring‑best‑practice.md`
    生产监控理论：RED模型（Rate‑Errors‑Duration，面向服务）；USE模型（Utilization‑Saturation‑Errors，面向基础设施）；告警分级、告警降噪、告警聚合原则；区分预警、严重、紧急告警阈值。

### 02‑cluster‑health‑check（集群健康检查）
制定日常巡检标准化判断条件，配合监控告警 + 人工巡检落地。
1. `01‑cluster‑health‑overview.md`：集群健康判定模型：控制平面健康、节点健康、网络健康、存储健康、工作负载健康；健康状态枚举：正常、预警、故障、严重故障。
2. `02‑node‑health‑check.md`：Node Ready状态判定、Lease续约机制、三种资源压力（MemoryPressure / DiskPressure / PIDPressure）判定条件。
3. `03‑control‑plane‑health‑check.md`：apiserver健康探针、scheduler/controller‑manager选主状态、etcd集群成员数量、leader唯一性。
4. `04‑network‑health‑check.md`：CNI就绪状态、CoreDNS Pod状态与解析成功率、Service Endpoint就绪数量、Ingress控制器运行状态。
5. `05‑storage‑health‑check.md`：CSI‑Controller与CSI‑Node状态、SC可用、PVC绑定状态、快照是否就绪、存储池使用率。

### 03‑troubleshooting‑methodology（排障方法论）
统一排障思路，避免盲目操作。
1. `01‑troubleshooting‑methodology.md`：标准排障四步法：**确认现象 → 缩小故障范围 → 定位问题组件 → 查找根因并给出修复方案**；区分全局故障、单节点故障、单个Pod故障、仅部分用户故障。
2. `02‑troubleshooting‑flow.md`：用户访问链路分层排查顺序：`Ingress → Service → Endpoint → Pod → 容器进程 → Node网络 → 内核资源`，逐层排除。
3. `03‑debug‑toolkit.md`：整理整套工具集：kubectl、kubectl‑describe、events、logs‑‑previous、kubectl‑debug临时Pod、crictl、nsenter、tcpdump、journalctl。

### 04‑node‑failures（节点故障）
1. `01‑node‑notready.md`：kubelet停止续约Lease、节点控制器判定NotReady；常见原因：kubelet进程崩溃、端口被防火墙拦截、磁盘压力、内核OOM杀掉kubelet。
2. `02‑node‑down.md`：节点彻底宕机，Lease超时；node‑controller基于`pod‑eviction‑timeout`驱逐Pod，ReplicaSet在其他节点重建Pod；区分优雅驱逐和强制驱逐。
3. `03‑node‑resource‑pressure.md`：MemoryPressure、DiskPressure、PIDPressure产生条件；kubelet会拒绝新建Pod、驱逐低优先级Pod。
4. `04‑node‑debugging.md`：节点综合排查命令：journalctl -u kubelet、crictl ps、dmesg查看内核OOM、iostat、vmstat、检查防火墙规则。

### 05‑pod‑and‑workload‑failures（Pod和工作负载故障）
1. `01‑pod‑pending.md`：调度失败全部原因：CPU内存不足、污点容忍、节点亲和、反亲和、PVC绑定失败、镜像拉取失败、准入Webhook拒绝。
2. `02‑crashloopbackoff.md`：容器反复重启：启动命令错误、liveness探针失败、内存OOM、权限不足、配置错误、securityContext限制。
3. `03‑image‑pull‑failure.md`：镜像拉取失败：imagePullSecret错误、Harbor不通、镜像Tag不存在、内网DNS解析异常、网络策略拦截出站。
4. `04‑pod‑eviction.md`：kubelet主动驱逐Pod的完整逻辑、驱逐打分机制、QoS等级（Guaranteed、Burstable、Best‑Effort）。
5. `05‑workload‑debugging.md`：Deployment滚动更新卡住、StatefulSet有序更新失败、HPA伸缩异常排查方案。

### 06‑network‑failures（网络故障）
1. `01‑dns‑failure.md`：CoreDNS解析失败：CoreDNS Pod异常、NetworkPolicy阻断CoreDNS入出站、ndots配置问题、ipv6干扰。
2. `02‑service‑access‑failure.md`：访问Service不通：Endpoint为空、kube‑proxy模式异常（ipvs问题）、目标Pod防火墙、标签不匹配。
3. `03‑ingress‑failure.md`：Ingress 502/504：ingress‑controller无法访问后端Pod、NetworkPolicy拒绝Ingress访问业务Pod、证书问题。
4. `04‑cni‑failure.md`：Calico‑node异常、网卡配置错误、iptables/ipset规则异常、Pod之间网络不通。
5. `05‑network‑debugging.md`：使用nsenter进入网络命名空间、tcpdump抓包、模拟Pod内部访问测试。

### 07‑storage‑failures（存储故障）
1. `01‑pvc‑pending.md`：StorageClass不存在、CSI‑controller异常、存储池容量不足、绑定策略问题。
2. `02‑volume‑mount‑failure.md`：CSI‑node无法挂载卷、NFS权限不足、selinux限制、宿主机目录权限问题。
3. `03‑csi‑failure.md`：CSI‑Controller Pod异常、CSI‑Node注册失败、快照创建失败、扩容不生效。
4. `04‑storage‑debugging.md`：查看CSI日志、验证存储后端连通性、查看events报错。

### 08‑control‑plane‑failures（控制平面故障）
1. `01‑api‑server‑failure.md`：apiserver启动失败：证书过期、etcd连不上、准入Webhook超时、防火墙关闭6443端口；apiserver请求拥堵。
2. `02‑etcd‑failure.md`：etcd磁盘满、leader频繁切换、集群成员丢失、数据损坏、快照异常。
3. `03‑scheduler‑failure.md`：scheduler选主失败、Predicate和Priority逻辑异常，所有Pod无法调度。
4. `04‑controller‑manager‑failure.md`：controller‑manager队列堆积、endpoint控制器、副本控制器停止工作。
5. `05‑control‑plane‑debugging.md`：查看控制平面systemd日志、etcd日志、重启控制平面组件的安全操作。

### 09‑production‑scenarios（生产真实故障场景）
完全贴合线上故障，梳理现象‑集群反应‑排查步骤‑修复‑事后复盘。
1. `01‑node‑crash‑scenario.md`：节点突然宕机完整全过程：监控告警 → Lease超时 → Pod驱逐 → 其他节点重建Pod → 节点恢复后原有Pod被删除。
2. `02‑api‑server‑unavailable.md`：apiserver不可用现象：kubectl命令卡住，已有Pod继续运行，但新建/删除资源全部失效。
3. `03‑etcd‑disk‑full.md`：etcd磁盘占满，apiserver无法写入数据，集群瘫痪，给出紧急清理快照步骤。
4. `04‑cluster‑resource‑exhaustion.md`：集群CPU/内存耗尽，大量Pod Pending，节点进入资源压力状态。
5. `05‑network‑partition.md`：网络分区导致etcd脑裂，scheduler和controller‑manager多实例同时运行引发异常。
6. `06‑production‑incident‑review.md`：生产事故复盘模板：现象、影响范围、根因、临时解决方案、长期修复方案、后续预防措施、优化监控告警。

### 10‑cheatsheet（速查手册）
1. `01‑monitoring‑cheatsheet.md`：高频PromQL示例、指标含义、告警阈值整理；
2. `02‑troubleshooting‑cheatsheet.md`：故障现象‑根因‑执行命令一一对应，日常排障复制即用；
3. `03‑emergency‑response.md`：生产故障分级、紧急处理步骤、禁止操作清单、升级上报流程。

## 四、DEV/FAT/UAT/PROD 差异化标准
1. DEV：仅部署基础metrics‑server，不部署Prometheus；故障随便重建Pod即可，不用深度根因分析。
2. FAT：部署监控，但告警仅消息通知；故障优先重启Pod，事后简单记录问题。
3. UAT：监控告警规则对齐生产；故障严格按照排障流程分析根因，禁止随意重启组件。
4. PROD（强制约束）
    - 完整部署Prometheus、Alertmanager、持久化存储；严格执行RED、USE模型设置告警阈值；
    - 出现故障严格遵守排障四步法，禁止盲目重启控制平面组件；
    - 控制平面故障优先保存日志、events、组件日志再进行修复；
    - 一级故障执行升级上报机制，事后填写事故复盘文档；
    - 定期模拟节点宕机、etcd故障进行故障演练。

## 五、阅读顺序建议（学习顺序）
1. 先看 `01‑cluster‑monitoring` 理解各项指标含义；
2. 然后 `02‑cluster‑health‑check` 掌握集群健康判定条件；
3. 学习 `03‑troubleshooting‑methodology` 建立统一排障思路；
4. 再依次学习：节点 → Pod → 网络 → 存储 → 控制平面故障；
5. 研读 `09‑production‑scenarios` 熟悉真实生产故障场景；
6. 日常工作查看 `10‑cheatsheet` 速查文档。

## 六、上下游文档关联
### 上游前置文档
1. `02‑workload‑management`：Pod生命周期、探针机制、QoS等级、HPA原理；
2. `03‑network‑management`：Calico原理、Service‑Proxy‑Mode(ipvs)、Endpoint、NetworkPolicy；
3. `04‑storage‑management`：CSI、StorageClass、PV/PVC绑定机制；
4. `05‑security‑management`：准入Webhook、证书有效期、审计日志；
5. `06‑daily‑operations`：kubectl命令、资源监控top、events、日志查看。

### 下游输出文档
1. `cluster‑upgrade‑theory‑guide.md`：集群升级前后组件健康检查；
2. `etcd‑backup.md`：etcd故障时快照恢复方案；
3. `production‑checklist.md`：将监控指标纳入每日自动化巡检清单；
4. 应急处置文档：故障后执行生产事故复盘文档。

## 七、整体核心原则
1. 监控优先：用指标提前发现隐患，而不是故障发生后再排查；
2. 分层排障：严格按照请求链路从上到下逐层定位，禁止凭经验猜测；
3. 故障止损优先：生产故障先恢复业务，再深挖根因；
4. 事后闭环：线上故障必须复盘，补充监控告警避免问题重复发生。