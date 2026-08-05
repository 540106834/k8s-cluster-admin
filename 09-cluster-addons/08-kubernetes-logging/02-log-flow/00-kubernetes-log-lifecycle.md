# kubernetes‑log‑lifecycle.md
## 1 概述
本文完整描述一条容器日志从业务程序输出、containerd落地、Fluent‑Bit采集加工、中间件缓冲、后端存储写入、周期管理、用户查询直至过期销毁的全生命周期；同时区分普通容器日志、节点系统日志、apiserver审计日志三条数据流。  
环境基线：K8s‑v1.32、containerd、Fluent‑Bit采集器；消息队列缓冲选用Kafka；存储后端支持 Loki / Elasticsearch / ClickHouse。

## 2 日志完整生命周期总流程（新增Kafka缓冲架构）
### 架构A：直连存储（简单环境）
```
业务应用输出(stdout/stderr)
→ containerd 驱动写入宿主机日志文件
→ Fluent‑Bit 监听文件采集日志
→ Pipeline流水线预处理
→ 通过内网TLS上报至日志存储组件
→ 数据写入存储、建立索引、时间分区
→ Grafana检索查询
→ 日志定时过期、压缩、清理、磁盘回收
```

### 架构B：Kafka消息队列缓冲（高吞吐生产架构，推荐大规模集群）
```
业务应用输出(stdout/stderr)
→ containerd落地宿主机日志文件
→ Fluent‑Bit采集、解析、标签注入、预处理
→ 推送至Kafka Topic做消息削峰、异步缓冲
→ 消费端组件(Loki‑Distributor / Fluent‑Bit消费端)消费日志
→ 写入 Loki / Elasticsearch / ClickHouse
→ Grafana检索查询
→ 生命周期过期清理
```

## 3 阶段1：日志产生（应用 → 容器运行时）
1. 业务进程在容器内部打印控制台输出，stdout标准输出、stderr标准错误流。
2. containerd‑shim接管容器标准输出，不会将日志存放在容器可读写层；
3. 按照容器运行时日志驱动，日志落地至宿主机文件：
`/var/log/containers/xxx‑pod‑xxx_namespace‑xxx.containerd‑xxx.log`
4. 日志文件采用json格式，内置时间戳、日志正文、日志流标识。
> 容器删除之后，宿主机对应的日志文件会被containerd自动清理。

### 额外日志源
- kubelet、kube‑proxy组件日志：`/var/log/kubelet`
- 操作系统内核日志：`/var/log/syslog`
- k8s‑apiserver审计日志：socket或者文件输出

## 4 阶段2：节点采集阶段（Fluent‑Bit 读取日志）
1. DaemonSet运行在Worker节点的Fluent‑Bit通过tail插件监听宿主机日志目录；
2. 监控日志文件新增行，处理日志轮转，日志文件切割之后自动追踪新文件；
3. 读取原始JSON日志，进入内置流水线。

## 5 阶段3：Pipeline日志预处理流程
1. **Parser解析**：拆解containerd json日志，分离timestamp、log、stream字段；
2. **Kubernetes过滤器**：根据Pod IP或者容器ID，自动注入元数据标签
namespace、pod_name、deployment_name、node_name、labels；
3. **Filter过滤**：丢弃健康检查、无用调试日志、重复日志；
4. **Modify字段处理**：新增自定义标签、删除无用字段、字段重命名；
5. **脱敏处理**：正则匹配手机号、密钥、token、账号进行掩码；
6. **缓冲区**：优先内存缓冲，后端存储故障时写入宿主机磁盘缓冲目录；
7. **Output输出分支**
    - 小规模集群：直接输出 Loki / ES / ClickHouse
    - 大规模集群：输出至 Kafka 对应Topic

## 6 新增：Kafka中间缓冲层详解
### 6.1 Kafka架构定位
作为日志链路的异步削峰层，隔离前端采集Agent与后端存储，应对日志洪峰、存储组件短时故障、存储扩容停机。
- Topic划分建议：container‑log、audit‑log、node‑syslog，三类日志物理隔离
- 分区数量：根据集群节点规模、日志吞吐量规划分区
- 副本数≥2，保障消息可靠性
- 消息留存时长：建议1‑3天，作为故障窗口期缓冲

### 6.2 两条消费模式
1. **模式一：Loki‑Distributor 原生消费Kafka**
Distributor内置kafka消费者，直接拉取消息写入Ingester。
2. **模式二：独立Fluent‑Bit消费端**
独立部署消费端Pod，消费Kafka之后分发至不同存储后端，实现日志分流：
    - 容器普通日志 → Loki
    - 需要全文检索业务日志 → Elasticsearch
    - 审计、访问日志 → ClickHouse

### 6.3 Kafka架构优势
1. 削峰限流：业务突发大量日志不会直接压垮存储组件
2. 解耦采集端和存储端，存储升级、重启不会造成Agent日志丢弃
3. 支持日志多副本分发，一份日志同时投递多个存储引擎
4. 具备消息回溯，存储故障恢复之后可以重新消费区间内日志

## 7 阶段4：后端存储写入流程
### 7.1 Loki
1. Distributor接收日志，校验标签、哈希分片；
2. Ingester接收数据流，内存缓存、压缩生成Chunk日志块；
3. Chunk持久化至NFS‑SC存储；标签索引单独存放；
4. Ruler组件定时执行日志告警规则。

### 7.2 Elasticsearch
1. 数据投递至ES集群，写入对应日期索引；
2. 分片生成倒排索引，支持全文分词检索；
3. 后台执行段合并优化索引结构。

### 7.3 ClickHouse
1. 接收HTTP接口日志数据；
2. 按照时间字段写入对应日期分区表；
3. 生成主键稀疏索引，依靠分区裁剪加速海量日志查询。

## 8 阶段5：日志访问与检索
1. 用户在Grafana填写检索条件：命名空间、工作负载、Pod名称、日志关键词；
2. Grafana调用对应存储组件的查询API；
3. Loki：检索标签索引，找到对应日志Chunk，解压之后匹配正则；
4. Elasticsearch：基于倒排索引进行全文检索；
5. ClickHouse：SQL语句执行多维度分组、聚合、统计；
6. Kafka只承担消息缓冲，不负责日志检索。

## 9 阶段6：日志生命周期管理（过期、压缩、删除）
1. 按照平台留存策略区分不同环境日志保存时长：开发环境短留存、审计日志长期保存；
2. Kafka：Topic消息到达保留时长后自动清除；
3. Loki：过期Chunk直接删除；
4. Elasticsearch：通过索引生命周期管理ILM，冷数据迁移、关闭索引、删除旧索引；
5. ClickHouse：通过TTL策略自动清理过期分区；
6. 磁盘空间回收，完成一条日志完整生命周期。

## 10 三类特殊日志独立链路
1. **容器标准输出日志**：应用 → containerd日志文件 → Fluent‑Bit → Kafka(可选) → 存储
2. **节点组件日志**：kubelet落地/var/log → Fluent‑Bit采集
3. **apiserver审计日志**：api‑server输出审计日志 → 独立Kafka‑Topic，单独消费写入存储，禁止业务日志混入

## 11 四种整体架构选型对比
|架构方案|适用集群规模|优点|短板|
|---|---|---|---|
|Fluent‑Bit直连Loki|小规模集群|架构简单、组件少|日志洪峰容易压垮存储|
|Fluent‑Bit+Kafka+Loki|中大型生产集群|削峰缓冲、解耦上下游|需要维护一套Kafka集群|
|Fluent‑Bit+Kafka+ES|需要全文检索|消息可靠、分词检索强大|资源开销很高|
|Fluent‑Bit+Kafka+ClickHouse|海量审计日志、统计场景|列式存储聚合性能优秀|不适合正文模糊检索|

## 12 生命周期常见故障点位
1. 容器日志轮转过快，tail插件漏采日志；
2. Fluent‑Bit磁盘缓冲目录空间占满造成日志丢弃；
3. k8s标签数量过多，Loki索引膨胀；
4. Kafka分区不足、消息堆积、磁盘打满；
5. ES分片过多、段合并阻塞写入；
6. ClickHouse时间分区规划不合理，查询扫描海量分区；
7. 网络中断，Agent缓冲溢出丢失日志。

## 13 后续文档
`container‑runtime‑shturl` 深入讲解containerd日志驱动、日志文件结构与轮转机制