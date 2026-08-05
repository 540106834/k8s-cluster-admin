# query‑design.md
## 1 环境基线
- Kubernetes v1.32、containerd
- 采集端：Fluent‑Bit
- 缓冲层：Kafka（大规模集群）
- 存储后端：Loki / Elasticsearch / ClickHouse
- 可视化入口：Grafana
- 整体链路：用户查询请求 → Grafana → 存储查询API → 索引检索 → 读取日志数据 → 返回结果

## 2 查询层整体架构分层
```
前端入口(Grafana)
→ 查询代理/前端组件(Loki‑Query‑Frontend、ES‑Coordinator、CH‑HTTP‑Handler)
→ 查询调度、任务拆分、并发控制
→ 索引层过滤（标签索引 / 倒排索引 / MergeTree分区索引）
→ 磁盘数据读取、解压、字段计算、正则匹配、聚合运算
→ 结果合并、限流、返回至前端
```
三种存储拥有独立的查询链路、语法、优化手段，下面分开进行设计说明。

## 3 Loki 查询架构设计
### 3.1 查询组件分工
1. **Query‑Frontend**：查询入口，负责查询限流、拆分大查询、缓存、超时控制、负载均衡
2. **Query**：无状态工作节点，分发查询任务至Ingester与持久化Chunk存储
3. **Ingester**：提供内存中还未落地Chunk的实时日志查询
4. **Compactor**：后台合并日志块，优化后续Chunk查询速度

### 3.2 查询原理
1. 优先借助标签索引做过滤：namespace、pod_name、deployment_name、node_name
2. 根据标签匹配对应的Chunk集合
3. 读取压缩Chunk并解压，在日志正文内部执行正则匹配
4. 汇总日志条目，返回Grafana

### 3.3 LogQL 基础语法示例
```logql
{namespace="dev",pod_name=~"order-.*"} |= "error"
```

### 3.4 Loki 查询最佳实践
1. 查询必须带上时间范围，缩小Chunk扫描范围
2. 依靠标签前置过滤，减少解压的日志块数量
3. 禁止使用没有标签过滤的全量正则查询，会引发大量磁盘IO
4. 标签只存放离散枚举值；动态字段、request‑id、用户id放入日志正文
5. 超大查询开启分片查询、设置查询超时，防止长时间阻塞查询节点

## 4 Elasticsearch 查询架构设计
### 4.1 查询组件分工
1. Coordinator节点：接收查询请求，分发至所有data分片节点，合并返回结果
2. Data‑Node：读取本地分片、倒排索引检索、字段过滤
3. Ingest节点：写入预处理，不承担查询压力

### 4.2 查询原理
1. 依靠倒排索引快速定位包含关键字的文档
2. 支持分词检索、模糊查询、短语匹配、字段过滤
3. 多分片并行查询，最后由coordinator聚合结果

### 4.3 DSL简单示例
```json
{
  "query":{
    "match":{
      "log":"java.lang.Exception"
    }
  }
}
```

### 4.4 ES 查询规范
1. 时间范围作为第一级过滤条件，优先走时间索引
2. 控制分页深度，禁止深度from+size分页，改用scroll或者search‑after
3. 关闭不需要检索字段的索引，减少索引体积
4. 业务低峰期执行段合并，高峰期段合并会拖慢查询性能

## 5 ClickHouse 查询架构设计
### 5.1 查询架构
1. HTTP/TCP接口接收SQL查询
2. 解析SQL，利用分区键裁剪，跳过不在时间范围内的数据分区
3. 在分区之内依靠主键索引稀疏过滤数据块
4. 列式存储只读取SQL涉及的字段，跳过无关列，大幅降低IO
5. 执行聚合、分组、统计之后返回结果

### 5.2 示例SQL
```sql
SELECT count(*) AS error_count
FROM container_log
WHERE log_time >= now() - 3600
AND namespace = 'prod'
AND content LIKE '%error%'
GROUP BY pod_name
```

### 5.3 ClickHouse 查询优化策略
1. 查询必须携带时间条件，触发分区裁剪
2. ORDER BY主键优先使用时间字段
3. 频繁查询字段放在主键前缀
4. 大报表查询设置并发限制，防止压垮集群

## 6 Kafka 查询说明
Kafka只作为消息缓冲层，**不承担日志检索功能**；
仅支持消费、消息回溯，下游存储引擎负责所有查询工作。

## 7 Grafana 统一查询入口设计
1. 多数据源配置：Loki、Elasticsearch、ClickHouse独立数据源
2. 面板分层：
    - 实时日志排查面板（Loki）
    - 全文关键字检索面板（ES）
    - 日志指标大盘、错误统计、PV报表（ClickHouse）
3. 全局时间选择器统一管控日志时间区间
4. 配置查询超时、最大日志返回条数，避免超大查询造成集群负载

## 8 查询层通用生产约束
1. 所有查询强制携带时间范围，禁止无时间限制的全库扫描
2. 区分场景选型：排查日志用Loki、正文检索用ES、统计报表用ClickHouse
3. 设置查询并发上限、查询超时时间，防止慢查询长时间占用IO与CPU
4. 慢查询开启监控，捕获长时间运行的检索语句并优化
5. 生产环境禁止业务Pod直接访问存储查询接口，所有查询流量经过Grafana权限入口

## 9 高频故障和优化方案
1. Loki查询缓慢：标签过少、需要解压大量Chunk；增加标签过滤条件
2. ES查询卡顿：分片数量过多、深度分页、段合并IO抢占资源；优化分页方式
3. ClickHouse报表耗时：没有触发分区裁剪；查询条件带上时间范围
4. Grafana请求超时：日志量过大，缩短查询时间窗口，增加前置过滤条件

## 10 后续文档指引
daily‑operation.md，日志平台日常运维、巡检、参数调优规范