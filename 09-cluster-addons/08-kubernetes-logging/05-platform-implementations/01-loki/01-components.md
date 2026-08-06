# loki/components.md
## 1 前置环境基线
- Kubernetes‑v1.32
- Loki 版本：3.3.0
- 存储驱动：NFS‑SC 动态存储类
- 部署模式：Distributed 微服务分布式架构
> 整套服务拆分为 Distributor、Ingester、Query‑Frontend、Querier、Compactor、Index‑Gateway，各组件独立部署、资源隔离、可单独扩缩容。

## 2 组件总览表格
|组件名称|部署类型|是否有状态|核心职责|默认副本数|
|---|---|---|---|---|
|Distributor|Deployment|无状态|接收日志、标签校验、一致性哈希路由、写入负载均衡|3|
|Ingester|StatefulSet|有状态|日志内存缓冲、组装Chunk、持久化块存储、热日志查询|3|
|Query‑Frontend|Deployment|无状态|查询入口、任务拆分、限流、超时控制、查询缓存|2|
|Querier|Deployment|无状态|执行日志检索、读取Chunk、解压、正则过滤、结果合并|按需扩容|
|Compactor|StatefulSet/Deployment|有状态|合并碎片化Chunk、TTL过期清理、标签索引维护|1|
|Index‑Gateway|Deployment|无状态|索引访问代理，屏蔽底层存储，统一处理索引读写|2|

## 3 逐个组件详解
### 3.1 Distributor（写入分发器）
#### 核心工作流程
1. 接收 Fluent‑Bit 推送过来的日志数据流；监听端口 3100
2. 校验日志标签，拦截高‑cardinality 动态标签（traceId、requestId）
3. 使用标签集合做哈希计算，通过一致性哈希算法路由日志到对应 Ingester
4. 多Ingester之间实现哈希环负载均衡，支持Ingester上下线时的数据重分布

#### 关键配置项
```yaml
distributor:
  replication_factor: 3
  limits:
    max_label_names_per_series: 8
```
- 写入副本数为3，保证一条日志下发至多个Ingester实现写入高可用
- 限制单条日志标签数量，从源头规避标签爆炸

#### 运维要点
- 无状态组件，可以随时横向扩容应对高并发写入
- 监控指标：写入QPS、请求延迟、被拒绝的高基数日志条数

---

### 3.2 Ingester（日志写入与缓存组件）
Loki 最核心的有状态组件，负责日志缓存与Chunk生成
1. 接收 Distributor 分发的日志，内存内按照时间窗口缓冲日志
2. 日志按时间排序，打包、压缩生成二进制 Chunk（默认窗口 2h）
3. 将压缩Chunk以及标签‑块索引持久化至NFS/对象存储
4. 对外提供近期驻留在内存里面的热日志查询
5. 支持 WAL 预写日志，Pod崩溃之后可以通过WAL恢复内存日志

#### 关键参数
```yaml
ingester:
  chunk_idle_period: 2h
  chunk_block_size: 262144
  wal:
    enabled: true
```

#### 运维要点
- StatefulSet 部署，绑定独立PVC持久化WAL和本地缓存
- Ingester副本数推荐3，保证写入冗余；Ingester下线会触发Chunk刷新落地
- 内存资源需要预留充足，内存大小决定可承载的内存日志窗口

---

### 3.3 Query‑Frontend 查询前端
作为所有查询流量的统一入口，承担查询调度能力
1. 接收Grafana的LogQL查询请求
2. 将大范围、耗时较长的查询拆分为多个小型子查询
3. 设置查询超时、并发限制、速率限流，防止慢查询压垮集群
4. 开启查询缓存，缓存重复查询结果
5. 将拆分任务下发给后端Querier工作节点

#### 适用优化
- 长时间范围日志检索会被拆分为按小时的子任务并行执行

---

### 3.4 Querier 查询工作节点
无状态的日志检索执行者
1. 接收 Query‑Frontend下发的子查询任务
2. 并行两处数据源：Ingester内存热数据、磁盘冷Chunk文件
3. 读取压缩块、解压日志数据、执行标签过滤、正则匹配日志内容
4. 聚合多条Chunk的日志结果，向上返回

#### 扩容策略
高峰期日志查询量大时，只需要增加Querier副本，不影响写入链路

---

### 3.5 Compactor 块压缩管理器（后台单任务组件）
独立后台服务，负责Chunk后期生命周期管理
1. 把大量碎片化的小Chunk合并成大块，减少磁盘IO、加快查询速度
2. 根据全局 retention_period TTL，清理过期日志Chunk
3. 重建、优化标签索引
4. 清理已经被删除的系列索引记录

> 注意：生产环境一般只部署单个Compactor，多实例会引发Chunk并发冲突

---

### 3.6 Index‑Gateway 索引网关
1. 代理所有标签索引读写请求
2. 屏蔽底层NFS、对象存储细节，Ingester、Querier不需要直接对接存储
3. 索引缓存，加速标签检索速度
4. 存储层更换时只需要修改网关配置，上层组件无感知

## 4 组件之间完整交互链路
### 写入链路
Fluent‑Bit → Distributor → Ingester(内存缓存‑WAL‑生成Chunk) → Index‑Gateway → NFS存储

### 查询链路
Grafana → Query‑Frontend → Querier → Index‑Gateway查询索引 → 读取Chunk → 解压过滤 → 返回结果

## 5 组件资源配置参考（生产环境）
|组件|CPU|内存|
|---|---|---|
|Distributor|2‑4核|2Gi‑4Gi|
|Ingester|4核|4Gi‑8Gi|
|Query‑Frontend|2核|2Gi|
|Querier|2‑4核|4Gi（解压Chunk消耗大量内存）|
|Compactor|2核|2Gi|
|Index‑Gateway|2核|2Gi|

## 6 组件故障处理
1. Distributor副本故障：其余副本承接写入流量，无业务损失
2. Ingester Pod异常：WAL预写日志重启恢复；长时间停机强制刷新所有Chunk落地
3. Compactor异常：过期日志无法自动清理，磁盘持续上涨
4. Querier全部宕机：日志写入正常，仅日志查询功能不可用

## 7 后续文档
- deployment.md：三种部署模式详细落地配置
- storage.md：Chunk存储、索引、持久化方案详解