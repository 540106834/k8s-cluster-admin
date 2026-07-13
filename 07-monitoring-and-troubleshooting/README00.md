你的 `07-monitoring-and-troubleshooting` 目前偏向**故障分类手册**，但缺少生产 Kubernetes 运维最核心的两部分：

1. **集群可观测性（Monitoring）**

   * 监控什么指标
   * 指标来源在哪里
   * 每个指标有什么运维价值
   * 异常意味着什么

2. **故障机制与排障（Troubleshooting）**

   * 故障发生后 Kubernetes 自身如何处理
   * 控制器如何恢复
   * 运维人员如何介入定位

建议调整为：

```text
07-monitoring-and-troubleshooting/
├── 00-README.md                              # Kubernetes 监控与故障排查总览
│
├── 01-cluster-monitoring/
│   ├── 01-monitoring-architecture.md         # Kubernetes 监控体系架构
│   │                                        # Metrics来源、采集链路、Prometheus架构
│   │
│   ├── 02-api-server-metrics.md              # kube-apiserver 监控指标
│   │                                        # 请求量、延迟、错误率、工作队列
│   │                                        # API Server健康状态判断
│   │
│   ├── 03-etcd-metrics.md                    # etcd 监控指标
│   │                                        # DB大小、leader状态、commit延迟、
│   │                                        # raft同步状态、磁盘性能
│   │
│   ├── 04-scheduler-metrics.md               # kube-scheduler 监控指标
│   │                                        # 调度成功率、pending原因、
│   │                                        # scheduling latency
│   │
│   ├── 05-controller-manager-metrics.md      # kube-controller-manager指标
│   │                                        # Controller同步状态、queue depth
│   │                                        # 副本控制、Node控制
│   │
│   ├── 06-kubelet-metrics.md                 # kubelet监控指标
│   │                                        # Pod状态、容器状态、
│   │                                        # CPU/Memory、Volume、PLEG
│   │
│   ├── 07-container-runtime-metrics.md       # containerd监控指标
│   │                                        # 容器创建、镜像拉取、runtime异常
│   │
│   ├── 08-node-exporter-metrics.md           # Node系统指标
│   │                                        # CPU、Memory、Disk、Network
│   │
│   ├── 09-kube-state-metrics.md             # Kubernetes对象状态指标
│   │                                        # Deployment、Pod、Node、PVC状态
│   │
│   └── 10-monitoring-best-practice.md        # 生产监控指标设计
│                                            # USE模型、RED模型、告警设计
│
├── 02-cluster-health-check/
│   ├── 01-cluster-health-overview.md         # 集群健康检查模型
│   │
│   ├── 02-node-health-check.md               # Node健康检查
│   │                                        # Ready状态、资源压力、Lease
│   │
│   ├── 03-control-plane-health-check.md      # 控制面健康检查
│   │                                        # API Server、Scheduler、
│   │                                        # Controller、etcd
│   │
│   ├── 04-network-health-check.md            # 网络健康检查
│   │                                        # CNI、CoreDNS、Service、Ingress
│   │
│   └── 05-storage-health-check.md            # 存储健康检查
│                                            # CSI、PV、PVC、StorageClass
│
├── 03-troubleshooting-methodology/
│   ├── 01-troubleshooting-methodology.md     # Kubernetes故障定位方法
│   │                                        # 现象→范围→组件→根因
│   │
│   ├── 02-troubleshooting-flow.md            # 分层排障流程
│   │                                        # 用户请求链路:
│   │                                        # Ingress→Service→Pod→Node
│   │
│   └── 03-debug-toolkit.md                   # kubectl/debug工具箱
│                                            # describe、events、logs、
│                                            # debug、crictl
│
├── 04-node-failures/
│   ├── 01-node-notready.md                   # Node NotReady故障
│   │                                        # kubelet异常后的处理机制
│   │                                        # Node Controller检测流程
│   │
│   ├── 02-node-down.md                       # Node宕机故障
│   │                                        # 心跳丢失
│   │                                        # Lease机制
│   │                                        # Pod驱逐机制
│   │                                        # ReplicaSet重新创建Pod
│   │
│   ├── 03-node-resource-pressure.md          # Node资源压力
│   │                                        # MemoryPressure
│   │                                        # DiskPressure
│   │                                        # PIDPressure
│   │
│   └── 04-node-debugging.md                  # Node综合排障
│
├── 05-pod-and-workload-failures/
│   ├── 01-pod-pending.md                     # Pod Pending分析
│   │                                        # 调度失败原因
│   │
│   ├── 02-crashloopbackoff.md                # CrashLoopBackOff分析
│   │                                        # 应用退出、探针失败
│   │
│   ├── 03-image-pull-failure.md              # 镜像拉取失败
│   │                                        # Registry、认证、网络
│   │
│   ├── 04-pod-eviction.md                    # Pod驱逐机制
│   │                                        # Node压力导致驱逐
│   │
│   └── 05-workload-debugging.md              # Deployment/StatefulSet排障
│
├── 06-network-failures/
│   ├── 01-dns-failure.md                     # CoreDNS故障
│   ├── 02-service-access-failure.md           # Service访问异常
│   ├── 03-ingress-failure.md                 # Ingress访问异常
│   ├── 04-cni-failure.md                     # CNI网络异常
│   └── 05-network-debugging.md
│
├── 07-storage-failures/
│   ├── 01-pvc-pending.md                     # PVC绑定失败
│   ├── 02-volume-mount-failure.md            # Volume挂载失败
│   ├── 03-csi-failure.md                     # CSI异常
│   └── 04-storage-debugging.md
│
├── 08-control-plane-failures/
│   ├── 01-api-server-failure.md              # API Server故障
│   ├── 02-etcd-failure.md                    # etcd故障
│   ├── 03-scheduler-failure.md               # Scheduler故障
│   ├── 04-controller-manager-failure.md      # Controller故障
│   └── 05-control-plane-debugging.md
│
├── 09-production-scenarios/
│   ├── 01-node-crash-scenario.md             # Node宕机完整流程
│   │                                        # 故障发现→集群反应→恢复
│   │
│   ├── 02-api-server-unavailable.md          # API Server不可用
│   ├── 03-etcd-disk-full.md                  # etcd磁盘满
│   ├── 04-cluster-resource-exhaustion.md     # 集群资源耗尽
│   ├── 05-network-partition.md               # 网络分区
│   └── 06-production-incident-review.md      # 生产事故复盘
│
└── 10-cheatsheet/
    ├── 01-monitoring-cheatsheet.md           # 指标速查
    ├── 02-troubleshooting-cheatsheet.md       # 故障→原因→命令
    └── 03-emergency-response.md               # 生产应急处理流程
```

核心设计思想：

## 监控部分回答：

> Kubernetes 怎么知道自己健康？

例如：

### Node状态

指标：

```
kube_node_status_condition
```

价值：

```
Node Ready=False
        |
        ↓
Node Controller检测
        |
        ↓
判断Node异常
        |
        ↓
触发Pod Eviction
```

---

### kubelet

重点：

```
kubelet_running_pods
kubelet_volume_stats_used_bytes
container_cpu_usage_seconds_total
container_memory_working_set_bytes
```

价值：

发现：

* Pod数量异常
* 容器资源异常
* Volume容量不足
* kubelet压力

---

### etcd

重点：

```
etcd_server_has_leader
etcd_disk_backend_commit_duration_seconds
etcd_mvcc_db_total_size_in_bytes
```

价值：

判断：

* etcd是否健康
* 是否存在IO瓶颈
* 是否接近容量限制

---

## Troubleshooting部分回答：

> 出问题以后 Kubernetes 怎么处理？

例如 Node 挂掉：

```
Node故障
 |
 |
kubelet停止发送Lease
 |
 |
Node Controller检测超时
 |
 |
Node状态:
Ready Unknown
 |
 |
超过pod-eviction-timeout
 |
 |
驱逐Pod
 |
 |
Deployment Controller发现副本不足
 |
 |
Scheduler重新调度Pod
 |
 |
业务恢复
```

---

这个结构更接近**生产云 Kubernetes Administrator / SRE 知识体系**：

* 06-daily-operations：

  > "正常情况下怎么操作"

* 07-monitoring-and-troubleshooting：

  > "怎么判断系统健康，以及异常情况下怎么恢复"

两个目录职责边界会非常清晰。
