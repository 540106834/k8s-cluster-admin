# 01-cluster-monitoring/03-etcd-metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/03-etcd-metrics.md`
- 前置文档：`01-monitoring-architecture.md`、`02-api-server-metrics.md`
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Prometheus‑2.45、Prometheus Operator、离线内网部署
- 适用环境：DEV/FAT/UAT/PROD，基础设施组件遵循**USE模型**观测
- 文档范围：etcd指标采集配置、核心分层指标、Raft集群、磁盘IO、数据库容量、生产PrometheusRule告警、Grafana大盘、故障排查、多环境差异化配置

## 二、etcd指标采集配置（ServiceMonitor标准清单）
### 2.1 Metrics端点基础信息
1. 暴露地址：`https://<master>:2379/metrics`
2. 认证：TLS双向证书，集群CA统一签发，Prometheus Operator自动挂载SA证书
3. 标准抓取全局参数
```yaml
interval: 15s
scrape_timeout: 10s
evaluation_interval: 15s
metrics_path: /metrics
scheme: https
```
4. 健康探针端点（不采集时序，用于存活校验）
- `/health`：集群健康、Leader状态、节点同步校验
- `/livez`：进程存活
- `/readyz`：Raft同步完成、读写可用

### 2.2 ServiceMonitor标准YAML（GitOps托管）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kube-etcd
  namespace: kube-monitoring
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      app: etcd
  endpoints:
  - port: https-metrics
    scheme: https
    metricsPath: /metrics
    interval: 15s
    scrapeTimeout: 10s
    tlsConfig:
      serverName: etcd.kube-system.svc.cluster.local
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabelings:
    - sourceLabels: [__meta_kubernetes_endpoint_port_name]
      action: keep
      regex: https-metrics
```
> 部署说明：etcd为静态Pod，kube-system内置etcd Service自动生成Endpoint，无需静态配置；离线环境复用集群内置CA证书。

## 三、核心指标分层（严格遵循USE模型）
### 3.1 Utilization 资源使用率（存储/CPU/内存/句柄）
1. 数据库容量
- `etcd_db_total_size_in_bytes`：DB总存储占用（含快照、临时文件）
- `etcd_db_size_in_use_bytes`：实际有效数据大小
- `etcd_mvcc_db_total_size_in_bytes`：MVCC多版本占用（碎片核心来源）
2. 进程资源（kubelet容器指标）
- `container_cpu_usage_seconds_total`：etcd CPU占用
- `container_memory_usage_bytes`：内存占用（MVCC内存缓存）
- `container_file_descriptors`：文件句柄数，上限默认65535
3. 磁盘分区使用率（node-exporter）
- `node_filesystem_size_bytes / node_filesystem_avail_bytes` etcd数据盘分区使用率

#### 容量基线阈值
- Warning：DB总容量 > 70G / 分区使用率 > 80%
- Critical：DB总容量 > 90G / 分区使用率 > 90%
- Emergency：分区使用率 ≥95%

### 3.2 Saturation 饱和度（队列、等待、IO延迟、Raft堆积）
1. Raft日志提交延迟（集群同步核心）
`etcd_server_commit_duration_seconds_bucket`
| 分位 | 基线 | Warning | Critical |
| ---- | ---- | ------- | -------- |
| P50  | <10ms | >50ms   | >100ms   |
| P99  | <50ms | >200ms  | >500ms   |
2. Raft消息队列堆积
- `etcd_server_raft_message_queue_length`：待同步消息队列长度
持续>500代表节点同步阻塞
3. MVCC事务等待队列
`etcd_mvcc_write_wait_latency_seconds_bucket`：写事务排队耗时
4. 磁盘IO饱和度（node-exporter）
- `node_disk_io_time_seconds_total` %iowait
- `node_disk_write_queue_length` 磁盘写队列深度

### 3.3 Errors 错误指标（集群故障、读写失败、快照异常）
1. Raft集群错误
- `etcd_server_raft_leader_changes_total`：Leader切换次数（频繁切换=集群不稳定）
- `etcd_server_raft_heartbeat_failed_total`：心跳丢失
- `etcd_server_proposals_failed_total` 提案提交失败（写入拒绝）
2. 读写请求错误
`etcd_server_requests_failed_total` 区分read/write失败
3. 快照异常
- `etcd_server_snapshot_save_failed_total` 快照保存失败
- `etcd_server_snapshot_send_failed_total` 快照同步失败
4. 数据库告警
`etcd_db_alarm_total` 标签alarm=spaceQuota（空间超限告警）

## 四、etcd集群专属Raft细分指标（集群稳定性判断核心）
1. Leader身份标识
`etcd_server_is_leader`：1=当前节点Leader，0=Follower
PromQL快速判断集群多Leader：`sum(etcd_server_is_leader) != 1`
2. 集群节点在线数
`etcd_server_health{health="true"}` 正常节点计数，标准集群3节点需全部在线
3. 提案吞吐（写入速率）
`etcd_server_proposals_applied_total` 5m速率代表集群写入QPS
4. 日志落后量（Follower同步差距）
`etcd_server_raft_index_diff` Leader与Follower日志索引差值
差值持续>10000代表节点严重落后，触发快照同步

## 五、读写性能细分指标（配合API Server定位慢存储）
1. 请求耗时直方图
`etcd_server_requests_duration_seconds_bucket` 区分range/put/delete/txn
2. 读/写总量速率
```promql
# 5分钟写QPS
sum(rate(etcd_server_requests_total{type=~"put|txn"}[5m]))
# 5分钟读QPS
sum(rate(etcd_server_requests_total{type="range"}[5m]))
```
3. 压缩指标
`etcd_server_compaction_total` 定时压缩执行次数，压缩失败会持续放大MVCC碎片

## 六、生产级告警规则 PrometheusRule（对齐三层告警分层）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kube-etcd-rules
  namespace: kube-monitoring
  labels:
    prometheus: k8s
    role: alert-rules
spec:
  groups:
  - name: kube-etcd.rules
    interval: 15s
    rules:
    # ========== Emergency 紧急（短信+企业微信双通知 7*24响应）==========
    - alert: EtcdInstanceDown
      expr: up{job="kube-etcd"} == 0
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "etcd节点离线"
        message: "etcd实例 {{$labels.instance}} 抓取失败，集群副本不足风险"

    - alert: EtcdMultipleLeader
      expr: sum(etcd_server_is_leader) != 1
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "etcd集群存在多Leader"
        message: "集群Leader数量异常，数据写入一致性破坏"

    - alert: EtcdSpaceQuotaAlarm
      expr: etcd_db_alarm_total{alarm="spaceQuota"} > 0
      for: 1m
      labels:
        severity: Emergency
      annotations:
        summary: "etcd空间配额耗尽"
        message: "etcd触发空间超限告警，集群拒绝所有写入操作"

    - alert: EtcdDiskFull
      expr: sum by (device)(node_filesystem_avail_bytes{mountpoint=~".*etcd.*"}) / sum by (device)(node_filesystem_size_bytes{mountpoint=~".*etcd.*"}) < 0.05
      for: 2m
      labels:
        severity: Emergency
      annotations:
        summary: "etcd数据磁盘剩余不足5%"

    # ========== Critical 严重（当日处理，API延迟上涨风险）==========
    - alert: EtcdLeaderFrequentChange
      expr: sum(rate(etcd_server_raft_leader_changes_total[10m])) > 3
      for: 5m
      labels:
        severity: Critical
      annotations:
        summary: "etcd 10分钟内Leader切换超3次"
        message: "集群网络波动/磁盘IO过高导致Leader频繁切换，管控API卡顿"

    - alert: EtcdRaftIndexLagHigh
      expr: etcd_server_raft_index_diff > 10000
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "Follower日志严重落后Leader"

    - alert: EtcdCommitLatencyP99High
      expr: histogram_quantile(0.99, sum(rate(etcd_server_commit_duration_seconds_bucket[5m])) by (le)) > 0.5
      for: 3m
      labels:
        severity: Critical
      annotations:
        summary: "etcd提交P99延迟超500ms"

    - alert: EtcdDBSizeCritical
      expr: etcd_db_total_size_in_bytes > 90 * 1024 * 1024 * 1024
      for: 5m
      labels:
        severity: Critical
      annotations:
        summary: "etcd数据库容量超90G"

    # ========== Warning 预警（工作时段处理，无业务阻断）==========
    - alert: EtcdDiskUsageWarning
      expr: sum by (device)(node_filesystem_avail_bytes{mountpoint=~".*etcd.*"}) / sum by (device)(node_filesystem_size_bytes{mountpoint=~".*etcd.*"}) < 0.2
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "etcd磁盘剩余不足20%"

    - alert: EtcdDBSizeWarning
      expr: etcd_db_total_size_in_bytes > 70 * 1024 * 1024 * 1024
      for: 10m
      labels:
        severity: Warning
      annotations:
        summary: "etcd数据库容量超70G，建议定时碎片压缩"

    - alert: EtcdRaftQueueBacklog
      expr: etcd_server_raft_message_queue_length > 500
      for: 5m
      labels:
        severity: Warning
      annotations:
        summary: "etcd Raft同步消息队列堆积"
```

## 七、Grafana大盘标准观测维度
1. 集群总览面板
    - 节点在线数量、Leader状态、Leader切换次数趋势
    - etcd实例up状态、CPU/内存/句柄使用率
    - 数据库总容量、数据盘使用率曲线
2. Raft集群同步面板
    - 各节点日志索引差值、Raft消息队列长度
    - 心跳失败、提案失败计数
    - P50/P99 commit提交延迟分位
3. 读写性能面板
    - 总读写QPS、Put/Txn写入量
    - 读写延迟P99曲线、失败请求占比
4. 磁盘与碎片面板
    - MVCC总占用、压缩执行次数
    - 磁盘%iowait、写队列深度
    - 快照保存/同步失败计数
5. 告警面板
    - spaceQuota空间告警、读写失败总数

## 八、多环境差异化配置（对齐顶层架构文档）
1. DEV环境
    - 无Prometheus Operator，仅metrics-server，无etcd时序指标采集
2. FAT环境
    - 部署etcd ServiceMonitor，无Thanos归档
    - 仅Warning/Critical告警，关闭Emergency短信，仅企业微信推送
    - 数据保留7天，不做长期容量趋势观测
3. UAT环境
    - 完整采集+全套PrometheusRule，阈值与生产完全对齐
    - 全部告警等级启用，仅企业微信通知，无短信
    - 数据保留30天，模拟生产容量增长场景验证压缩策略
4. PROD强制约束
    - Thanos归档etcd指标至MinIO，存储180天，用于故障回溯
    - ServiceMonitor、PrometheusRule GitOps托管，禁止临时修改
    - Emergency等级短信+企业微信双通道7×24推送
    - Alertmanager配置告警抑制：etcd节点离线时，抑制下游apiserver延迟、Pod异常告警
    - 配合node-exporter观测etcd数据盘IO指标，磁盘瓶颈优先定位
    - 每周巡检etcd碎片容量，配置定时自动压缩

## 九、监控采集与集群故障完整排查链路
### 9.1 etcd指标抓取失败 up=0
根因清单：
1. Master节点防火墙/NetworkPolicy封禁2379端口
2. ServiceMonitor标签selector与etcd Service不匹配
3. TLS证书过期、serverName配置错误，证书校验失败
4. etcd静态Pod异常崩溃，进程未启动

排查命令：
```bash
# Prometheus Pod内手动测试指标连通
curl -k https://etcd.kube-system.svc.cluster.local:2379/metrics -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
# 查看etcd Pod状态
kubectl get pod -n kube-system -l app=etcd
# 检查网络策略放行kube-monitoring访问kube-system 2379端口
kubectl get netpol -n kube-system
```

### 9.2 API Server延迟飙升，根因定位etcd瓶颈（USE下钻）
1. 第一步：查看etcd commit P99延迟是否超标
2. 第二步：观测磁盘%iowait、写队列深度，区分磁盘性能瓶颈
3. 第三步：查看raft_index_diff，判断Follower同步落后
4. 第四步：检查etcd_db_total_size_in_bytes，确认MVCC碎片过大
优化方案：定时compact压缩、扩容高速SSD数据盘、拆分大资源List请求减少etcd写入

### 9.3 频繁Leader切换故障排查链路
1. 查看节点间网络延迟、丢包（node-exporter网卡指标）
2. 核查etcd数据盘IO饱和，磁盘阻塞Raft心跳同步
3. 检查etcd内存资源不足，MVCC缓存挤压导致进程卡顿
4. 集群节点数量不足（低于3副本），网络抖动直接触发切主

### 9.4 空间Quota告警紧急处理流程
1. 临时清理无用CRD、废弃Namespace释放存储空间
2. 手动执行etcd compact压缩，清理MVCC历史版本
3. 扩容etcd数据磁盘，调高空间配额上限
4. 优化控制器List/Watch，减少无效etcd写入

## 十、关联文档
1. 顶层架构：`01-monitoring-architecture.md` 监控整体框架、USE模型、告警分层标准
2. 管控面指标：`02-api-server-metrics.md` API Server RED指标与etcd交互链路
3. 节点系统指标：`08-node-exporter-metrics.md` 磁盘、IO、系统资源观测
4. 故障方法论：`03-troubleshooting-methodology.md` 存储层故障定位通用流程
5. 监控速查：`10-cheatsheet/01-monitoring-cheatsheet.md` etcd专用PromQL汇总
6. 集群健康巡检：`02-cluster-health-check` etcd集群定时健康探测脚本