# 01-cluster-monitoring/06-kubelet-metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/06-kubelet-metrics.md`
- 前置文档：`01-monitoring-architecture.md`、`02-api-server-metrics.md`、`05-controller-manager-metrics.md`
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Prometheus‑2.45、Prometheus Operator、离线内网部署
- 适用环境：DEV/FAT/UAT/PROD，节点运行时组件同时适用 **RED（容器业务）+ USE（节点资源）** 双模型观测
- 文档范围：kubelet指标采集配置、PLEG/容器生命周期、Volume挂载、Pod状态、镜像拉取、驱逐、进程资源、生产告警规则、节点故障排查、多环境差异化策略

## 二、kubelet指标采集配置
### 2.1 Metrics端点基础信息
1. 指标地址：`https://node-ip:10250/metrics`
2. 认证：TLS节点证书，Prometheus Operator使用ServiceAccount鉴权访问各节点kubelet
3. 全局标准抓取参数
```yaml
interval: 15s
scrape_timeout: 10s
evaluation_interval: 15s
metrics_path: /metrics
scheme: https
```
4. 健康探针（无监控时序）
- `/livez`：kubelet进程存活
- `/readyz`：容器运行时连通、PLEG正常、可接收Pod操作

### 2.2 ServiceMonitor GitOps标准YAML
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kubelet
  namespace: kube-monitoring
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      kubernetes.io/os: linux
  endpoints:
  - port: https-metrics
    scheme: https
    metricsPath: /metrics
    interval: 15s
    scrapeTimeout: 10s
    tlsConfig:
      insecureSkipVerify: true
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
```
> 说明：使用NodeServiceDiscovery自动发现集群所有节点，无需手动维护节点IP列表；节点自签名证书跳过校验。

## 三、核心指标分层
### 3.1 RED模型：Pod/容器生命周期吞吐、失败、延迟
#### 3.1.1 Rate 操作吞吐
1. 容器启停总量
`kubelet_container_operations_total{operation=create/start/stop/delete}`
```promql
# 5分钟容器创建速率
sum by(node)(rate(kubelet_container_operations_total{operation="create"}[5m]))
```
2. 镜像拉取吞吐
`kubelet_image_pulls_total{result=success/failed}`
3. Volume挂载操作
`kubelet_volume_operations_total{operation=mount/unmount/attach/detach}`

#### 3.1.2 Errors 操作失败指标（故障核心）
1. 容器操作失败
`kubelet_container_operations_total{result="error"}`
2. 镜像拉取失败
`kubelet_image_pulls_total{result="failed"}`
3. 存储卷挂载失败
`kubelet_volume_operations_errors_total`
4. PLEG同步异常
`kubelet_pleg_relist_errors_total`：PLEG轮询容器运行时报错，代表kubelet与containerd通信故障
5. Pod沙箱创建失败
`kubelet_pod_sandbox_operations_total{result="error"}`

#### 3.1.3 Duration 操作延迟（直方图分位）
基线阈值（容器/卷操作统一标准）
| 百分位 | 正常基线 | Warning阈值 | Critical阈值 |
|--------|----------|-------------|--------------|
| P50    | <0.1s    | >0.5s       | >1s          |
| P90    | <0.3s    | >1s         | >3s          |
| P99    | <0.8s    | >3s         | >10s         |

核心PromQL：
```promql
# 容器创建P99延迟
histogram_quantile(0.99, sum(rate(kubelet_container_operation_duration_seconds_bucket{operation="create"}[5m])) by (le,node))
# 卷挂载P99延迟
histogram_quantile(0.99, sum(rate(kubelet_volume_operation_duration_seconds_bucket{operation="mount"}[5m])) by (le,node))
```

## 四、kubelet专属核心细分指标
### 4.1 PLEG 容器同步核心指标（节点卡顿根因）
1. `kubelet_pleg_relist_duration_seconds_bucket`：PLEG轮询耗时，数值高代表containerd响应缓慢
2. `kubelet_pleg_relist_interval_seconds`：PLEG轮询间隔，默认1s，堆积会自动拉长间隔
3. `kubelet_pleg_relist_latency_seconds`：容器状态同步延迟
判定标准：PLEG P99 >3s → 节点容器运行时阻塞，Pod状态更新滞后

### 4.2 镜像管理指标
1. `kubelet_image_size_bytes`：本地镜像占用磁盘总大小
2. `kubelet_image_garbage_collected_bytes_total`：镜像GC清理容量
3. `kubelet_images_total`：节点本地镜像总数，镜像过多会拉长拉取/列表耗时

### 4.3 Volume 存储指标
1. `kubelet_volumes_in_use`：当前挂载使用卷数量
2. `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes`：PVC磁盘使用率
3. `kubelet_volume_stats_inodes_free`：存储卷inode水位

### 4.4 节点驱逐指标（资源压力识别）
1. `kubelet_evictions_total{signal=memory.available/memory.usageHigh/nodefs.available/imagefs.available}`：各类资源驱逐Pod计数
2. `kubelet_eviction_durations_seconds_bucket`：驱逐流程耗时
3. `kubelet_preemptions_total`：主动抢占低优先级Pod

### 4.5 Pod/沙箱状态计数
1. `kubelet_running_pods`：节点运行中Pod瞬时数量
2. `kubelet_running_containers`：节点运行容器总数
3. `kubelet_sandboxes_total{state=ready/notready}`：Pod沙箱就绪状态

## 五、USE模型：节点&kubelet进程资源饱和度
### 5.1 kubelet进程自身资源
由cadvisor容器指标采集
1. `container_cpu_usage_seconds_total{container="kubelet"}`：kubelet CPU占用，PLEG频繁轮询会打满CPU
2. `container_memory_usage_bytes{container="kubelet"}`：内存占用，大量Pod/镜像缓存持续上涨
3. `container_file_descriptors{container="kubelet"}`：句柄耗尽会导致容器操作失败

### 5.2 节点磁盘分层水位（区分imagefs/nodefs）
1. `kubelet_nodefs_available_bytes / kubelet_nodefs_capacity_bytes`：节点根分区剩余
2. `kubelet_imagefs_available_bytes / kubelet_imagefs_capacity_bytes`：镜像存储分区剩余
判定：任一分区剩余<10%触发镜像GC、Pod驱逐

### 5.3 容器资源使用率（cgroup）
`container_cpu_usage_seconds_total` / `container_memory_usage_bytes` 单个Pod资源占用，联动驱逐指标判断资源瓶颈

## 六、生产PrometheusRule告警规则（三层告警对齐顶层规范）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kubelet-rules
  namespace: kube-monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  groups:
  - name: kubelet.rules
    interval: 15s
    rules:
    # ========== Emergency 紧急（短信+企业微信双通道 7×24）==========
    - alert: KubeletNodeDown
      expr: up{job="kubelet"} == 0
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "节点kubelet失联"
        message: "节点 {{$labels.node}} kubelet无法访问，Pod调度、驱逐、卷挂载全部失效"

    - alert: NodeDiskCriticalFull
      expr: (kubelet_nodefs_available_bytes / kubelet_nodefs_capacity_bytes) < 0.05 OR (kubelet_imagefs_available_bytes / kubelet_imagefs_capacity_bytes) < 0.05
      for: 2m
      labels:
        severity: Emergency
      annotations:
        summary: "节点磁盘剩余不足5%，触发强制驱逐"

    - alert: MassPodEviction
      expr: sum by(node)(rate(kubelet_evictions_total[5m])) > 20
      for: 3m
      labels:
        severity: Emergency
      annotations:
        summary: "节点大规模驱逐Pod"
        message: "节点{{$labels.node}}资源耗尽，持续驱逐业务Pod"

    # ========== Critical 严重（当日处理，业务Pod异常/存储故障）==========
    - alert: PLEGHighLatency
      expr: histogram_quantile(0.99, sum(rate(kubelet_pleg_relist_duration_seconds_bucket[5m])) by (le,node)) > 3
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "节点PLEG同步延迟过高，容器状态更新停滞"

    - alert: VolumeMountFailedHigh
      expr: sum by(node)(rate(kubelet_volume_operations_errors_total[5m])) > 10
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "节点卷挂载失败频繁，Pod无法启动"

    - alert: ImagePullFailedHigh
      expr: sum by(node)(rate(kubelet_image_pulls_total{result="failed"}[5m])) > 5
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "节点镜像拉取持续失败"

    # ========== Warning 预警（工作时段处理，无阻断影响）==========
    - alert: NodeDiskWarning
      expr: (kubelet_nodefs_available_bytes / kubelet_nodefs_capacity_bytes) < 0.2 OR (kubelet_imagefs_available_bytes / kubelet_imagefs_capacity_bytes) < 0.2
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "节点磁盘剩余不足20%，建议清理镜像/日志"

    - alert: PLEGRelistError
      expr: sum by(node)(rate(kubelet_pleg_relist_errors_total[5m])) > 1
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "节点PLEG同步存在报错，containerd连通异常"

    - alert: KubeletCpuHighWarning
      expr: sum(rate(container_cpu_usage_seconds_total{container="kubelet"}[5m])) / sum(kube_pod_container_resource_limits_cpu_cores{container="kubelet"}) > 0.85
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "kubelet进程CPU使用率超85%"
```

## 七、Grafana大盘观测维度
1. 节点总览面板
    - 所有节点kubelet在线状态、运行Pod/容器总数
    - nodefs/imagefs磁盘使用率曲线、inode水位
    - 节点驱逐总量趋势
2. PLEG运行面板
    - 各节点PLEG P50/P90/P99延迟TOP排行
    - PLEG错误次数、轮询间隔拉长趋势
3. 容器&镜像面板
    - 容器创建/启停失败速率、镜像拉取成功/失败占比
    - 本地镜像总容量、GC清理容量曲线
4. 存储卷面板
    - PVC磁盘使用率TOP10、卷挂载/卸载失败计数
    - 节点在用卷总数、动态存储供给延迟
5. 资源驱逐面板
    - 按驱逐信号分类驱逐Pod数量柱状图
    - 驱逐流程耗时分位延迟

## 八、多环境差异化配置（对齐顶层架构规范）
1. DEV环境
    - 无Prometheus Operator，仅metrics-server，无kubelet时序指标采集
    - 故障人工`kubectl describe node`查看磁盘、驱逐事件
2. FAT环境
    - 部署kubelet ServiceMonitor，无Thanos长期归档
    - 仅Warning/Critical告警，关闭Emergency短信，仅企业微信推送
    - 时序数据保留7天
3. UAT环境
    - 完整采集全套PrometheusRule，告警阈值与生产完全对齐
    - 全等级告警启用，仅企业微信通知，无短信
    - 数据保存30天，模拟磁盘满、节点驱逐、镜像拉取失败验证告警
4. PROD强制约束
    - Thanos归档kubelet指标至MinIO，存储180天，用于节点宕机、业务Pod异常回溯
    - ServiceMonitor、PrometheusRule统一GitOps托管，禁止临时修改
    - Emergency等级短信+企业微信双通道7×24推送
    - Alertmanager告警抑制：节点kubelet离线时，抑制该节点所有Pod异常、卷挂载失败衍生告警
    - 定期巡检高PLEG延迟节点，清理冗余镜像、扩容节点磁盘、优化containerd配置

## 九、监控采集与节点故障完整排查链路
### 9.1 kubelet指标抓取失败 up=0
根因清单
1. 节点防火墙拦截10250端口
2. NodeSelector/ServiceMonitor标签匹配异常，节点未被发现
3. 节点kubelet进程崩溃、systemd服务异常
4. Node网络策略阻断监控组件访问节点kubelet端口

排查命令
```bash
# 节点本地验证kubelet指标端口
curl -k https://127.0.0.1:10250/metrics
# 查看kubelet运行状态
systemctl status kubelet
# 查看节点事件定位kubelet异常
kubectl describe node node-xxx
```

### 9.2 PLEG延迟过高，节点Pod状态卡顿排查流程
1. 观测`kubelet_pleg_relist_errors_total`，判断是否containerd通信报错
2. 查看node-exporter磁盘IO指标，确认节点磁盘IO饱和拖慢容器列表
3. 清理节点大量冗余镜像，减少镜像列表耗时
4. 优化containerd配置、调高kubelet并发参数

### 9.3 节点频繁驱逐Pod故障下钻
1. 通过`kubelet_evictions_total`区分驱逐信号（内存/磁盘/镜像分区）
2. 查看对应分区使用率指标，确认磁盘/内存水位
3. 清理节点容器日志、无用镜像、大PVC文件释放空间
4. 调高Pod资源request，避免节点资源耗尽

### 9.4 PVC挂载失败批量报错排查链路
1. 拆分`kubelet_volume_operations_errors_total`定位mount/attach失败
2. 联动CSI控制器指标，确认存储后端API连通性
3. 检查节点存储插件、云存储权限、磁盘分区inode耗尽

### 9.5 告警误报优化方案
1. 全局抓取间隔15s，禁止高频抓取加重kubelet压力
2. 所有告警`for`延时最低3分钟，过滤临时磁盘抖动、瞬时批量创建Pod
3. 发布扩容时段配置Alertmanager静默规则，抑制短时镜像拉取峰值告警

## 十、关联文档
1. 顶层架构：`01-monitoring-architecture.md` RED/USE模型、统一三层告警规范
2. 运行时指标：`07-container-runtime-metrics.md` containerd底层指标联动
3. 节点系统指标：`08-node-exporter-metrics.md` CPU/内存/磁盘/网卡系统层指标
4. 对象状态指标：`09-kube-state-metrics.md` Pod/PVC/Node静态资源状态
5. 故障方法论：`03-troubleshooting-methodology.md` 节点类故障通用排查流程
6. PromQL速查：`10-monitoring-best-practice.md` kubelet专用查询语句汇总
7. 集群健康巡检：`02-cluster-health-check` 定时检测节点磁盘、驱逐事件脚本