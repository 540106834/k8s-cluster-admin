# Grafana 监控平台生产方案（精简架构版）

## 1. 核心定位与整体架构

**Grafana 只负责展示与告警，不采集、不存储时序数据**，通过数据源查询外部时序/日志/业务数据，实现可视化与告警闭环。
```
Grafana Dashboard

├── 1. 基础设施层 Infrastructure
│
├── 2. Kubernetes平台层
│
├── 3. 应用层 Application
│
├── 4. 中间件层 Middleware
│
├── 5. 数据库层 Database
│
├── 6. 网络层 Network
│
└── 7. 业务指标层 Business
```


### 标准基础架构

```Plain Text
Exporter → Prometheus(存储/采集) → Grafana(查询展示/告警)
```

### 生产高可用架构（含Thanos）

```Plain Text
多K8s集群Prometheus + Thanos Sidecar 
        ↓
对象存储(S3/OSS) + Thanos Query 
        ↓
Grafana 统一查询、展示、告警
```

## 2. 核心组件：DataSource 数据源

Grafana 所有数据均来自外部数据源，无自研存储。

|数据源|核心用途|
|---|---|
|Prometheus|时序指标监控（CPU/内存/网络/资源）|
|Loki/ES|容器/系统日志查询分析|
|InfluxDB|传统时序数据存储查询|
|MySQL|业务维度数据展示|
|CloudWatch|公有云资源监控|

### Prometheus 数据查询链路

```Plain Text
Grafana → PromQL → Prometheus HTTP API → 时序数据库
```

## 3. 生产 Dashboard 分层设计

遵循**集群总览 → 节点详情 → 资源详情**分层设计，覆盖K8s全维度监控。

### 3.1 集群总览 Dashboard

核心展示：集群CPU/内存、节点数、Pod数、网络、APIServer、ETCD状态

集群CPU使用率：

```Plain Text
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

集群内存使用率：

```Plain Text
1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
```

### 3.2 Node 节点监控

核心指标：CPU、内存、磁盘、网络吞吐  
核心指标名：`node_cpu_seconds_total`、`node_memory_*`、`node_filesystem_*`、`node_network_*_bytes_total`

### 3.3 K8s 资源监控

- Deployment：`kube_deployment_status_replicas`
- Pod 状态：`kube_pod_status_phase`
- 容器CPU使用率（按Pod聚合）：

```Plain Text
sum(rate(container_cpu_usage_seconds_total{namespace="prod"}[5m])) by(pod)
```

## 4. Grafana Variable 动态变量

核心作用：**一套Dashboard，多环境动态切换**（命名空间、Pod、节点），无需修改图表。

### 命名空间变量查询

```Plain Text
label_values(kube_namespace_labels, namespace)
```

### 变量生效链路

```Plain Text
下拉切换变量 → 自动替换PromQL标签 → 图表实时刷新对应环境数据
```

## 5. Grafana 告警体系

### 告警架构

```Plain Text
Grafana AlertRule → 定时评估(Evaluation) → ContactPoint → 多渠道通知
```

支持：Webhook、飞书、钉钉、邮件、Slack

### 告警完整流程

```Plain Text
PromQL阈值匹配 → Pending(等待窗口期) → Firing(触发) → 推送通知
```

通用规则范式：

```Plain Text
expr: node_cpu_usage > 80
for: 5m
```

## 6. 与 kube-prometheus-stack 集成

### 组件关系

```Plain Text
Prometheus Operator 统一管理
├─ Prometheus(指标采集)
├─ Alertmanager(告警收敛)
└─ Grafana(可视化面板)
```

### 核心联动机制

- **ServiceMonitor**：自动发现K8s监控目标，无需手动改Prometheus配置
- **PrometheusRule**：声明式统一管理告警规则
- **Dashboard ConfigMap**：Grafana Sidecar 自动加载大盘，禁止手动导入

## 7. Dashboard 自动化交付（生产标准）

通过带专属标签的 ConfigMap 实现大盘自动化部署、更新、同步。

```Plain Text
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-dashboard
  labels:
    grafana_dashboard: "1" # 关键识别标签
```

### 自动加载链路

```Plain Text
ConfigMap(json大盘数据) → Grafana Sidecar 监听 → 自动加载更新
```

## 8. 权限体系（企业生产）

### 认证方式

LDAP / OIDC / OAuth 统一账号登录

### 权限层级模型

```Plain Text
Organization(组织) → Folder(目录) → Dashboard(细粒度权限)
```

### 角色划分

- 开发：Viewer（只读查看）
- 运维：Editor（编辑大盘/规则）
- 管理员：Admin（全量权限）

## 9. 高可用架构（生产必备）

### 单节点（测试）

```Plain Text
Grafana + SQLite(本地文件)
```

### 生产HA架构

```Plain Text
LB负载均衡
├─ Grafana多实例集群
└─ 共享MySQL/PostgreSQL（存储用户/大盘/权限/告警）
```

## 10. 性能优化方案

### 10.1 PromQL 优化

禁止短时间范围计算，避免Prometheus压力过大

❌ 不推荐：`rate(metric[1s])`   
✅ 推荐：`rate(metric[5m])`

### 10.2 Recording Rule 预计算优化

将复杂高频查询预计算存储，Grafana直接读取结果，大幅降低查询压力

```Plain Text
record: node:cpu_usage:avg
expr: avg(rate(node_cpu_seconds_total[5m]))
```

## 11. 大型集群：Grafana + Thanos 架构

解决**多集群监控、指标长期存储、Prometheus单集群瓶颈**问题

```Plain Text
多集群Prometheus + Thanos Sidecar → 远端写入S3/OSS
        ↓
Thanos Query 统一聚合查询
        ↓
Grafana 统一可视化展示与告警
```

### 核心优势

- 多集群监控统一入口

- 指标永久存储（对象存储）

- Prometheus 轻量化、高可用

## 12. 生产完整监控闭环

```Plain Text
Exporter采集指标 
↓ ServiceMonitor自动发现 
↓ Prometheus存储计算 
↓ Grafana可视化展示(PromQL+变量) 
↓ PrometheusRule阈值检测 
↓ Alertmanager告警收敛 
↓ 企业微信/钉钉/Webhook通知
```

## 核心技术栈速览（复盘）

DataSource、Dashboard、Variable、PromQL、RecordingRule、AlertRule、ContactPoint、Sidecar自动加载、ConfigMap部署、LDAP/OIDC权限、kube-prometheus-stack、ServiceMonitor、Thanos多集群架构
