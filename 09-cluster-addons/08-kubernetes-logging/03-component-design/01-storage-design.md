# storage‑design.md
## 1 前置环境基线
- Kubernetes v1.32，containerd容器运行时
- 日志采集端：Fluent‑Bit DaemonSet
- 异步缓冲组件：Kafka（大中型集群必备削峰中间件）
- 持久化存储供给：NFS‑SC StorageClass
- 三类存储引擎：Loki（默认容器日志）、Elasticsearch（全文检索）、ClickHouse（海量日志聚合统计）
- 配置管理：GitOps + ArgoCD，离线组件包存放于MinIO

## 2 整体存储分层架构
完整日志存储链路：
`Fluent‑Bit节点预处理 → Kafka消息队列(可选缓冲层) → 存储引擎写入层 → 持久化磁盘层 → 索引层 → Grafana查询层`

四层存储架构分层
1. **消息缓冲层**：Kafka，承担流量削峰、上下游解耦、消息多副本分发
2. **写入网关层**：Distributor / ES‑Ingest / ClickHouse‑HTTP接口，接收日志流量、负载均衡
3. **引擎内核层**：Ingester、分片节点、分区表，完成日志压缩、索引构建
4. **持久化层**：依托集群NFS‑SC提供PVC，保存Chunk、分片数据、分区表文件

## 3 Loki 存储架构（容器日志默认方案）
### 3.1 组件拆分
1. **Distributor**：无状态Deployment多副本；接收Fluent‑Bit或者Kafka上报日志，根据标签哈希进行分片路由；校验标签，拦截标签基数过大的非法日志
2. **Ingester**：StatefulSet，绑定NFS‑SC PVC；内存缓存日志，定时压缩生成Chunk日志块；写入持久化存储；维护标签索引
3. **Query‑Frontend / Query**：日志查询入口，拆分查询任务、调度Ingester读取压缩块、解压日志、正则匹配
4. **Ruler**：日志告警规则评估组件，基于日志触发错误告警
5. **Compactor**：后台合并小块、清理过期日志、优化磁盘Chunk结构

### 3.2 索引设计（Loki核心要点）
1. 仅对标签建立索引：namespace_name、pod_name、deployment_name、node_name
2. 日志正文不会构建倒排索引，依靠Chunk内部正则检索，磁盘占用极低
3. 严格管控标签数量，禁止将动态值（请求ID、用户ID）设置为标签，防止标签爆炸
4. 标签索引与日志Chunk分开存储

### 3.3 持久化规范
- Ingester使用StatefulSet绑定NFS‑SC
- Chunk块默认压缩存储，降低磁盘开销
- 配置日志过期TTL，自动清理超出保存周期的Chunk

## 4 Elasticsearch 存储架构（全文检索场景）
### 4.1 节点角色拆分
1. Master节点：集群元数据管理、分片调度，3副本保证集群高可用
2. Data节点：承载分片数据、构建倒排索引、磁盘IO读写
3. Ingest节点：前置日志预处理，解析、字段转换
4. Coordinator节点：接收查询请求，聚合多分片检索结果

### 4.2 索引结构设计
1. 采用按天滚动索引 `container‑log‑20260805`
2. ILM索引生命周期管理：热索引、冷索引、关闭索引、自动删除过期索引
3. 倒排索引对日志全字段分词，适合正文模糊检索、短语匹配
4. 分片规划：分片数量根据日志吞吐量提前规划，单分片数据量控制在30‑50GB

### 4.3 生产约束
1. JVM堆内存设置为物理内存一半，最大不超过31G
2. 禁止NFS远端存储作为ES数据盘，优先本地磁盘；NFS仅小规模测试环境使用
3. 段合并会产生较高IO压力，业务低峰期执行合并任务

## 5 ClickHouse 存储架构（日志聚合、审计统计场景）
### 5.1 部署结构
StatefulSet部署ClickHouse集群，NFS‑SC挂载数据表目录；采用多副本模式保障数据可靠。

### 5.2 表结构核心设计
1. 引擎选用MergeTree，依靠时间字段做分区键，按日期自动分区
2. 主键设置日志时间 + namespace，依靠分区裁剪大幅缩小查询扫描范围
3. 列式存储结构，聚合、count、sum、group‑by多维度统计性能优秀

示例建表核心参数
```sql
CREATE TABLE container_log
(
    log_time DateTime,
    namespace String,
    pod_name String,
    content String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(log_time)
ORDER BY (log_time,namespace)
```

### 5.3 生命周期
依靠TTL配置自动清理过期分区，适合K8s审计日志、访问日志大盘统计。

## 6 Kafka缓冲层存储设计
1. Topic拆分：`container‑log`、`node‑system‑log`、`k8s‑audit‑log`，三类日志物理隔离
2. 副本数 ≥ 2，保证消息可靠性
3. 消息保存时长设置1‑3天，作为存储组件故障窗口期
4. 分区数量 ≥ 集群节点数，防止单分区写入瓶颈
5. 磁盘存储优先本地磁盘，高吞吐场景禁止NFS挂载Kafka数据目录

## 7 三类存储引擎横向对比
|存储引擎|索引机制|存储开销|核心能力|适合业务场景|
|---|---|---|---|---|
|Loki|标签索引，正文无索引|极低|标签筛选+正则检索|Pod标准输出、集群容器日志排查|
|Elasticsearch|全字段倒排分词索引|很高|全文检索、模糊搜索|业务日志关键字深度检索|
|ClickHouse|MergeTree分区+主键稀疏索引|中等|SQL聚合、分组统计、报表|审计日志、访问日志指标大盘|

## 8 生产环境通用存储规范
1. Loki Ingester、ES‑Data、ClickHouse数据节点调度至高性能专属节点，使用节点标签隔离资源
2. 容器业务日志优先存入Loki；需要检索的业务日志分流至ES；审计日志统一写入ClickHouse
3. 所有存储组件开启资源Limit，避免日志洪峰耗尽节点资源
4. 定时执行存储层备份：Loki‑Chunk快照、ES索引快照、ClickHouse分区备份
5. 监控磁盘使用率、写入延迟、索引数量、分区堆积，设置磁盘水位告警
6. 审计日志链路独立，不和普通业务日志共用存储实例

## 9 存储层常见故障与规避方案
1. Loki标签基数爆炸：严格管控标签，动态字段放入日志正文而非标签
2. Elasticsearch分片过多、段合并阻塞写入：合理规划分片，配置ILM生命周期
3. ClickHouse查询缓慢：优化时间分区，查询必须携带时间条件触发分区裁剪
4. Kafka消息堆积：扩容分区数量、增加消费端实例、优化Fluent‑Bit预处理过滤无用日志
5. NFS磁盘IO瓶颈：高吞吐场景存储引擎更换宿主机本地磁盘

## 10 后续文档指引
data‑retention.md，日志留存周期、TTL策略、冷热分层、过期清理方案