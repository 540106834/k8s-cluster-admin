# Prometheus 监控系统核心技术总结

## 1. Prometheus 基础架构

Prometheus 是一款**开源时序数据库 + 监控系统**，核心特点：

- **Pull 模型（主动拉取）**

- **多维数据模型**

- **PromQL 专属查询语言**

- **原生 Service Discovery 服务发现**

- **独立 Alertmanager 告警管理**

整体架构流转逻辑：

```Plain Text
Exporter
    |
    | HTTP /metrics 接口上报指标
    |
    v
Prometheus Server
    |
    +--> TSDB 时序数据库（数据存储）
    |
    +--> PromQL 实时数据查询
    |
    +--> Rule 规则计算（告警/预计算）
              |
              v
        Alertmanager 告警组件
              |
        邮件/钉钉/企业微信/Slack 通知

Grafana（可视化面板）
    |
    v
调用 Prometheus Query API 获取数据展示
```

## 2. Prometheus 核心组件

### Prometheus Server

#### 2.1 Retrieval 采集模块

核心职责是主动抓取各监控目标的指标数据，是数据采集的核心入口。

```Plain Text
target（监控目标）
  |
  | scrape 定时抓取
  |
Prometheus 服务端
```

默认采集配置：抓取间隔 15s，通过 HTTP 协议请求目标 /metrics 接口获取指标，示例：`GET http://node-exporter:9100/metrics`

#### 2.2 TSDB 时序数据库

Prometheus 内置的专属时序数据库，专门用于存储监控时序数据，数据结构轻量化、读写性能优异。

标准数据结构：`metric_name + labels + timestamp + value`

数据示例：

```Plain Text
node_cpu_seconds_total{
 cpu="0",
 mode="idle"
}
=
123456
```

#### 2.3 核心概念：Time Series 时间序列

一组**唯一标签组合**对应一条独立时间序列，标签组合不同，即为不同时序数据。

示例（两条独立时间序列）：

```Plain Text
# 时序1
http_requests_total{
 method="GET",
 status="200"
}

# 时序2
http_requests_total{
 method="POST",
 status="200"
}
```

## 3. Exporter 指标采集组件

Exporter 核心作用是将各类非 Prometheus 格式的原生监控数据，转换为 Prometheus 可识别的标准 metrics 格式，是异构组件监控的核心适配层。

### 3.1 Node Exporter

用于监控 Linux 服务器整机指标，覆盖硬件与系统核心资源，监控范围包含：CPU、内存、磁盘、网络、文件系统，默认指标接口：`http://node:9100/metrics`

### 3.2 常用 Exporter 汇总

|Exporter 组件|监控用途|
|---|---|
|node-exporter|服务器主机资源监控|
|mysqld-exporter|MySQL 数据库监控|
|redis-exporter|Redis 缓存监控|
|blackbox-exporter|网络链路、端口、接口探测监控|
|kube-state-metrics|K8s 集群资源状态监控|

## 4. Kubernetes 环境 Prometheus 架构

生产环境主流采用 **kube-prometheus-stack** 一站式监控套件，集成所有核心监控组件，开箱即用。

### 4.1 套件核心组成

```Plain Text
Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics + Prometheus Operator
```

### 4.2 集群监控架构流转

```Plain Text
K8s API Server
                 |
                 |（同步集群资源数据）
       kube-state-metrics（采集集群资源状态）
                 |
Node 节点
 |
 +-- node-exporter（采集主机资源指标）

Pod 业务容器
 |
 +-- 容器 /metrics 接口（业务指标）


          Prometheus（统一抓取所有指标）
               |
               |（PromQL 数据分析）
            Grafana（可视化展示）
```

## 5. Prometheus Operator 核心能力

K8s 环境下的核心管控组件，替代传统手动修改 `prometheus.yml` 的方式，通过 CRD 自定义资源实现监控配置的声明式、自动化管理，适配集群动态扩缩容场景。

可通过 `kubectl get crd` 查看所有监控自定义资源。

### 5.1 Prometheus CRD

用于定义 Prometheus 服务实例的部署、运行、采集规则等核心配置。

```Plain Text
kind: Prometheus
```

### 5.2 ServiceMonitor

核心作用：声明需要监控的 K8s Service 资源，告知 Prometheus 抓取目标，实现监控配置自动化更新。

```Plain Text
kind: ServiceMonitor
```

#### 配置生效流程

```Plain Text
Service 资源
 |
 |（匹配标签规则）
ServiceMonitor 规则
 |
 |
Prometheus Operator（自动解析）
 |
 |
自动生成 prometheus.yml 采集配置
 |
 |
Prometheus 执行指标采集
```

### 5.3 PodMonitor

用于直接监控 K8s Pod 资源，适配无 Service 暴露的 Pod 监控场景。

```Plain Text
kind: PodMonitor
```

### 5.4 ServiceMonitor 与 PodMonitor 区别

|资源类型|监控发现对象|
|---|---|
|ServiceMonitor|K8s Service 资源|
|PodMonitor|K8s Pod 资源|

### 5.5 PrometheusRule

用于自定义监控告警规则、预计算规则，支持基于 PromQL 配置阈值触发告警。

示例（节点 CPU 使用率过高规则）：

```Plain Text
expr: node_cpu_usage > 90
```

## 6. PromQL 核心查询语法

### 6.1 节点 CPU 使用率查询

```Plain Text
100 -
(
avg by(instance)
(rate(node_cpu_seconds_total{
mode="idle"
}[5m]))
*100
)
```

### 6.2 节点内存使用率查询

```Plain Text
(
node_memory_MemTotal_bytes
-
node_memory_MemAvailable_bytes
)
/node_memory_MemTotal_bytes
*100
```

### 6.3 核心函数用法

#### rate() 速率计算

用于计算指标在指定时间区间内的**平均增长速率**，适配计数器类型指标。

```Plain Text
rate(http_requests_total[5m]) # 过去5分钟请求平均速率
```

#### increase() 增量计算

用于计算指标在指定时间区间内的**总增长数值**。

```Plain Text
increase(http_requests_total[1h]) # 过去1小时请求总增量
```

#### sum by 聚合分组

按指定标签维度聚合统计指标数据，实现多维度汇总查询。

```Plain Text
sum by(namespace)
(
container_cpu_usage_seconds_total
) # 按命名空间汇总所有容器CPU使用量
```

## 7. Prometheus 告警全流程

### 7.1 完整告警链路

```Plain Text
Prometheus 服务端
     |
     |（匹配 PrometheusRule 规则）
触发告警指标
     |
     |
Alertmanager 告警处理组件
     |
     |（路由、分组、去重、静默处理）
告警接收器 Receiver
     |
     |
钉钉/邮件/微信/Slack/电话通知
```

### 7.2 Alertmanager 核心功能

- **分组 Grouping**：将同类型、同故障源的多条告警合并推送，避免告警风暴（如批量 Pod 异常合并为节点异常告警）

- **去重 Deduplication**：重复触发的相同告警，仅推送一次

- **静默 Silence**：维护、升级场景下，临时屏蔽指定告警，避免无效通知

- **路由 Route**：基于告警级别、标签分类推送不同渠道（严重级别推电话、警告级别推邮件）

## 8. Prometheus 存储方案

### 8.1 默认本地 TSDB

默认数据存储路径：`/prometheus`，为内置轻量时序数据库。

优势：高性能、部署简单、读写高效；劣势：单节点部署、存储容量有限、无法实现超长期数据留存。

### 8.2 生产长期存储方案

#### Thanos（主流方案）

```Plain Text
Prometheus
     |
     |
Thanos Sidecar（边车组件）
     |
     |
对象存储（S3/MinIO）
```

解决痛点：实现监控数据长期持久化存储、支持多集群数据统一查询、保障服务高可用。

#### VictoriaMetrics

高性能时序存储替代方案，存储压缩率更高、查询速度更快，适配大规模监控集群。

## 9. Prometheus 高可用方案

### 9.1 双节点高可用部署

```Plain Text
Prometheus-A（主节点）
Prometheus-B（备节点）
        |
        |（双节点同时采集数据）
   Alertmanager（统一处理告警，去重冗余数据）
```

双节点部署会产生重复指标数据，生产通过 Thanos、Cortex、VictoriaMetrics 实现数据去重与统一聚合。

## 10. Kubernetes 核心监控对象

### 10.1 Node 节点层监控

监控指标：CPU、内存、磁盘、网络、负载、文件系统；数据来源：**node-exporter**

### 10.2 Pod 容器层监控

监控指标：CPU、内存、容器重启次数、OOM 异常、网络流量；数据来源：**cAdvisor**

### 10.3 K8s 资源状态监控

监控对象：Deployment 副本数、Pod 运行状态、Node 健康状态、PVC 存储状态；数据来源：**kube-state-metrics**

## 11. 核心原理与优化方案

### 11.1 Pull 模型核心优势

Prometheus 采用主动 Pull 模式采集指标，核心优势：

- 服务端统一控制采集频率，指标采集节奏可控

- 可主动判断监控目标在线状态，精准识别目标异常

- 客户端无需复杂配置，轻量化无侵入

- 适配 K8s 动态扩缩容、节点动态变化的云原生场景

### 11.2 K8s 监控目标发现原理

Prometheus 通过 K8s API Server 同步集群资源，依托 `kubernetes_sd` 服务发现机制识别集群资源；在 Operator 架构下，通过 ServiceMonitor、PodMonitor 声明监控规则，自动生成采集配置，实现动态服务发现。

### 11.3 时序数据存储限制原因

时序数据量由 `指标数量 × 标签组合数量` 决定，大量高基数标签（user_id、request_id、session_id）会生成百万级时序数据，造成存储膨胀、查询卡顿，因此无法无限保存数据。

### 11.4 集群监控优化方案

- **降低标签基数**：剔除 user_id、request_id 等唯一高基数标签，减少时序数据总量

- **调整采集间隔**：非核心指标从15s调整为60s，降低采集压力

- **预计算规则**：通过 Recording Rule 预计算复杂 PromQL 结果，提升查询速度

- **任务分片**：多 Prometheus 节点分工采集，节点负责主机指标、节点负责容器指标，分摊压力

## 12. 生产故障排查思路

### 12.1 监控无数据排查链路

确认监控规则 → 校验端点可用性 → 测试指标接口连通性 → 查看服务端目标状态

```Plain Text
kubectl get servicemonitor  # 检查监控规则配置
↓
kubectl get endpoints        # 检查监控端点是否就绪
↓
curl target:port/metrics     # 手动测试指标接口是否正常返回数据
↓
Prometheus UI - Status - Targets  # 查看目标采集状态
```

### 12.2 Target 目标 Down 排查

按层级依次排查：网络连通性 → 端口开放状态 → Service 配置 → Endpoint 就绪状态 → RBAC 权限 → TLS 证书配置

### 12.3 告警推送失败排查

按告警链路逐级定位：规则配置有效性 → 服务端告警触发状态 → Alertmanager 处理状态 → 接收器渠道配置

```Plain Text
PrometheusRule 规则配置
      |
      |
Prometheus Alerts 告警触发状态
      |
      |
Alertmanager 告警处理日志
      |
      |
Receiver 通知渠道配置
```

## 核心总结

Prometheus 是云原生场景下基于 Pull 模型的开源时序监控系统，依托各类 Exporter 实现多组件指标采集，结合 K8s 服务发现与 Operator 实现集群动态监控管理，通过 PromQL 完成多维数据查询分析，借助 Rule 规则生成告警并由 Alertmanager 统一分发。生产环境通常搭配 Grafana 实现可视化、Thanos 实现长期存储与高可用，构成完整、稳定的云原生监控体系。

