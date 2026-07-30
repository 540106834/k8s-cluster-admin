# 01-cluster-monitoring/10-monitoring-best-practice.md
## 一、文档基础信息
- 归属路径：`07-monitoring-and-troubleshooting/01-cluster-monitoring/10-monitoring-best-practice.md`
- 前置文档：01~09 全监控模块文档（架构、节点、容器运行时、kubelet、kube-state）
- 集群基准：K8s 1.32.13、Prometheus 2.45、Thanos、Prometheus Operator、Alertmanager、Grafana
- 定位：集群监控**生产级标准化规范、PromQL最佳实践、存储优化、告警治理、GitOps交付、排错通用模板**
- 核心目标：降低指标基数、减少无用告警、统一查询范式、控制存储成本、标准化可观测交付

# 二、Prometheus & Thanos 存储性能最佳实践
## 2.1 全局抓取标准化配置（统一规范）
全局抓取三参数全集群统一，所有 ServiceMonitor 严格遵守：
```yaml
interval: 15s
scrape_timeout: 10s
evaluation_interval: 15s
```
特殊组件例外：
1. kube-state-metrics：interval=30s（资源状态变化慢，减少API压力）
2. CronJob/批任务自定义exporter：interval=60s
3. 仓库/日志慢导出组件：scrape_timeout=15s

### 抓取优化规则（降基数核心）
1. relabel 前置过滤无用指标，不在服务端过滤
2. 丢弃高基数动态标签（pod_ip、container_id、随机traceid）
3. textfile 导出指标严格控制单行数量，禁止百万级指标输出
4. 禁用无用收集器：node-exporter bcache/rapl/selinux、containerd无关snapshot指标
5. 统一标签规范：固定 `cluster、env、namespace、service、node` 五维基础标签，禁止自定义随机标签

## 2.2 存储分层留存（Thanos 标准分层）
### 分层保留周期（生产强制）
1. 原始块（Prometheus本地磁盘）：2d，压缩存储，实时查询
2. 短期对象存储（S3/MinIO）：30d，5m降采样（avg/max/sum）
3. 长期归档对象存储：180d，15m降采样，用于容量规划、年度复盘
### 降采样规则
- 5m：CPU/内存/磁盘IO/网络吞吐高频性能指标
- 15m：kube-state资源状态、集群配额、容量统计指标
### 磁盘存储优化
1. Prometheus数据目录独立高速SSD，禁止机械盘/共享存储
2. 开启wal压缩、块压缩，`storage.tsdb.retention.size` 限制本地磁盘上限
3. 分片Prometheus：业务集群拆分Prometheus实例，单实例指标基数≤150万

## 2.3 高基数指标治理（线上最常见性能故障）
### 高基数黑名单（直接过滤）
1. 带Pod IP、容器ID、请求路径、用户ID标签的业务埋点
2. kube_pod_labels/kube_secret_labels/kube_configmap_labels（海量自定义标签）
3. 瞬时唯一Trace、请求ID、随机生成标识
### 治理手段
1. ServiceMonitor `metricRelabelings` 丢弃高基数标签
```yaml
metricRelabelings:
- action: labeldrop
  regex: pod_ip|container_id|request_path|trace_id
```
2. 业务埋点规范：路径做聚合（/api/* 而非完整URL）
3. 拆分业务exporter，微服务独立采集，避免单实例千万指标

# 三、PromQL 通用最佳实践（统一查询范式）
## 3.1 基础查询规范
1. 优先使用 `irate()` 瞬时速率（CPU、IO、网络等瞬时性能指标）
2. 批量总量使用 `rate()`（错误计数、流量总量统计）
3. 禁止无聚合裸指标查询，必须搭配 `sum by(node/namespace/service)` 聚合
4. 时间窗口统一：性能指标 `[1m]`，状态计数 `[5m]`
### 正反示例
```promql
# 错误：无聚合，返回数万条时序
node_cpu_seconds_total{mode="idle"}

# 正确：按节点聚合
100 - avg by(node)(irate(node_cpu_seconds_total{mode="idle"}[1m]) * 100)
```

## 3.2 集群九大高频标准查询模板
### 1）节点资源（node-exporter）
```promql
# CPU使用率
100 - avg by(node)(irate(node_cpu_seconds_total{mode="idle"}[1m]) * 100)
# IO等待占比
avg by(node)(irate(node_cpu_seconds_total{mode="iowait"}[1m]) * 100)
# 分区剩余空间占比
node_filesystem_free_bytes / node_filesystem_size_bytes
# OOM触发速率
rate(node_vmstat_oom_kill[5m])
# 磁盘IO饱和度
avg by(node,device)(rate(node_disk_io_time_seconds_total[1m]))
```

### 2）容器运行时 containerd
```promql
# CRI错误调用占比
sum by(node)(rate(containerd_grpc_server_handled_total{code!="OK"}[5m])) 
/ sum by(node)(rate(containerd_grpc_server_handled_total[5m]))
# GC释放磁盘容量
sum by(node)(increase(containerd_gc_reclaimed_bytes_total[1h]))
```

### 3）kubelet & Pod运行时
```promql
# Pod OOM容器计数
sum by(namespace,pod)(kube_pod_container_status_terminated_reason{reason="OOMKilled"})
# Pending阻塞Pod
sum by(namespace,pod)(kube_pod_status_phase{phase="Pending"})
# 镜像拉取失败
sum by(namespace,pod)(kube_pod_container_status_waiting_reason{reason="ErrImagePull"})
```

### 4）工作负载可用性
```promql
# Deployment副本缺失率
(kube_deployment_spec_replicas - kube_deployment_status_replicas_ready) / kube_deployment_spec_replicas
# DaemonSet缺失Pod数量
kube_daemonset_status_number_unavailable
# CronJob上次执行失败
kube_cronjob_status_last_successful_schedule_time < kube_cronjob_status_last_schedule_time
```

### 5）存储PV/PVC
```promql
# 未绑定PVC
kube_persistentvolumeclaim_status_phase{phase="Pending"}
# 丢失PVC
kube_persistentvolumeclaim_status_phase{phase="Lost"}
```

### 6）集群容量规划
```promql
# 集群总可分配CPU
sum(kube_node_status_allocatable_cpu_cores)
# 集群已申请CPU总量
sum(kube_pod_container_resource_requests_cpu_cores)
# CPU分配率
sum(kube_pod_container_resource_requests_cpu_cores) / sum(kube_node_status_allocatable_cpu_cores)
# Namespace CPU配额使用率
kube_resourcequota_used_cpu_cores / kube_resourcequota_hard_cpu_cores
```

### 7）网络故障
```promql
# 网卡入包丢包速率
sum by(node,device)(rate(node_network_receive_drop_total[5m]))
# TCP连接总数
node_tcp_connections
```

### 8）节点状态告警
```promql
# 未就绪节点
kube_node_status_condition{condition="Ready",status="false"}
# 封锁不可调度节点
kube_node_spec_unschedulable
```

### 9）文件句柄耗尽风险
```promql
node_filefd_allocated / node_filefd_maximum
```

## 3.3 查询性能避坑规则
1. 禁止大范围 `{__name__=~".+"}` 模糊匹配，精准指定指标名
2. 禁止大时间范围无聚合查询（如 `[1d]` 裸指标）
3. 多指标联合查询优先 `*_join` 标签关联，避免笛卡尔积
4. Grafana面板减少瞬时多查询，拆分多面板、开启缓存
5. 告警规则避免复杂子查询、多层聚合嵌套

# 四、告警治理最佳实践（减少90%无效告警）
## 4.1 三级告警标准（全局统一分级，所有Rule对齐）
1. **Emergency 紧急**：业务中断、数据丢失、集群瘫痪
   - 通知通道：短信 + 企业微信/钉钉 双通道 7×24
   - 持续时间阈值：1~2min（快速触发）
   - 示例：节点失联、PVC丢失、大规模Pod OOM、磁盘硬件错误
2. **Critical 严重**：业务容量不足、服务不可用、存储阻塞
   - 通知通道：企业微信/钉钉，无短信
   - 持续阈值：3~5min（过滤瞬时抖动）
   - 示例：副本缺失、镜像拉取失败、PVC未绑定、Swap高占用
3. **Warning 预警**：资源水位偏高、潜在风险，工作时段处理
   - 通知通道：企业微信低优先级分组
   - 持续阈值：10min（过滤瞬时波动）
   - 示例：CPU/内存85%+、磁盘剩余20%、HPA达到最大副本

## 4.2 Alertmanager 抑制规则（核心降噪手段）
### 通用抑制模板（所有集群统一配置）
1. 节点故障抑制：节点NotReady告警，抑制该节点所有Pod、containerd、kubelet衍生告警
2. 存储故障抑制：磁盘100%饱和，抑制该分区所有Pod写入异常告警
3. Namespace配额抑制：配额耗尽，抑制该命名空间Pending Pod告警
4. 集群全局故障抑制：Prometheus失联，抑制全部子组件告警
### 分组规则
按 `cluster、namespace、alertname` 分组，同类型告警合并推送，避免刷屏

## 4.3 告警降噪通用策略
1. 统一 `for` 延时阈值，过滤瞬时抖动（磁盘瞬时IO高峰、临时Pod重建）
2. 标签去重：相同namespace+service告警合并
3. 静音窗口：版本发布、凌晨批任务时段临时屏蔽低优先级Warning告警
4. 告警生命周期管理：定期清理长期未处理告警，优化阈值
5. 屏蔽测试环境紧急短信，仅预发/生产开启Emergency短信通道

## 4.4 告警注释标准化（统一annotations模板）
每条告警强制包含4个字段，方便排错：
```yaml
annotations:
  summary: "一句话故障描述"
  description: "详细现象+影响范围"
  promql: "触发告警完整PromQL语句"
  dashboard: "对应Grafana大盘链接"
```

# 五、组件部署 & GitOps 交付规范
## 5.1 全监控组件统一GitOps目录树
```
monitoring/
├── base/                # 基础通用资源
│   ├── prometheus/      # Prometheus CR、存储配置
│   ├── thanos/          # 存储网关、接收器
│   ├── alertmanager/    # 抑制、路由、通知模板
│   ├── grafana/         # 数据源、大盘JSON
│   └── rbac/            # 全组件ServiceAccount权限
├── exporters/           # 采集组件DaemonSet/Deployment
│   ├── node-exporter/
│   ├── containerd-exporter/
│   ├── kube-state-metrics/
│   └── kubelet-servicemonitor.yaml
├── rules/               # 分层告警规则（对应01~09文档）
│   ├── node-rules.yaml
│   ├── runtime-rules.yaml
│   ├── kube-state-rules.yaml
│   └── global-resource-rules.yaml
├── servicemonitors/     # 统一抓取配置
└── overlays/            # 环境差异化覆盖(dev/fat/uat/prod)
```
## 5.2 环境差异化管控规范
1. DEV：缩短存储留存、关闭短信告警、降低抓取精度
2. FAT：完整采集，关闭Emergency短信，短期数据留存7天
3. UAT：与生产规则、阈值完全对齐，验证告警链路
4. PROD：完整Thanos归档、双通道紧急告警、全量采集、180天长期存储
## 5.3 交付流水线约束
1. 所有CRD（Prometheus、ServiceMonitor、PrometheusRule）禁止手动kubectl apply
2. ArgoCD统一同步监控仓库，配置变更需PR审核
3. Grafana大盘JSON随代码仓库统一版本管理，禁止页面手动修改保存

# 六、Grafana 可视化标准化规范
## 6.1 大盘分层设计（统一结构）
1. 00-集群总览：全节点资源、异常资源汇总、告警看板
2. 01-节点硬件：CPU/内存/磁盘IO/文件系统/网络硬件指标
3. 02-容器运行时：containerd CRI、shim、GC镜像存储
4. 03-Pod工作负载：Pod状态、OOM、副本、滚动更新视图
5. 04-存储资源：PV/PVC水位、绑定状态、磁盘容量规划
6. 05-批处理任务：CronJob执行成功率、漏跑统计
7. 06-容量规划：集群CPU/内存/存储分配率、Namespace配额TOP排行
## 6.2 面板通用规范
1. 统一单位：CPU核、GB、MB/s、百分比、秒
2. 阈值配色统一：绿色正常，黄色Warning，红色Critical
3. 所有面板固定时间范围快捷选项：5m/1h/6h/24h/7d
4. 每个异常面板内置对应告警PromQL与故障排查指引
5. 禁用无限多图例，TOP10聚合展示，防止图例溢出

# 七、故障排查通用流程（监控视角）
## 7.1 监控组件自身故障排查链路
1. Prometheus无指标：检查ServiceMonitor标签、抓取超时、目标Pod运行状态、网络连通性
2. 指标缺失权限：kube-state-metrics RBAC集群只读权限缺失
3. 查询缓慢高基数：定位高基数标签、优化metricRelabel过滤、拆分实例
4. Thanos查询超时：降采样配置错误、对象存储带宽不足、块压缩失效
5. 告警不触发：evaluation_interval、for延时、PromQL语法错误、规则未加载

## 7.2 业务卡顿通用下钻流程（监控分层定位）
1. Grafana集群总览 → 判断是节点硬件/容器/存储/集群资源问题
2. 硬件瓶颈：node-exporter磁盘IO饱和 > CPU iowait > 内存Swap > 网卡丢包
3. 容器运行时瓶颈：containerd CRI延迟、GC阻塞、shim崩溃
4. K8s资源瓶颈：Pod Pending资源不足、副本缺失、PVC绑定失败、HPA上限
5. 容量瓶颈：Namespace配额耗尽、集群总资源分配率超过90%

# 八、安全规范
1. kube-state-metrics 禁用secret/configmap标签采集，防止配置泄露
2. Prometheus/Alertmanager/Grafana开启基础认证，禁止匿名访问
3. Exporter仅内网监听，禁止暴露公网，网络策略限制监控端口访问
4. 监控ServiceAccount最小权限原则，仅授予读取指标所需API权限
5. 日志中屏蔽敏感指标标签（账号、密钥、业务隐私字段）

# 九、定期巡检运维规范
## 9.1 每日自动化巡检脚本（配套02-cluster-health-check）
1. 高基数指标检测，输出TOP20高基数时序
2. 磁盘使用率、OOM、未就绪节点、异常PVC统计
3. Prometheus目标抓取失败数量统计
## 9.2 周度监控优化
1. 清理无效告警、调整不合理阈值
2. 大盘无用面板删除，优化慢查询
3. 检查Thanos存储块压缩、降采样有效性
## 9.3 月度容量规划
基于180天归档指标分析集群资源增长趋势，提前扩容节点/存储