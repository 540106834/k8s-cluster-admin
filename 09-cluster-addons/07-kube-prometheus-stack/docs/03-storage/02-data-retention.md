# docs/03-storage/02-data-retention.md
# Prometheus TSDB 数据留存周期规划与清理策略
## 文档基础信息
- K8s：v1.32
- Chart：kube-prometheus-stack-65.1.0
- 存储底座：NFS `nfs-sc`
- 管控模式：Git values + Helm 下发
- 文档等级：★★★★☆ 存储运维核心文档
- 前置阅读：01-storage-design.md、02-deployment/02-configuration.md

## 目录
1. 数据留存双约束机制（时间上限 + 容量上限）
2. 多环境标准留存参数模板（Prod/UAT/Dev）
3. TSDB 数据分层压缩与生命周期流转
4. 不同指标类型差异化留存方案
5. 动态调优操作流程（不重启Prometheus）
6. 容量耗尽应急清理手段
7. 留存相关监控告警规则
8. 长期归档扩展方案（Thanos 远端存储）
9. 关联文档索引

---

# 1. 数据留存双约束机制（强制双阈值同时生效）
Prometheus TSDB 同时启用**时间保留**、**容量保留**两套清理逻辑，任意一条触发即自动删除老旧数据，双重防止磁盘打满：
1. **retention（时间阈值）**：按时间窗口删除超过周期的时序块；
2. **retentionSize（容量硬上限）**：TSDB总数据量达到设定值，优先删除最老数据块，不受时间周期限制；

执行优先级：容量阈值 > 时间阈值。磁盘空间紧张时，会提前裁剪数据，保证Prometheus持续写入。

## 1.1 核心参数说明（values 配置段）
```yaml
prometheus:
  prometheusSpec:
    # 时间维度保留周期
    retention: "15d"
    # 磁盘容量硬上限
    retentionSize: "450GB"
```
- retention 支持单位：d(天)/h(小时)/m(分钟)；
- retentionSize 支持单位：GB/TB；
- 两个参数必须成对配置，禁止只配置单一项。

## 1.2 清理执行逻辑
1. TSDB 每2小时生成一个Block数据块；
2. Prometheus后台每15分钟执行一轮回收检查；
3. 先判断总存储是否超过 retentionSize：超限则从最早Block开始删除；
4. 容量未超限，则删除创建时间超过 retention 的Block；
5. WAL预写日志不受retention控制，仅内存+临时落盘，重启失效。

---

# 2. 多环境标准留存参数模板
## 2.1 生产环境 Prod（标准配置）
业务全量指标、节点/容器/中间件持续采集，PVC单副本500Gi：
```yaml
retention: "15d"
retentionSize: "450GB"
```
- 可留存15天完整高精度原始指标；
- 磁盘占用逼近450GB时自动裁剪，最多保留约13~14天数据。

## 2.2 测试环境 UAT
业务流量低、采样量少，PVC单副本200Gi：
```yaml
retention: "7d"
retentionSize: "180GB"
```

## 2.3 开发环境 Dev
仅基础集群监控，关闭业务自定义Exporter：
```yaml
retention: "3d"
retentionSize: "50GB"
```

## 2.4 高频采集特殊业务（10s抓取间隔）
接口/压测高频指标，存储压力翻倍，同步缩短留存：
```yaml
retention: "7d"
retentionSize: "400GB"
```

---

# 3. TSDB 数据分层压缩与生命周期流转
## 3.1 四层数据生命周期
1. **Head块（热数据，0~2h）**
   当前未关闭的2小时窗口，全精度原始采样，内存+磁盘双缓存，查询速度最快，不可删除；
2. **Level 0 块（2h~2d）**
   关闭后的原始数据块，无压缩，采样粒度30s；
3. **Level 1 压缩块（2d~7d）**
   自动聚合压缩，采样点合并，体积缩减40%~60%；
4. **Level 2 长期压缩块（7d+）**
   高压缩zstd算法，粒度粗，磁盘占用极低，超过retention则清理。

## 3.2 压缩开关配置（默认开启）
```yaml
prometheus:
  prometheusSpec:
    tsdb:
      walCompression: true
      blocksCompression: zstd
```
压缩可大幅降低NFS磁盘占用，同等容量下延长数据留存时长。

---

# 4. 不同指标类型差异化留存方案
## 4.1 全量长期保留（15天）
- 节点资源：CPU/内存/磁盘/网络；
- K8s元数据：Pod/Deployment/Namespace状态；
- 中间件基础监控：MySQL/Redis/消息队列基础指标。

## 4.2 短期高频指标（7天）
- 业务QPS、延迟、错误率、接口耗时分布；
- 容器单Pod高频CPU/内存瞬时峰值；
特点：采样量大，数据膨胀快，缩短留存控制磁盘。

## 4.3 瞬时事件指标（3天）
- 容器OOM、Pod重启、临时错误日志计数；
- 压测、临时批量任务指标；
无需长期回溯，降低存储开销。

### 差异化实现方案
不拆分多Prometheus，使用**指标丢弃规则**，写入阶段过滤无用高频指标：
```yaml
prometheus:
  prometheusSpec:
    remoteWrite:
      # 无Thanos时关闭
      enabled: false
    # 写入前丢弃低频无价值指标，减少存储压力
    writeRelabelConfigs:
      - action: drop
        regex: 'http_request_duration_seconds_bucket'
        sourceLabels: [__name__]
```

---

# 5. 动态调优操作流程（无需重启Prometheus）
## 5.1 修改Git values参数
修改对应环境values-prod.yaml，调整retention/retentionSize：
```yaml
# 示例：磁盘紧张，缩短留存至10天，容量上限350GB
retention: "10d"
retentionSize: "350GB"
```

## 5.2 下发配置热更新
prometheus-operator支持热加载TSDB参数，滚动更新Pod即可生效，无需停机：
```bash
helm upgrade kube-monitor /opt/monitor-chart/kube-prometheus-stack \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml
```

## 5.3 验证生效
进入Prometheus UI → Status → Command-line flags，查看 `storage.retention`、`storage.retention.size` 已更新。

## 5.4 观察数据裁剪进度
监控指标：
```promql
# 已删除的数据块数量
prometheus_tsdb_blocks_deleted_total
# 当前磁盘占用
prometheus_tsdb_storage_blocks_bytes
```

---

# 6. 容量耗尽应急清理手段
## 6.1 临时缩短留存（优先推荐，无损操作）
临时调小retention，触发批量旧数据清理，磁盘释放后再恢复正常值。

## 6.2 临时扩容PVC（中长期方案）
参考 01-storage-design.md 7章节 存储扩容流程。

## 6.3 临时丢弃高频指标（快速减负）
新增writeRelabel丢弃bucket直方图类大体积指标，减少新增写入压力。

## 6.4 手动清理极端场景（谨慎操作，有数据丢失）
1. 停止Prometheus StatefulSet：`kubectl scale statefulset kube-monitor-prometheus -n monitoring --replicas=0`
2. NFS服务端手动删除老旧block目录；
3. 重启Prometheus副本。

> 风险提示：手动删除Block会导致历史指标断层，仅磁盘100%卡死时使用。

---

# 7. 留存相关监控告警规则
内置PrometheusRule监控存储与数据裁剪状态，阈值可自定义：
```yaml
groups:
- name: tsdb-retention-alert
  rules:
  # PVC磁盘使用率80%预警
  - alert: PrometheusStorageHigh
    expr: sum(kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"kube-monitor-prometheus.*"}) / sum(kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~"kube-monitor-prometheus.*"}) > 0.8
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Prometheus TSDB磁盘使用率超过80%"

  # 磁盘90%高危，紧急扩容
  - alert: PrometheusStorageCritical
    expr: sum(kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"kube-monitor-prometheus.*"}) / sum(kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~"kube-monitor-prometheus.*"}) > 0.9
    for: 5m
    labels:
      severity: critical

  # TSDB持续大量删除数据，说明容量上限频繁触发
  - alert: PrometheusDataPruningActive
    expr: increase(prometheus_tsdb_blocks_deleted_total[1h]) > 10
    for: 15m
    labels:
      severity: warning
```

---

# 8. 长期归档扩展方案（Thanos）
当前单Prometheus仅短期15天留存，如需**数月/年长期指标存储**，扩展Thanos组件：
1. Prometheus开启remoteWrite远端写入对象存储；
2. Thanos Store网关统一查询短期NFS数据 + 长期归档对象存储；
3. 分层留存：本地NFS保留15天高精度数据，对象存储保留1年聚合粗粒度数据；
4. 本章节仅覆盖单Prometheus本地TSDB策略，Thanos独立扩展文档。

## Thanos配套留存分层逻辑
- 本地Prometheus：15天原始高精度；
- Thanos对象存储：1年聚合5分钟粒度指标。

---

# 9. 关联文档索引
1. 存储PVC规格、NFS架构：01-storage-design.md
2. values完整存储配置：02-deployment/02-configuration.md
3. Helm升级存储备份流程：02-deployment/03-upgrade.md
4. PVC磁盘故障排查：09-troubleshooting/03-pvc-error.md
5. 监控告警规则编写规范：05-prometheus-operator/03-prometheusrule.md
6. 平台资源容量规划：10-best-practices/01-resource-planning.md