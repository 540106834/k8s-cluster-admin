# 01-cluster-monitoring/07-container-runtime-metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/07-container-runtime-metrics.md`
- 前置文档：`06-kubelet-metrics.md`、`01-monitoring-architecture.md`
- 集群基准：Kubernetes 1.32.13、containerd 2.1.5、Prometheus 2.45、Prometheus Operator、离线内网
- 适用环境：DEV/FAT/UAT/PROD；运行时采用 **RED（操作吞吐/失败/延迟）+ USE（运行时进程资源、IO饱和度）** 双模型观测
- 文档范围：containerd metrics采集配置、CRI gRPC链路指标、镜像/容器/沙箱生命周期、磁盘IO/GC垃圾回收、容器运行时错误、告警规则、运行时卡顿故障排查、多环境策略

## 二、Containerd 指标采集配置
### 2.1 Metrics端点基础信息
1. 默认指标地址：`http://127.0.0.1:1338/v1/metrics`（仅本地回环监听）
2. 认证：无TLS，纯HTTP；仅节点本地可访问，由kubelet/node-exporter侧转发抓取
3. 全局抓取标准参数
```yaml
interval: 15s
scrape_timeout: 8s
evaluation_interval: 15s
metrics_path: /v1/metrics
scheme: http
```
4. containerd 健康探针
- `/v1/health`：校验containerd服务、shim、snapshotter连通性

### 2.2 采集实现方案（两种主流）
#### 方案1：NodeExporter TextFile 静态导出（推荐生产）
节点systemd定时脚本，curl拉取containerd metrics写入文本，node-exporter读取暴露，全局统一抓取
```bash
# /usr/local/bin/containerd-metrics-exporter.sh
#!/bin/bash
curl -s http://127.0.0.1:1338/v1/metrics > /var/lib/node-exporter/containerd-metrics.prom
```
#### 方案2：Sidecar 本地代理容器（小规模集群）
DaemonSet在每个节点部署轻量代理，HostNetwork绑定1339端口转发127.0.0.1:1338指标，Prometheus直接发现节点端口抓取

### 2.3 ServiceMonitor 标准YAML（NodeExporter TextFile模式）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: containerd-runtime
  namespace: kube-monitoring
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-exporter
  endpoints:
  - port: metrics
    interval: 15s
    scrapeTimeout: 8s
    relabelings:
    - sourceLabels: [__metrics_path__]
      regex: /metrics
      targetLabel: __metrics_path__
      replacement: /metrics
```

## 三、核心指标分层：RED模型（CRI操作全链路）
### 3.1 Rate CRI操作吞吐（gRPC调用总量）
核心指标：`containerd_grpc_server_handled_total{service,method}`
service区分三类核心CRI服务：
- `runtime.v1.RuntimeService`：容器/沙箱启停、状态查询
- `runtime.v1.ImageService`：镜像拉取、删除、列表
- `runtime.v1.SnapshotService`：镜像分层快照存储操作

常用PromQL
```promql
# 全节点5分钟CRI总调用速率
sum by(node, service, method)(rate(containerd_grpc_server_handled_total[5m]))
# 创建沙箱（Pod沙箱）调用速率
sum by(node)(rate(containerd_grpc_server_handled_total{method="CreateSandbox"}[5m]))
# 镜像拉取Pull调用速率
sum by(node)(rate(containerd_grpc_server_handled_total{method="PullImage"}[5m]))
```

配套吞吐指标
1. `containerd_containers_total{state}`：节点各状态容器计数（created/running/stopped/deleted）
2. `containerd_sandboxes_total{state}`：Pod沙箱数量
3. `containerd_images_total`：本地镜像总数

### 3.2 Errors 运行时故障指标（根因定位核心）
1. gRPC调用错误码指标 `containerd_grpc_server_handled_total{code=Unknown/DeadlineExceeded/ResourceExhausted}`
    - DeadlineExceeded：CRI调用超时 → containd卡顿、磁盘IO阻塞
    - Unknown：运行时内部panic、shim进程崩溃
    - ResourceExhausted：磁盘满、句柄耗尽、内存不足
```promql
# CRI错误调用占比
sum by(node)(rate(containerd_grpc_server_handled_total{code!="OK"}[5m])) / sum by(node)(rate(containerd_grpc_server_handled_total[5m]))
```
2. Shim进程崩溃指标 `containerd_shim_crashes_total`：容器shim异常退出，容器失联
3. Snapshot存储错误 `containerd_snapshot_errors_total{operation}`：分层快照挂载/删除失败
4. GC垃圾回收失败 `containerd_gc_errors_total`：镜像/容器GC清理失败，磁盘无法释放

### 3.3 Duration CRI调用延迟（直方图P50/P90/P99）
统一基线阈值（所有CRI方法通用）
| 百分位 | 正常基线 | Warning阈值 | Critical阈值 |
|--------|----------|-------------|--------------|
| P50    | <0.05s   | >0.3s       | >1s          |
| P90    | <0.2s    | >1s         | >5s          |
| P99    | <0.5s    | >3s         | >10s         |

核心PromQL
```promql
# PullImage镜像拉取P99延迟
histogram_quantile(0.99, sum(rate(containerd_grpc_server_seconds_bucket{method="PullImage"}[5m])) by (le,node))
# CreateContainer创建容器P99延迟
histogram_quantile(0.99, sum(rate(containerd_grpc_server_seconds_bucket{method="CreateContainer"}[5m])) by (le,node))
```

## 四、Containerd 专属细分业务指标
### 4.1 Snapshotter 镜像分层存储（磁盘性能瓶颈核心）
1. `containerd_snapshot_layers_total`：节点镜像分层总数，分层过多拉高拉取/删除耗时
2. `containerd_snapshot_usage_bytes`：快照镜像总占用磁盘容量
3. `containerd_snapshot_operation_seconds_bucket`：快照创建/挂载耗时，直接影响PLEG延迟

判定标准：快照操作P99>2s → 节点磁盘IO饱和、overlayfs性能差

### 4.2 GC 垃圾回收指标（磁盘水位联动）
1. `containerd_gc_duration_seconds_bucket`：GC执行耗时
2. `containerd_gc_reclaimed_bytes_total`：GC清理释放磁盘容量
3. `containerd_gc_queue_depth`：待GC清理资源队列深度，数值持续上涨代表GC阻塞

### 4.3 Shim 容器进程指标
1. `containerd_shim_running_total`：当前运行shim进程数量
2. `containerd_shim_cpu_usage_seconds_total`：shim进程CPU消耗，高消耗代表容器卡死、日志刷屏
3. `containerd_shim_memory_usage_bytes`：shim内存泄漏监控

### 4.4 镜像拉取细分指标
1. `containerd_image_pull_bytes_total`：累计拉取镜像字节
2. `containerd_image_pull_duration_seconds_bucket`：单镜像拉取总耗时
3. `containerd_image_pull_layer_wait_seconds`：分层下载等待延迟（镜像仓库带宽瓶颈）

## 五、USE模型：运行时进程&磁盘饱和度
### 5.1 Containerd 主进程资源（node-exporter采集）
1. `process_cpu_seconds_total{comm="containerd"}`：containerd主线程CPU占用，大量CRI调用、GC会持续打满CPU
2. `process_memory_virtual_bytes{comm="containerd"}`：虚拟内存，镜像元数据缓存持续上涨易内存溢出
3. `process_file_descriptors{comm="containerd"}`：句柄数上限耗尽会导致所有CRI调用失败

### 5.2 节点磁盘IO饱和度（联动snapshot指标）
1. `node_disk_io_time_seconds_total`：磁盘IO等待时间，IO打满会直接拉高所有CRI操作延迟
2. `node_filesystem_free_bytes{mountpoint="/var/lib/containerd"}`：containerd数据目录剩余空间
判定：/var/lib/containerd剩余<10%触发镜像拉取失败、GC失效

## 六、生产PrometheusRule告警规则（三层告警对齐顶层规范）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: containerd-runtime-rules
  namespace: kube-monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  groups:
  - name: containerd.rules
    interval: 15s
    rules:
    # ========== Emergency 紧急（短信+企业微信双通道 7×24）==========
    - alert: ContainerdGRPCAllFailed
      expr: sum by(node)(rate(containerd_grpc_server_handled_total{code!="OK"}[5m])) / sum by(node)(rate(containerd_grpc_server_handled_total[5m])) > 0.8
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "节点containerd CRI调用80%失败"
        message: "节点{{$labels.node}} containerd服务异常，所有Pod创建/启停、镜像拉取失效，kubelet PLEG阻塞"

    - alert: ContainerdDataDiskCriticalFull
      expr: node_filesystem_free_bytes{mountpoint="/var/lib/containerd"} / node_filesystem_size_bytes{mountpoint="/var/lib/containerd"} < 0.05
      for: 2m
      labels:
        severity: Emergency
      annotations:
        summary: "containerd数据目录磁盘剩余不足5%"

    # ========== Critical 严重（当日处理，业务Pod无法启动）==========
    - alert: ContainerdGRPCP99HighLatency
      expr: histogram_quantile(0.99, sum(rate(containerd_grpc_server_seconds_bucket[5m])) by (le,node)) > 10
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "CRI调用P99延迟超10s，PLEG同步卡顿"

    - alert: ShimProcessCrashHigh
      expr: sum by(node)(rate(containerd_shim_crashes_total[5m])) > 5
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "节点容器shim进程频繁崩溃，业务容器异常退出"

    - alert: SnapshotOperationFailed
      expr: sum by(node)(rate(containerd_snapshot_errors_total[5m])) > 8
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "镜像快照操作频繁失败，镜像无法加载"

    # ========== Warning 预警（工作时段处理，无阻断影响）==========
    - alert: ContainerdDataDiskWarning
      expr: node_filesystem_free_bytes{mountpoint="/var/lib/containerd"} / node_filesystem_size_bytes{mountpoint="/var/lib/containerd"} < 0.2
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "containerd磁盘剩余不足20%，建议执行镜像GC清理"

    - alert: ContainerdGCLongDuration
      expr: histogram_quantile(0.90, sum(rate(containerd_gc_duration_seconds_bucket[5m])) by (le,node)) > 5
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "containerd GC垃圾回收耗时过长，磁盘释放缓慢"

    - alert: ContainerdCpuHighWarning
      expr: sum(rate(process_cpu_seconds_total{comm="containerd"}[5m])) / 4 > 0.85
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "containerd进程CPU占用超85%，IO/GC阻塞"
```

## 七、Grafana大盘观测维度
1. Containerd总览面板
    - 全节点CRI调用总量、错误占比TOP节点排行
    - containerd进程CPU/内存/句柄资源曲线
    - /var/lib/containerd磁盘使用率、GC释放容量趋势
2. CRI延迟面板
    - CreateSandbox/PullImage/CreateContainer等核心方法P50/P90/P99延迟
    - 按错误码拆分失败调用柱状图（超时/资源耗尽/内部错误）
3. 镜像&快照面板
    - 节点镜像总数、快照分层数量、快照操作耗时
    - 镜像拉取总流量、分层下载等待延迟
4. Shim与GC面板
    - shim进程崩溃次数、运行shim数量、shim资源占用
    - GC队列深度、单次GC耗时、GC失败计数
5. 联动故障面板
    - 与kubelet PLEG延迟指标合并展示，定位运行时导致节点卡顿根因

## 八、多环境差异化配置（对齐顶层架构规范）
1. DEV环境
    - 无标准化指标采集，仅本地curl手动拉取containerd metrics排查
    - 无告警规则，故障人工重启containerd服务
2. FAT测试环境
    - 部署node-exporter textfile导出采集containerd指标
    - 仅Warning/Critical告警，关闭Emergency短信，仅企业微信推送
    - 时序数据保留7天，不做长期容量分析
3. UAT预发环境
    - 完整采集全套PrometheusRule，告警阈值与生产完全一致
    - 全等级告警启用，仅企业微信通知，无短信
    - 数据保存30天，模拟磁盘满、镜像拉取超时、shim崩溃验证告警触发
4. PROD生产强制约束
    - Thanos归档containerd指标至MinIO，存储180天，用于节点Pod失联、镜像故障回溯
    - ServiceMonitor、PrometheusRule统一GitOps托管，禁止临时修改规则
    - Emergency等级短信+企业微信双通道7×24推送
    - Alertmanager告警抑制：containerd故障时，抑制同节点kubelet PLEG延迟、Pod启动失败衍生告警
    - 定时自动化镜像GC脚本，降低磁盘满告警频次；定期巡检高延迟快照节点，优化磁盘介质

## 九、监控采集与运行时故障完整排查链路
### 9.1 containerd指标抓取失败
根因清单
1. containerd metrics服务未启动（配置未开启metrics地址）
2. textfile导出脚本未定时执行，文件为空
3. 节点防火墙/本地回环限制1338端口访问
4. node-exporter无读取/var/lib/node-exporter目录权限

排查命令
```bash
# 节点本地验证metrics端口
curl http://127.0.0.1:1338/v1/metrics
# 查看导出脚本执行日志
journalctl -u containerd-metrics-exporter.timer
# 检查containerd配置是否开启metrics
grep metrics /etc/containerd/config.toml
```

### 9.2 CRI调用大面积超时、PLEG延迟飙升排查流程
1. 查看`containerd_grpc_server_seconds_bucket`确认所有方法延迟同步上涨
2. 检查node-exporter磁盘IO指标，判断是否磁盘IO饱和
3. 观测GC队列深度`containerd_gc_queue_depth`，确认GC阻塞抢占IO
4. 清理无用镜像、扩容/var/lib/containerd磁盘、调整GC并发参数

### 9.3 Shim频繁崩溃、容器异常退出排查链路
1. 查看`containerd_shim_crashes_total`确认崩溃次数上涨
2. 抓取shim进程日志 `journalctl -u containerd | grep shim`
3. 区分根因：容器OOM、内核bug、镜像文件损坏、cgroup权限异常

### 9.4 镜像拉取失败、快照报错排查链路
1. 拆分PullImage错误码，区分仓库超时/磁盘满/快照层损坏
2. 查看快照操作延迟，判断overlayfs性能瓶颈
3. 执行`crictl images prune`手动GC清理无用镜像释放空间

### 9.5 告警误报优化方案
1. 全局抓取间隔统一15s，禁止高频抓取加重containerd gRPC压力
2. 所有告警`for`延时最低3分钟，过滤批量发布瞬时CRI峰值抖动
3. 版本发布时段配置Alertmanager静默规则，抑制短时镜像拉取延迟告警

## 十、关联文档
1. 顶层架构：`01-monitoring-architecture.md` RED/USE双模型、统一三层告警规范
2. 上层节点指标：`06-kubelet-metrics.md` kubelet PLEG与containerd CRI联动链路
3. 节点系统层指标：`08-node-exporter-metrics.md` CPU/内存/磁盘IO系统底层指标
4. 对象状态指标：`09-kube-state-metrics.md` Pod/镜像静态资源状态指标
5. 故障方法论：`03-troubleshooting-methodology.md` 容器运行时卡顿通用排查流程
6. PromQL速查：`10-monitoring-best-practice.md` containerd专用查询语句汇总
7. 集群健康巡检：`02-cluster-health-check` 定时检测containerd磁盘、shim崩溃脚本