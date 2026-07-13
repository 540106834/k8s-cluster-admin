# 03‑worker‑node‑management/00‑overview.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/00‑overview.md`
- 前置依赖文档：
  - 集群总架构文档、`05‑security‑management`安全体系、`06‑daily‑operations`日常运维手册、`07‑monitoring‑and‑troubleshooting`监控排障体系
- 集群基准：Kubernetes‑1.32.13，kube‑lease节点心跳机制，containerd‑2.1.5，Calico‑3.30，CSI存储、ipvs模式kube‑proxy、PDB、Taint‑Toleration、Node‑Affinity、内核调优、内网离线环境。
- 环境分层：DEV / FAT / UAT / PROD。
- 文档定位：Worker‑Node模块总览，梳理整体架构、组件分工、目录结构、核心设计理念、环境差异化标准、上下游依赖、学习顺序、生产红线。

## 二、Worker‑Node 整体架构与组件分工
### 1. 节点内部核心组件
1. **kubelet**：节点核心代理程序；和apiserver通信；维持Lease续约；拉取Pod清单；调用containerd启停容器；执行资源压力驱逐；上报节点状态；执行探针（liveness/readiness/startupProbe）。
2. **containerd‑2.1.5**：CRI运行时；管理容器生命周期、镜像拉取、sandbox创建、镜像GC、容器IO管控。
3. **CNI（Calico‑node）**：配置iptables‑ipset；Pod网络连通；NetworkPolicy策略执行。
4. **kube‑proxy**：ipvs模式，在每个节点生成Service转发规则。
5. **CSI‑node**：对接后端存储，完成PV挂载、卸载、扩容。
6. 配套DaemonSet组件：node‑exporter、filebeat、sys‑tune。

### 2. 控制平面对应控制器
1. **Node‑Controller**：监控Node Lease状态；Lease超时后判定节点失联；依据`pod‑eviction‑timeout(5min)`触发跨节点重建Pod；更新Node Ready状态。
2. **Scheduler**：结合Node标签、污点容忍度、节点亲和、资源剩余量把Pod调度到合适节点。
3. **Admission‑Webhook**：对节点上创建的Pod做安全校验（PSS、镜像校验）。

### 3. 围绕节点的4大核心机制（本模块核心）
1. **生命周期机制**：节点初始化 → 正常运行 → 维护排空 → 退役下线；对应`04‑node‑lifecycle.md`。
2. **调度控制机制**：Label、Taint‑Toleration、Node‑Affinity、Pod‑Affinity/Anti‑Affinity（`07‑scheduling‑control.md`）。
3. **kubelet自我保护机制**：MemoryPressure、DiskPressure、PIDPressure；kubelet主动驱逐低优先级Pod缓解节点压力（`08‑resource‑pressure.md`）。
4. **安全加固机制**：操作系统加固、sysctl参数、防火墙规则、SELinux、kubelet配置收紧、容器运行时安全配置（`09‑node‑hardening.md`）。

## 三、目录各个文档核心简述
```
03-worker-node-management/
├── 00-overview.md                  # 本文件，模块总览
├── 01-node-basics.md               # 节点基础信息查看命令、资源统计、节点状态判定、Lease查看、基础健康检查项
├── 02-node-join.md                # 节点环境预处理、内核参数、containerd离线部署、kubeadm‑join接入、接入后校验清单
├── 03-node-drain.md               # cordon/uncordon/drain原理、PDB约束、drain失败原因、分批排空操作、命令参数详解
├── 04-node-lifecycle.md           # 节点完整生命周期：上线‑运行‑维护‑退役全流程、生产上线&退役SOP
├── 05-node-troubleshooting.md     # Node NotReady、kubelet挂掉、containerd异常、CNI故障、磁盘inode耗尽综合排查方法论
├── 06-kubelet-runtime.md          # kubelet配置解析、PLEG原理、容器镜像GC策略、kubelet性能调优、日志配置、kubelet报错分析
├── 07-scheduling-control.md       # Label标准化、Taint内置污点、自定义污点、节点亲和、Pod反亲和、调度策略落地示例
├── 08-resource-pressure.md        # MemoryPressure / DiskPressure / PIDPressure触发条件、驱逐打分机制、QoS等级、驱逐顺序
├── 09-node-hardening.md          # OS安全加固、sysctl内核参数、防火墙白名单、kubelet安全配置、containerd安全配置、禁用特权容器
└── 10-runbooks.md                # Runbook手册，整理节点宕机、kubelet崩溃、磁盘打满、inode耗尽、containerd故障、drain失败的应急处理步骤
```

## 四、统一设计原则（贯穿整个模块）
1. **分层防御思想**
    - 调度层：通过Taint、节点亲和控制Pod部署范围；
    - 运行层：kubelet监控资源压力，压力超标主动驱逐Pod；
    - 控制器层：Node‑Controller检测节点宕机，跨节点重建Pod；
    - 操作系统层：内核参数、防火墙、SELinux做底层安全加固。
2. **故障止损原则**
    - 节点故障分为两类：kubelet异常但服务器正常；服务器彻底宕机；
    - kubelet异常：Lease超时后控制器重建Pod；原节点恢复后旧Pod被垃圾回收；
    - 资源压力：kubelet优先驱逐低优先级Pod（Best‑Effort > Burstable > Guaranteed）保障系统进程稳定。
3. **变更安全原则**
    - 节点维护严格顺序：`cordon → drain → 维护 → uncordon/delete node`；
    - PROD禁止一次性批量排空多个节点；严格依赖PDB保证业务最小可用副本；
    - 节点新增、退役、内核升级、containerd升级必须选择业务低峰窗口。
4. **可观测原则**
    - node‑exporter采集系统指标；kubelet metrics暴露内部运行指标；
    - Prometheus配置USE模型告警：CPU、内存、磁盘使用率、inode、iowait、PLEG延迟、镜像GC状态。

## 五、DEV / FAT / UAT / PROD 差异化执行标准
1. **DEV本地环境**
    - 节点可以随意重启；drain可以添加`--force`强制清理Pod；不配置PDB；无需严格内核加固；仅部署metrics‑server，不需要Prometheus告警。
2. **FAT测试环境**
    - 节点维护可以分批执行；必要时临时修改PDB；
    - 操作系统基础加固即可；内核参数统一对齐生产；
    - 监控仅消息告警，不配置短信告警。
3. **UAT预生产环境**
    - 流程对齐生产：禁止`--force`强制驱逐Pod；维护选凌晨低峰；
    - 完整开启SELinux、防火墙白名单；kubelet和containerd安全配置和生产一致；
    - Prometheus告警规则复用生产配置。
4. **PROD生产环境（强制约束）**
    1. 节点上线前必须完成内核调优、安全加固，通过检查清单才允许加入集群；
    2. drain排空严禁使用`--force`；严格遵守PDB；一次仅排空一台节点，排空后观察5‑10分钟业务指标；
    3. 节点退役前校验PVC备份、CSI快照、定时备份任务全部执行完成；
    4. 出现节点NotReady、磁盘打满等一级故障按照`10‑runbooks.md`执行应急处置；
    5. 节点所有变更操作（内核升级、containerd升级、退役下线）走工单双人复核，操作全程被audit‑log记录；
    6. 定期执行故障演练：模拟节点宕机，验证Pod跨节点重建是否正常。

## 六、推荐学习顺序
1. 基础认知：`01-node-basics.md` → `02-node-join.md`，理解节点如何加入集群；
2. 生命周期：`04-node-lifecycle.md`掌握整体生命周期；再学习`03-node-drain.md`深入排空原理；
3. 调度体系：`07‑scheduling‑control.md`学习污点和亲和；
4. 运行时：`06‑kubelet‑runtime.md` → `08‑resource‑pressure.md`弄懂kubelet驱逐逻辑；
5. 安全加固：`09‑node‑hardening.md`；
6. 故障排障：`05‑node‑troubleshooting.md`；
7. 应急落地：`10‑runbooks.md`用于日常故障快速处理。

## 七、上下游文档关联
### 上游依赖文档
1. `02‑workload‑management`：QoS等级、PDB、Pod‑Disruption‑Budget、探针原理；
2. `03‑network‑management`：Calico‑node、ipvs、NetworkPolicy；
3. `04‑storage‑management`：CSI‑node、PV/PVC挂载逻辑；
4. `05‑security‑management`：PSS安全策略、准入Webhook、审计日志；
5. `06‑daily‑operations`：kubectl日常命令、发布前检查清单；
6. `07‑monitoring‑and‑troubleshooting`：kubelet指标、node‑exporter指标、USE告警模型。

### 下游输出文档
1. `cluster‑upgrade‑theory‑guide.md`：集群版本升级时节点分批驱逐与升级流程；
2. `etcd‑backup.md`：节点故障期间etcd备份校验；
3. `07‑monitoring‑and‑troubleshooting/04‑node‑failures`：节点NotReady、节点宕机深层故障分析。

## 八、总结
Worker‑Node是Kubernetes底层运行载体：
- kubelet负责节点内部管控；Node‑Controller负责全局状态判断；
- 日常运维核心三件事：**规范节点上线流程、安全的节点排空退役、节点资源压力监控与故障快速处理**；
- 生产环境必须做到：上线有检查、变更有限制、故障有预案、事后有复盘，避免因为节点问题引发集群级故障。