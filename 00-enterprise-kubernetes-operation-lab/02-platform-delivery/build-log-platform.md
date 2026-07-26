# build-log-platform.md
# Loki + Promtail 企业级K8s日志采集平台部署手册
## 一、文档定位
本文采用CNCF原生云原生日志方案 **Loki（日志存储查询）+ Promtail（节点日志采集）** 搭建集群统一日志平台；替代传统ELK高内存开销架构，适配容器JSON日志、多租户隔离、日志告警、Grafana联动可视化，完整覆盖部署、采集规则、持久化、权限、运维排障、交付验收。
前置依赖：
build-kubernetes-cluster.md｜集群基础环境就绪
build-monitoring-platform.md｜Prometheus/Grafana监控底座
build-storage-platform.md｜日志持久化StorageClass
validate-cluster-health.md｜集群交付日志平台验收标准
下游关联：build-monitoring-platform.md、06-network-debug.md

## 二、平台整体架构
### 2.1 四层架构组件
1. **采集层：Promtail（DaemonSet）**
   全节点部署，采集容器stdout/stderr日志、宿主机系统日志；自动解析容器元数据（namespace/pod/app/node），打上标签推送Loki。
2. **存储计算层：Loki**
   分为三大子组件，支持高可用分片部署：
   - distributor：接收Promtail推送日志，分发至ingester
   - ingester：日志内存缓存、分块持久化存储
   - querier：日志查询引擎，对接Grafana
3. **持久化层**
   日志块存储：对象存储MinIO/阿里云OSS；索引存储：PVC/对象存储；分离冷热数据。
4. **可视化告警层：Grafana**
   复用监控平台Grafana，内置Loki数据源，日志检索、链路过滤、日志告警联动AlertManager。

### 2.2 Loki vs ELK 核心优势
1. 不存储完整日志全文索引，仅索引标签，内存/磁盘占用远低于Elasticsearch
2. 原生K8s适配，自动识别容器元标签，无需复杂过滤规则
3. 与Prometheus/Grafana统一生态，一套面板同时看指标+日志
4. 轻量，万Pod集群资源开销极低

### 2.3 日志采集覆盖范围
✅ 所有容器标准输出stdout/stderr业务日志
✅ K8s控制平面组件日志（kube-apiserver/etcd/cni）
✅ 宿主机系统日志 /var/log/messages、内核报错
✅ 容器持久化日志文件（sidecar文件日志采集扩展）

## 三、前置环境准备
1. 集群StorageClass就绪，支持动态PVC用于Loki索引持久化
2. 对象存储（MinIO/云OSS）部署完成，用于日志块长期存储
3. Grafana监控平台已部署，Ingress域名可访问
4. 集群所有节点容器日志驱动为json格式（containerd标准配置）
5. 网络放行：Promtail → Loki 3100端口互通

## 四、步骤1：Helm仓库添加
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana
kubectl create ns logging
```

## 五、步骤2：values-loki.yaml 生产高可用完整配置
### 5.1 Loki 服务端配置（单机测试可缩减副本，生产双副本）
```yaml
loki:
  enabled: true
  replicas: 2
  persistence:
    enabled: true
    storageClassName: nfs-sc
    size: 50Gi
  storage:
    bucketNames:
      chunks: "loki-chunk"
      ruler: "loki-ruler"
      admin: "loki-admin"
    type: "s3"
    s3:
      endpoint: "minio.logging.svc.cluster.local:9000"
      bucket: "loki-chunk"
      accessKeyId: "minioadmin"
      secretAccessKey: "Minio@Pass2026"
      insecure: true
  limits:
    max_entries_per_query: 50000 # 单次查询日志行数限制
    retention_period: 7d # 日志全局保留7天
  ingester:
    replicas: 2
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1Gi
  distributor:
    replicas: 2
# 内置日志告警规则组件
ruler:
  enabled: true
  alertmanagerUrl: "http://alertmanager-operated.monitoring.svc.cluster.local:9093"
```

### 5.2 Promtail 采集端配置（全节点DaemonSet）
```yaml
promtail:
  enabled: true
  daemonset:
    enabled: true
  config:
    # 容器日志抓取规则
    snippets:
      pipelineStages:
        - docker: {} # 解析containerd json日志
        - match:
            selector: '{app=~".+"}'
            stages:
              - regex: # 提取日志level、traceId
                  expression: '.*\[(?P<level>\w+)\] (?P<traceId>[0-9a-f]{32}) .*'
              - labels:
                  level: null
                  traceId: null
    scrapeConfigs:
      # 采集容器stdout/stderr
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app
          - source_labels: [__meta_kubernetes_node_name]
            target_label: node
    # 宿主机系统日志采集
    - job_name: node-system
      static_configs:
        - targets:
            - localhost
          labels:
            job: system-log
          __path__: /var/log/*.log
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

### 5.3 Grafana 自动注入Loki数据源
复用monitoring命名空间Grafana，新增数据源配置；若独立Grafana可在chart内开启grafana.enabled。

## 六、步骤3：执行helm安装
```bash
helm install loki-stack grafana/loki-stack \
-n logging \
-f values-loki.yaml
```

## 七、部署完成校验
```bash
# 查看loki、promtail所有Pod就绪
kubectl get pods -n logging
# 查看loki服务端口
kubectl get svc -n logging loki
# 进入promtail验证采集日志无报错
kubectl logs -n logging daemonset/promtail
# 测试推送日志连通性
curl -X POST http://loki.logging.svc:3100/loki/api/v1/push
```

## 八、Grafana 配置与日志检索使用
### 8.1 添加Loki数据源
1. 登录Grafana → 连接数据源 → Loki
2. URL填写：`http://loki.logging.svc.cluster.local:3100`
3. 保存测试连通，无连接报错

### 8.2 常用日志查询语法（LogQL）
1. 查看指定命名空间全部业务日志
```logql
{namespace="biz"}
```
2. 指定应用、ERROR级别错误日志
```logql
{namespace="biz",app="api"} |= "ERROR"
```
3. 过滤5xx接口报错，带traceId追踪整条链路
```logql
{app="gateway"} |= "500" | json | traceId != ""
```

### 8.3 内置日志大盘
导入官方Loki通用面板：
- 集群日志总量趋势、错误日志占比
- 命名空间/应用日志排行
- 日志延迟、采集丢弃计数

## 九、日志告警配置（联动AlertManager）
### 9.1 Loki Ruler告警规则示例
```yaml
groups:
- name: biz-error-alert
  interval: 1m
  rules:
  - alert: AppHighErrorRate
    expr: count_over_time({namespace="biz"} |= "ERROR" [5m]) > 100
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "业务5分钟错误日志超过100条"
      description: "命名空间biz错误日志突增，请排查接口异常"
```
规则自动推送至AlertManager，通过钉钉/企业微信推送告警。

## 十、生产优化配置
### 1. 日志保留周期分层
1. 热数据（对象存储）：7天完整日志，实时检索
2. 长期归档：定时将OSS日志转存冷存储（低成本归档30天+）

### 2. 日志过滤降噪（丢弃无用调试日志）
Promtail pipeline增加drop过滤，过滤INFO调试日志节省存储：
```yaml
- match:
    selector: '{level="INFO"}'
    action: drop
```

### 3. 大日志文件分片、速率限制
防止单个业务疯狂打日志占用存储，配置Promtail限流：
```yaml
limits:
  rate_limit: 10000 # 单Pod每秒最大日志行数
```

### 4. 多租户隔离
通过namespace标签区分租户，Grafana组织权限隔离不同业务日志查看权限。

## 十一、高可用规范
1. Loki distributor/ingester双副本，避免日志接收/缓存单点故障
2. 日志块统一存入对象存储，PVC仅存索引，磁盘损坏不丢失日志
3. Promtail DaemonSet全节点部署，单节点故障不影响其他节点采集
4. AlertManager集群接收日志告警，告警消息不丢失

## 十二、全链路验收测试（纳入集群交付校验）
1. 业务Pod输出ERROR日志，Grafana可实时检索到对应日志
2. 控制平面etcd/kube-apiserver日志正常采集，无缺失
3. 宿主机系统内核报错日志可检索
4. 错误日志达到阈值自动触发钉钉告警
5. 节点重启后Promtail自动重连Loki，日志采集无中断
6. 日志保留7天后自动清理，磁盘空间自动释放

## 十三、高频故障排查
### 故障1：Grafana查询无任何日志
根因：Promtail无法连通Loki、标签匹配错误、容器日志非json格式
排查：kubectl logs promtail查看推送报错；确认容器日志驱动为json

### 故障2：只采集到部分Pod日志，部分Pod日志丢失
根因：Pod命名空间/标签relabel配置缺失；Promtail权限不足读取容器日志
修复：补充relabel_configs映射namespace/app标签

### 故障3：大量日志被丢弃，日志不全
根因：Promtail速率限制过低、Loki存储满、网络推送超时
排查：Promtail日志输出rate limit丢弃日志告警，调大限流参数

### 故障4：日志告警不推送钉钉
根因：loki ruler地址错误、AlertManager不可达、告警表达式不匹配日志规则
排查：查看loki ruler组件日志，验证alertmanagerUrl参数

### 故障5：查询日志超时，返回504
根因：单次查询日志行数过大、存储IO性能差、Loki querier资源不足
修复：调小max_entries_per_query，上调Loki内存limits

## 十四、生产运维落地规范
1. 集群统一日志驱动为containerd json格式，禁止纯文本无结构化日志
2. 生产环境必须对象存储持久化日志块，不依赖本地磁盘PVC长期存储
3. 配置日志降噪规则，过滤大量INFO调试日志，节省存储与查询性能
4. 核心业务开启错误日志告警，监控系统异常行为
5. 定期清理归档超7天热日志，冷存储长期归档留存用于审计
6. 集群交付验收必做日志检索、告警推送双项验证（validate-cluster-health.md）
7. 禁止业务输出超大单行日志，添加Promtail单行长度截断规则

## 十五、关联文档索引
build-kubernetes-cluster.md｜集群节点containerd日志驱动配置
build-monitoring-platform.md｜Grafana、AlertManager告警底座
build-storage-platform.md｜Loki索引PVC持久化配置
validate-cluster-health.md｜日志平台集群交付验收标准
06-network-debug.md｜Promtail与Loki网络连通故障排查
03-network-data-path.md｜容器日志标准输出流转原理