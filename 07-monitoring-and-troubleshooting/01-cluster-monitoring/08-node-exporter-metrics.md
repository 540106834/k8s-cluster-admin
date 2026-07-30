# 01-cluster-monitoring/08-node-exporter-metrics.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/08-node-exporter-metrics.md`
- 前置文档：`07-container-runtime-metrics.md`、`06-kubelet-metrics.md`、`01-monitoring-architecture.md`
- 集群基准：Kubernetes 1.32.13、containerd 2.1.5、node-exporter v1.8.2、Prometheus 2.45、Prometheus Operator、离线内网
- 观测模型：全量采用 **USE（资源饱和度）+ RED（硬件吞吐/错误/延迟）**，覆盖整机底层硬件、内核、文件系统、网络
- 文档范围：node-exporter部署采集配置、CPU/内存/磁盘IO/文件系统/网络/内核指标分层、硬件故障告警、服务器卡顿根因排查、多环境管控策略

## 二、Node Exporter 采集部署规范
### 2.1 端口与抓取参数
1. 默认指标端口：9100 /metrics
2. 全局标准抓取配置
```yaml
interval: 15s
scrape_timeout: 10s
evaluation_interval: 15s
metrics_path: /metrics
scheme: http
```
3. 必启收集器（生产强制开启）
cpu, memory, diskstats, filesystem, netdev, netstat, loadavg, systemd, filefd, time, uname, textfile
4. 禁用收集器（减少无用指标）
arp, bonding, bcache, hwmon, infiniband, ipvs, rapl, selinux（无对应硬件/场景）

### 2.2 DaemonSet 标准部署（精简生产版）
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: kube-monitoring
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: node-exporter
        image: quay.io/prometheus/node-exporter:v1.8.2
        args:
        - --collector.systemd
        - --collector.filefd
        - --collector.textfile.directory=/var/lib/node-exporter
        - --no-collector.arp
        - --no-collector.bcache
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
        - name: rootfs
          mountPath: /rootfs
          readOnly: true
        - name: textfile
          mountPath: /var/lib/node-exporter
      volumes:
      - name: proc
        hostPath: {path: /proc}
      - name: sys
        hostPath: {path: /sys}
      - name: rootfs
        hostPath: {path: /}
      - name: textfile
        hostPath: {path: /var/lib/node-exporter}
```

### 2.3 ServiceMonitor 自动节点发现
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: node-exporter
  namespace: kube-monitoring
spec:
  selector:
    matchLabels:
      app: node-exporter
  endpoints:
  - port: metrics
    interval: 15s
    scrapeTimeout: 10s
    relabelings:
    - action: labelmap
      regex: __meta_kubernetes_node_label_(.+)
```

## 三、指标分层：USE 整机资源饱和度模型
### 3.1 CPU 子系统（利用率/饱和度/负载）
#### 核心利用率指标
1. `node_cpu_seconds_total{mode}`：CPU各模式耗时（idle/user/system/iowait/steal）
```promql
# CPU总使用率（非空闲）
100 - (avg by (node) (irate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)
# IO等待占比（IO瓶颈核心判断）
avg by(node)(irate(node_cpu_seconds_total{mode="iowait"}[1m])) * 100
# 云主机CPU抢占(steal)
avg by(node)(irate(node_cpu_seconds_total{mode="steal"}[1m])) * 100
```
2. `node_load1 / node_load5 / node_load15`：系统负载
判定阈值：load1 > CPU核心数*1.2 → CPU饱和

#### 饱和度&错误指标
1. `node_context_switches_total`：上下文切换速率，数值突增代表线程竞争激烈
2. `node_forks_total`：进程创建频繁，消耗CPU调度资源

### 3.2 内存子系统（水位/交换/缓存/泄漏）
1. `node_memory_MemTotal_bytes / MemFree / MemAvailable / Buffers / Cached / SwapTotal / SwapFree`
```promql
# 可用内存占比
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
# Swap使用率
(node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes) / node_memory_SwapTotal_bytes
# 内存PageIn/PageOut（缺页颠簸）
rate(node_vmstat_pgpgin[1m])
rate(node_vmstat_pgpgout[1m])
```
2. `node_vmstat_oom_kill`：OOM杀死进程计数，持续上涨内存严重不足
3. `node_memory_MemFree_bytes` 持续缓慢下跌 → 存在内核/业务内存泄漏

阈值标准：
- Warning：可用内存 < 20%
- Critical：可用内存 < 10% 或 Swap使用率 > 70%

### 3.3 磁盘 IO 子系统（整机卡顿第一根因）
#### IO 吞吐（RED Rate）
`node_disk_read_bytes_total` / `node_disk_written_bytes_total`
```promql
# 单磁盘读写速率TOP
sum by(node,device)(rate(node_disk_read_bytes_total[1m]))
sum by(node,device)(rate(node_disk_written_bytes_total[1m]))
```

#### IO 饱和度（USE核心）
1. `node_disk_io_time_seconds_total`：磁盘IO耗时占比
```promql
# 磁盘IO饱和度（100%表示磁盘完全打满）
avg by(node,device)(rate(node_disk_io_time_seconds_total[1m]) / rate(node_disk_io_time_weighted_seconds_total[1m]))
```
2. `node_disk_io_now`：当前排队IO请求数，持续>10队列阻塞

#### IO 错误（RED Error）
`node_disk_read_errors_total` / `node_disk_write_errors_total`：磁盘硬件坏块、RAID故障

#### IO 延迟（RED Duration）
`node_disk_read_time_seconds_total` / `node_disk_write_time_seconds_total`
单IO耗时突增代表存储介质性能衰减（机械盘、差SSD、云盘限流）

### 3.4 文件系统分层（分区水位、inode耗尽）
1. 分区使用率
```promql
# 分区剩余空间占比
node_filesystem_free_bytes / node_filesystem_size_bytes
# inode剩余占比
node_filesystem_files_free / node_filesystem_files
```
2. 关键分区区分：
- `/` nodefs 节点系统分区
- `/var/lib/containerd` 容器运行时存储
- `/var/log` 日志分区
- PVC挂载目录（持久化业务存储）

阈值：
- Warning：剩余 < 20%；inode < 20%
- Emergency：剩余 < 5%；inode < 5%（直接无法创建文件）

### 3.5 网络子系统（网卡吞吐、丢包、错误）
#### Rate 吞吐
`node_network_receive_bytes_total` / `node_network_transmit_bytes_total`

#### Error 网络故障
```promql
# 网卡入/出包丢包率
sum by(node,device)(rate(node_network_receive_drop_total[1m]))
sum by(node,device)(rate(node_network_transmit_drop_total[1m]))
# 硬件校验错误
rate(node_network_receive_errs_total[1m])
```
判定：任一网卡丢包持续>0，引发Pod网络超时、服务调用失败

#### 连接饱和度
`node_tcp_connections` 当前TCP连接总数；`node_tcp_timewait` TIME-WAIT连接堆积，端口耗尽

### 3.6 文件句柄 & Systemd 系统状态
1. 文件句柄
```promql
# 全局句柄使用率
node_filefd_allocated / node_filefd_maximum
```
阈值 >80% Warning，>95% Critical（容器/进程无法新建连接）
2. systemd 服务状态
`node_systemd_unit_state{state="failed"}`：节点系统服务崩溃（sshd、containerd、kubelet）

## 四、文本导出扩展指标（TextFile Collector）
用于补充node-exporter原生不支持的自定义硬件/运行时指标：
1. containerd metrics（对接07-container-runtime-metrics.md）
2. 磁盘smart硬件健康状态
3. 服务器负载自定义业务脚本输出
文件目录固定：`/var/lib/node-exporter/*.prom`

## 五、生产统一告警规则（三层分级对齐全局规范）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: node-exporter-rules
  namespace: kube-monitoring
spec:
  groups:
  - name: node.hardware.rules
    interval: 15s
    rules:
    # ===================== Emergency 紧急（7×24短信+企业微信）=====================
    - alert: NodeFilesystemCriticalFull
      expr: node_filesystem_free_bytes / node_filesystem_size_bytes < 0.05
      for: 2m
      labels: {severity: Emergency}
      annotations: {summary: "节点分区磁盘低于5%，无法写入文件"}

    - alert: NodeOOMKillHappening
      expr: rate(node_vmstat_oom_kill[5m]) > 0
      for: 1m
      labels: {severity: Emergency}
      annotations: {summary: "节点持续OOM杀死进程/容器"}

    - alert: DiskHardwareError
      expr: sum by(node,device)(rate(node_disk_read_errors_total[5m]) + rate(node_disk_write_errors_total[5m])) > 0
      for: 1m
      labels: {severity: Emergency}
      annotations: {summary: "磁盘硬件读写错误，存在数据丢失风险"}

    # ===================== Critical 严重（当日必须处理）=====================
    - alert: DiskIOSaturated
      expr: avg by(node,device)(rate(node_disk_io_time_seconds_total[1m])) > 0.9
      for: 3m
      labels: {severity: Critical}
      annotations: {summary: "磁盘IO100%饱和，业务Pod卡顿超时"}

    - alert: NodeSwapHighUsage
      expr: (node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes)/node_memory_SwapTotal_bytes > 0.7
      for: 3m
      labels: {severity: Critical}
      annotations: {summary: "Swap使用率超70%，内存严重不足"}

    - alert: NetworkPacketDrop
      expr: sum by(node,device)(rate(node_network_receive_drop_total[5m]) + rate(node_network_transmit_drop_total[5m])) > 5
      for: 3m
      labels: {severity: Critical}
      annotations: {summary: "网卡持续丢包，微服务调用失败"}

    - alert: FileDescriptorCritical
      expr: node_filefd_allocated / node_filefd_maximum > 0.95
      for: 3m
      labels: {severity: Critical}
      annotations: {summary: "节点文件句柄接近耗尽"}

    # ===================== Warning 预警（工作时段处理）=====================
    - alert: NodeCpuHighWarning
      expr: 100 - avg by(node)(irate(node_cpu_seconds_total{mode="idle"}[1m])*100) > 85
      for: 10m
      labels: {severity: Warning}
      annotations: {summary: "节点CPU使用率超过85%"}

    - alert: NodeMemoryLowWarning
      expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.2
      for: 10m
      labels: {severity: Warning}
      annotations: {summary: "节点可用内存不足20%"}

    - alert: NodeFilesystemWarningFull
      expr: node_filesystem_free_bytes / node_filesystem_size_bytes < 0.2
      for: 10m
      labels: {severity: Warning}
      annotations: {summary: "分区剩余空间不足20%，建议清理日志/镜像"}

    - alert: FileDescriptorWarning
      expr: node_filefd_allocated / node_filefd_maximum > 0.8
      for: 10m
      labels: {severity: Warning}
      annotations: {summary: "文件句柄占用超过80%，存在耗尽风险"}
```

## 六、Grafana 大盘分层视图
1. 节点总览面板
    - 全节点在线状态、CPU/内存/磁盘使用率TOP排行
    - 整机负载、OOM计数、系统失败服务汇总
2. CPU负载面板
    - 各mode占用曲线、iowait/steal占比、上下文切换速率
3. 内存水位面板
    - 可用内存、Swap使用、Page颠簸、OOM事件时序
4. 磁盘IO性能面板
    - 各磁盘读写吞吐、IO饱和度、IO排队长度、硬件错误计数
5. 文件系统面板
    - 所有分区磁盘使用率、inode水位TOP10
6. 网络面板
    - 网卡上下行带宽、丢包/错误计数、TCP连接堆积
7. 系统资源面板
    - 文件句柄、系统失败服务、内核自定义textfile指标

## 七、多环境差异化管控策略
1. DEV开发环境
    - 部署简化DaemonSet，关闭非必要收集器
    - 仅Warning/Critical告警，无短信通知
    - 时序数据保留3天，无长期归档
2. FAT测试环境
    - 标准完整采集配置，开启textfile导出containerd指标
    - 关闭Emergency短信，仅企业微信推送
    - 数据保留7天，用于测试性能压测定位瓶颈
3. UAT预发环境
    - 全套采集+完整告警规则，阈值与生产完全对齐
    - 全等级告警，仅企业微信通知
    - 数据保存30天，模拟硬件故障验证告警链路
4. PROD生产强制约束
    - Thanos远端存储归档指标180天，用于业务卡顿、硬件故障回溯
    - DaemonSet、ServiceMonitor、PrometheusRule全部GitOps托管，禁止临时修改
    - Emergency级别短信+企业微信双通道7×24推送
    - Alertmanager告警抑制：单节点磁盘/内存故障时，抑制该节点kubelet、containerd、Pod衍生告警
    - 定时脚本清理节点容器日志、无用镜像，降低磁盘满告警频次

## 八、故障标准排查链路
### 8.1 node-exporter指标抓取失败
1. 检查DaemonSet Pod是否正常运行、hostPID/hostNetwork权限
2. 验证主机/proc /sys挂载是否只读、权限正常
3. 本地节点curl `localhost:9100/metrics` 验证端口监听
4. ServiceMonitor标签匹配、抓取超时参数是否过小

### 8.2 业务Pod响应缓慢、整机卡顿通用排查流程
1. node-exporter磁盘IO饱和度指标 → IO100%优先处理存储瓶颈
2. 查看CPU iowait占比确认是否磁盘阻塞CPU调度
3. 内存水位+Swap+PageIn/Page颠簸判断内存不足
4. 网卡丢包、TCP TIME-WAIT判断网络瓶颈
5. 文件句柄耗尽、分区inode满判断文件系统瓶颈

### 8.3 磁盘持续高IO故障下钻
1. 定位高IO设备device标签
2. 联动kubelet/containerd指标确认是镜像GC、日志写入、业务PVC读写
3. 清理大日志、扩容磁盘、更换高性能SSD存储介质

### 8.4 节点OOM频繁杀死容器
1. node_memory_MemAvailable持续走低、Swap大量使用
2. 查看业务Pod内存使用（cadvisor容器指标）
3. 调整Pod内存request/limit、扩容节点、优化内存泄漏应用

### 8.5 网卡丢包服务调用超时
1. 区分是入包丢包还是出包丢包
2. 检查网卡硬件错误、交换机端口限速、集群网络插件Cilium/Calico规则限流
3. 调整TCP内核参数（tcp_tw_reuse、端口范围缓解timewait堆积）

## 九、关联文档索引
1. 顶层规范：`01-monitoring-architecture.md` RED/USE观测模型、全局三层告警标准
2. 上层运行时：`06-kubelet-metrics.md`、`07-container-runtime-metrics.md` 容器层指标联动
3. 对象指标：`09-kube-state-metrics.md` K8s资源对象状态指标
4. 故障通用方法论：`03-troubleshooting-methodology.md` 整机性能瓶颈标准排查流程
5. PromQL速查：`10-monitoring-best-practice.md` node-exporter高频查询汇总
6. 集群巡检脚本：`02-cluster-health-check` 节点磁盘/内存/句柄定时检测脚本