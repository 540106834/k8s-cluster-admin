# docs/04-workload/01-prometheus.md
# kube-prometheus-stack Prometheus 核心组件运维手册
## 文档基础信息
- K8s 集群：v1.32
- Chart 基线：kube-prometheus-stack-65.1.0
- 存储：NFS StorageClass `nfs-sc`
- 管控模式：Git values + PrometheusOperator CRD
- 文档等级：★★★★★ 核心负载文档
- 前置阅读：02-deployment/02-configuration.md、03-storage/01-storage-design.md

## 目录
1. Prometheus Operator 管控架构
2. Prometheus CRD 资源模型（Prometheus/PodMonitor/ServiceMonitor/Rule）
3. HA 高可用部署架构（双副本独立TSDB）
4. 采集全链路配置（抓取、重标记、过滤）
5. TSDB 运行调优参数
6. 资源规格标准（多环境CPU/内存）
7. 安全配置（认证、网络隔离、权限）
8. 运维常用操作（重启、扩容、采集调试）
9. 核心监控指标与故障识别
10. 关联文档索引

---

# 1. Prometheus Operator 管控架构
## 1.1 组件分层
```
PrometheusOperator Deployment（控制器）
├─ 监听集群4类CRD资源：
│  1. Prometheus：定义Prometheus实例规格、存储、副本、全局配置
│  2. ServiceMonitor：基于Service发现目标Pod采集指标
│  3. PodMonitor：直接发现Pod，无需前置Service
│  4. PrometheusRule：告警/预计算规则，热加载不重启
├─ 自动下发资源：StatefulSet、PVC、Service、ConfigMap、Secret
└─ 管控闭环：Git修改values/CRD → helm upgrade → Operator同步更新Prometheus实例
```
## 1.2 Operator 核心能力
1. 全生命周期托管Prometheus/Alertmanager/Grafana；
2. 规则、采集配置热加载，无停机更新；
3. 自动注入服务发现配置，无需手动编写prometheus.yml；
4. 内置RBAC权限，自动授权读取集群Pod/Service/节点元数据。

## 1.3 部署约束
Operator为单副本Deployment，内存需求低（512Mi），无持久化存储；
禁止多Operator重复部署，避免资源冲突。

---

# 2. Prometheus CRD 资源模型
## 2.1 Prometheus CRD（values核心配置段 prometheus.prometheusSpec）
顶层实例定义，控制实例生命周期：副本、存储、留存、抓取全局参数、网络策略、资源限制、安全认证。
核心字段分组：
1. 高可用：replicas、serviceAccountName
2. 存储：storageSpec、retention、retentionSize
3. 抓取全局：scrapeInterval、evaluationInterval、scrapeTimeout
4. 筛选过滤：serviceMonitorSelector、podMonitorNamespaceSelector
5. 数据预处理：writeRelabelConfigs、relabelConfigs
6. 安全：tls、basicAuth、networkPolicy、securityContext

## 2.2 ServiceMonitor（标准业务采集方案）
适配规范：业务部署Service，暴露metrics端口；
匹配规则：
```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelector:
      matchLabels:
        platform: monitor
    serviceMonitorNamespaceSelector:
      matchLabels:
        monitor-enabled: "true"
```
业务Namespace必须打标签 `monitor-enabled: "true"`，ServiceMonitor必须携带 `platform: monitor`。

## 2.3 PodMonitor（无Service直采场景）
适用：DaemonSet、无Service临时Pod、宿主机级exporter；
筛选逻辑与ServiceMonitor完全一致，仅发现目标为Pod。

## 2.4 PrometheusRule 告警/预计算规则
独立CRD，Operator实时监听变更，自动热加载至Prometheus，无需重启实例；
区分两类规则：
1. record：预聚合指标（减少查询计算压力）
2. alert：告警触发规则，推送至Alertmanager

---

# 3. HA 高可用部署架构（生产强制双副本）
## 3.1 架构特点
1. replicas: 2，两个独立StatefulSet Pod，**各自独立PVC/独立TSDB**；
2. 无共享存储，访问模式RWO，杜绝TSDB多写损坏；
3. 双副本全量抓取相同指标，数据完全冗余；
4. 前端Grafana同时对接两个Prometheus Service，实现查询高可用；
5. 告警规则双副本独立评估，Alertmanager自动去重重复告警。

## 3.2 HA 配套配置
```yaml
prometheus:
  prometheusSpec:
    replicas: 2
    # 启用副本间告警重复抑制
    alertmanagerConfigSelector:
      matchLabels:
        platform: monitor
    # 服务发现负载均衡，避免单点抓取压力
    serviceDiscoveryNamespaceTolerations: []
```
## 3.3 故障容限
单副本宕机，另一副本持续采集、评估规则，监控无中断；
宕机副本恢复后自动重新抓取补齐内存热数据，NFS持久化历史数据不丢失。

## 3.4 不支持共享存储HA说明
Prometheus原生不支持多实例同时读写同一TSDB；
如需横向扩展、长期归档，后续扩展Thanos组件。

---

# 4. 采集全链路配置
## 4.1 全局抓取标准参数（生产）
```yaml
prometheus:
  prometheusSpec:
    scrapeInterval: 30s        # 指标抓取周期
    evaluationInterval: 1m      # 规则评估周期
    scrapeTimeout: 10s          # 单次抓取超时阈值
    sampleLimit: 50000          # 单次目标最大采样点数，防Exporter打满Prometheus
    targetLimit: 1000           # 全局最大采集目标数
```

## 4.2 relabel 标签重标记（发现阶段过滤）
作用：服务发现后、抓取前修改/过滤目标，减少无效采集：
```yaml
    relabelConfigs:
      - action: drop
        regex: "kube-system|kube-public"
        sourceLabels: [namespace]
```

## 4.3 writeRelabel 写入过滤（落盘TSDB前）
作用：指标抓取成功后，丢弃无用高频指标，降低存储开销：
```yaml
    writeRelabelConfigs:
      - action: drop
        sourceLabels: [__name__]
        regex: ".*_bucket|.*_sum|.*_count"
```

## 4.4 采集调试手段
1. Prometheus UI → Status → Targets：查看目标UP/DOWN、标签、抓取报错；
2. UI → Status → Configuration：实时查看最终生效prometheus.yml；
3. UI → Status → Rules：验证预计算/告警规则加载状态；
4. 日志查看抓取异常：`kubectl logs -f statefulset/kube-monitor-prometheus -n monitoring`

---

# 5. TSDB 运行调优参数
完整配套配置（03-storage/02-data-retention.md 详细说明）
```yaml
prometheus:
  prometheusSpec:
    retention: "15d"
    retentionSize: "450GB"
    walCompression: true
    blocksCompression: zstd
    tsdb:
      headChunksWriteBuffer: 104857600
      minBlockDuration: 2h
      maxBlockDuration: 2h
```
调优目标：降低NFS刷盘IO压力、提升查询速度、控制磁盘占用。

---

# 6. 多环境资源规格标准
## 6.1 生产环境（双副本HA，上千业务Pod）
```yaml
    resources:
      requests:
        cpu: 2000m
        memory: 4Gi
      limits:
        cpu: 4000m
        memory: 8Gi
```
## 6.2 UAT测试环境（单副本，少量业务）
```yaml
    resources:
      requests:
        cpu: 1000m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
```
## 6.3 Dev开发环境（单副本，仅集群基础监控）
```yaml
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 1000m
        memory: 2Gi
```

## 6.4 资源水位告警阈值
- 内存使用率＞70%：扩容内存；
- CPU持续满负载＞85%：提升CPU限制、拆分高频指标采集。

---

# 7. 安全配置规范
## 7.1 Pod安全上下文（禁用root）
```yaml
    securityContext:
      runAsUser: 65534
      runAsNonRoot: true
      fsGroup: 65534
      allowPrivilegeEscalation: false
```
## 7.2 网络隔离 NetworkPolicy
```yaml
    networkPolicy:
      enabled: true
```
仅允许：
1. Prometheus抓取业务Pod metrics端口；
2. 与Alertmanager通信推送告警；
3. 集群内部Grafana查询访问；
外部命名空间Pod无法直连Prometheus 9090端口。

## 7.3 Web界面基础认证
通过Secret注入账号密码，管控UI访问权限：
```yaml
    basicAuth:
      username:
        name: prom-auth-secret
        key: username
      password:
        name: prom-auth-secret
        key: password
```
## 7.4 TLS加密Web访问
Ingress开启TLS，所有Grafana/Prometheus访问强制HTTPS。

## 7.5 RBAC权限最小化
Operator自动创建ServiceAccount、ClusterRole，仅授予读取集群元数据权限，禁止写权限。

---

# 8. 日常运维标准操作
## 8.1 配置热更新（修改values/采集规则）
```bash
helm upgrade kube-monitor /opt/monitor-chart/kube-prometheus-stack \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml
```
Operator自动滚动更新StatefulSet，采集规则无需重启。

## 8.2 手动重启Prometheus实例
```bash
kubectl rollout restart statefulset kube-monitor-prometheus -n monitoring
```

## 8.3 临时扩容副本（应急负载高）
修改values replicas，helm upgrade下发；扩容新增独立PVC。

## 8.4 采集目标批量排查
```bash
# 查看所有DOWN采集目标
kubectl get servicemonitor -A
# 实时日志过滤抓取失败
kubectl logs -f sts/kube-monitor-prometheus-0 -n monitoring | grep "target down"
```

## 8.5 清理无用时序数据
参考 03-storage/02-data-retention.md 应急清理章节。

---

# 9. 核心监控指标与故障识别
## 9.1 采集健康指标
1. `up`：目标是否正常抓取，0=DOWN，1=UP；
2. `scrape_samples_scraped`：单周期抓取样本总量，突降代表采集故障；
3. `scrape_duration_seconds`：抓取耗时，过高说明Exporter响应慢。

## 9.2 TSDB存储健康指标
1. `prometheus_tsdb_storage_blocks_bytes`：当前磁盘占用；
2. `prometheus_tsdb_blocks_deleted_total`：自动清理数据块计数；
3. `prometheus_tsdb_wal_fsync_duration_seconds`：NFS刷盘延迟，高值代表存储IO瓶颈。

## 9.3 Prometheus运行状态指标
1. `prometheus_targets_sync_failures_total`：服务发现同步失败次数；
2. `prometheus_rule_evaluation_failures_total`：告警/预计算规则执行失败；
3. `prometheus_web_requests_in_flight`：并发查询量，过高导致OOM。

## 9.4 典型故障速查
1. Target全部DOWN → 网络策略拦截/metrics端口未暴露；
2. TSDB持续删块 → 磁盘容量达到retentionSize上限；
3. Rule执行失败 → PrometheusRule语法错误；
4. Pod OOM崩溃 → 内存资源限制不足、查询并发过高。

---

# 10. 关联文档索引
1. Chart values完整配置：02-deployment/02-configuration.md
2. 存储PVC与NFS架构：03-storage/01-storage-design.md
3. TSDB数据留存清理策略：03-storage/02-data-retention.md
4. 告警组件Alertmanager：04-workload/02-alertmanager.md
5. 可视化Grafana：04-workload/03-grafana.md
6. 采集规则ServiceMonitor/PodMonitor：05-prometheus-operator/01-servicemonitor.md
7. 告警规则PrometheusRule：05-prometheus-operator/03-prometheusrule.md
8. 监控故障排查手册：09-troubleshooting/02-prometheus-error.md