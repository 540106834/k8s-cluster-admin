# loki/deployment.md
## 环境基线
- Kubernetes：v1.32
- Loki 版本：3.3.0
- 存储类：`nfs‑sc` 动态NFS存储
- 部署模式：Single‑Binary、Simple‑Scalable、Distributed‑MicroService 三种方案，适配不同集群规模

## 1 三种部署模式对比
|部署模式|架构说明|适用集群规模|优点|短板|
|---|---|---|---|---|
|Single‑Binary|所有组件打包为单个进程|测试环境、开发集群、节点≤10|部署简单，仅一个Release；配置量少|写入、查询、压缩耦合，无法单独扩容组件，生产稳定性差|
|Simple‑Scalable|拆分为写入(Ingester‑Distributor)、查询(Querier‑Query‑Frontend)两大模块|中小型生产集群，节点10‑30|写入与查询链路资源隔离；部署成本适中|精细化管控能力不足，索引、压缩组件无法独立扩容|
|Distributed 分布式微服务|Distributor / Ingester / Query‑Frontend / Querier / Compactor / Index‑Gateway 独立工作负载|大型生产集群，节点＞30|每个组件独立扩缩容、资源隔离、故障域隔离、适合高并发|组件多、运维复杂，需要管理多组工作负载|

## 2 Single‑Binary 单二进制部署（测试环境）
### 1）values.yaml 关键配置
```yaml
mode: single‑binary
singleBinary:
  replicas: 1
storage:
  type: filesystem
  filesystem:
    directory: /loki/data
persistence:
  enabled: true
  storageClassName: nfs‑sc
  size: 20Gi
limits_config:
  retention_period: "7d"
```
- 适合dev环境快速搭建；日志保存周期7天
- 所有功能集成，Distributor、Ingester、Compactor、Querier全部内置
- 缺点：单进程瓶颈，不适合高并发写入场景

## 3 Simple‑Scalable 简易可伸缩模式（中小型生产推荐）
架构拆分：写入组、查询组
1. 写入链路：Distributor + Ingester(StatefulSet)
2. 查询链路：Query‑Frontend + Querier
3. Compactor、Index‑Gateway内置

### 核心配置片段
```yaml
mode: simple‑scalable
distributor:
  replicas: 2
ingester:
  replicas: 3
  persistence:
    enabled: true
    storageClassName: nfs‑sc
queryFrontend:
  replicas:2
querier:
  replicas:2
limits_config:
  retention_period: "15d"
```
### 扩容规则
1. 写入压力上涨 → 调高Distributor副本、Ingester副本
2. 日志查询并发高 → 扩容Querier实例
3. Ingester采用StatefulSet + PVC，保证WAL预写日志持久化

## 4 Distributed 完整微服务分布式模式（大型生产集群）
所有组件拆分为独立Deployment/StatefulSet，生产企业级标准架构
```yaml
mode: distributed
distributor:
  replicas: 3
ingester:
  replicas: 3
  persistence:
    enabled: true
    storageClassName: nfs‑sc
queryFrontend:
  replicas: 2
querier:
  replicas: 3
compactor:
  replicas: 1
indexGateway:
  replicas:2
```
### 各组件部署类型
1. Deployment：Distributor、Query‑Frontend、Querier、Index‑Gateway（无状态，随时伸缩）
2. StatefulSet：Ingester、Compactor（需要绑定持久化存储）

## 5 存储部署方案
1. 小规模集群：共用NFS‑SC，Chunk、索引全部存放NFS共享存储
2. 大规模集群：
    - Index‑Gateway独立对接索引存储
    - Chunk块存储使用对象存储；NFS仅作为缓存层

## 6 网络配置要点
1. Loki 写入端口 3100，集群内部Service暴露
2. Fluent‑Bit通过 `loki.logging.svc.cluster.local:3100` 推送日志
3. Query‑Frontend开启内网访问，Grafana通过Service访问查询入口

## 7 生产环境部署顺序
1. 创建logging命名空间
2. 部署Index‑Gateway，优先拉起索引代理服务
3. 启动写入链路：Distributor → Ingester
4. 启动查询链路：Query‑Frontend → Querier
5. 部署后台Compactor组件
6. Fluent‑Bit配置输出指向Loki写入地址
7. Grafana配置Loki数据源，测试日志采集‑查询全链路

## 8 资源配额参考（Distributed模式）
```yaml
distributor:
  resources:
    requests: {cpu:"2",memory:"2Gi"}
    limits: {cpu:"4",memory:"4Gi"}
ingester:
  resources:
    requests: {cpu:"4",memory:"4Gi"}
    limits: {cpu:"4",memory:"8Gi"}
queryFrontend:
  resources:
    requests: {cpu:"2",memory:"2Gi"}
querier:
  resources:
    requests: {cpu:"2",memory:"4Gi"}
compactor:
  resources:
    requests: {cpu:"2",memory:"2Gi"}
indexGateway:
  resources:
    requests: {cpu:"2",memory:"2Gi"}
```

## 9 环境差异化配置
1. dev环境：single‑binary，TTL=3d
2. uat环境：simple‑scalable，TTL=7d
3. prod环境：distributed分布式架构，常规日志TTL=15d、审计日志TTL=90d

## 10 上线验收检查清单
1. Ingester副本数≥3，WAL预写日志目录PVC正常挂载
2. Distributor标签拦截功能生效，拒绝高基数标签
3. Compactor正常运行，Chunk定时合并、过期日志自动清理
4. Fluent‑Bit无日志丢弃指标
5. Grafana可以正常检索容器日志

## 11 后续文档
- storage.md：TSDB、NFS/对象存储、索引网关详细配置
- scaling.md：集群扩容、缩容、Ingester哈希环伸缩方案