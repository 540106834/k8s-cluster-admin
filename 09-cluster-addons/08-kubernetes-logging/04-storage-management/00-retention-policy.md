# retention‑policy.md
## 1 环境基线
- Kubernetes v1.32、containerd
- 采集组件：Fluent‑Bit
- 缓冲组件：Kafka
- 存储引擎：Loki / Elasticsearch / ClickHouse
- 存储介质：NFS‑SC 动态存储类、节点本地磁盘
- 核心目标：分环境设置日志生命周期，管控磁盘容量、冷热分层、过期自动清理、审计日志长期留存

## 2 整体分层留存架构
整条日志链路每一层都具备独立的保存周期，分层独立管控：
1. Kafka 消息缓冲层（短期缓冲，故障窗口期）
2. Loki / ES / ClickHouse 持久化存储层（业务查询周期）
3. 冷数据归档层（对象存储，审计长期留存）

## 3 各组件默认留存周期规划
### 3.1 Kafka Topic 消息保存策略
Kafka仅用作流量削峰，不负责长期存储日志
- 开发环境：1 天
- 测试环境：2 天
- 生产环境：3 天
> 用途：存储服务故障、版本升级期间，用来回溯补发日志；超过时长自动清除消息，释放磁盘。

Topic 独立周期配置
- container‑log：1‑3天
- node‑system‑log：1‑3天
- k8s‑audit‑log：单独设置7天缓冲时长，审计消息窗口期拉长

### 3.2 Loki 日志留存策略
按照环境区分TTL，依靠 Compactor 组件自动清理过期 chunk
|环境类型|日志保存时长|说明|
|---|---|---|
|dev 开发环境|3d|调试日志无需长久保存|
|uat 测试环境|7d|测试问题回溯|
|prod 生产业务日志|15d|日常故障排查|
|prod 审计类日志|90d|安全审计、事件溯源|

loki‑runtime 核心配置片段
```yaml
limits_config:
  retention_period: "15d"
```
- 标签为 audit‑log 的数据流单独配置 90 天TTL
- 过期 chunk 直接标记删除，后台 compactor 回收磁盘空间

### 3.3 Elasticsearch 索引生命周期 ILM
采用按天滚动索引，热‑温‑冷‑删除完整生命周期
1. 热阶段（0‑3天）：可读写，部署高性能data节点
2. 温阶段（3‑7天）：关闭写入，降低副本数
3. 冷阶段（7‑15天）：迁移至低速磁盘，关闭索引节省资源
4. 过期删除：业务日志15天；审计日志90天

ILM策略优势
- 索引按日期拆分，单索引体积可控
- 冷热数据物理分层，节约高性能磁盘资源

### 3.4 ClickHouse TTL 分区过期策略
基于MergeTree引擎的时间分区，TTL自动清理过期分区
- 普通业务容器日志：15天
- k8s审计日志：90天

建表示例TTL配置
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
TTL log_time + INTERVAL 15 DAY;
```
审计日志单独一张数据表，TTL设置90天。

## 4 多环境日志留存规范
### 4.1 开发环境 dev
1. Kafka：1天
2. Loki：3天
3. 关闭ES、ClickHouse，不需要长期日志统计

### 4.2 测试环境 uat
1. Kafka：2天
2. Loki：7天
3. 测试业务检索日志ES保存7天

### 4.3 生产环境 prod
1. Kafka：3天
2. 常规业务日志 Loki 15天
3. 需要全文检索的业务ES索引周期15天
4. 审计、访问统计日志 ClickHouse 保存90天

## 5 冷热分层存储方案
1. 热数据（最近3‑7天）：高速本地磁盘，承担日常日志查询
2. 温数据（7‑30天）：NFS共享存储，低速介质
3. 冷数据（超过30天审计日志）：导出至对象存储做归档，默认不在线查询

## 6 特殊日志单独策略
1. apiserver 审计日志：全链路延长生命周期，Kafka7天、ClickHouse保存90天，禁止短周期清理
2. kubelet、节点系统日志：跟随生产业务日志周期15天
3. 容器崩溃、panic错误日志：开启快照持久化，不受常规TTL约束

## 7 磁盘水位阈值配置
设置三层磁盘告警水位，防止日志打满存储介质
1. 警告水位：磁盘使用率 70%，触发告警
2. 预警水位：80%，手动清理无用日志、缩短TTL时长
3. 紧急水位：85%，自动清理最早过期日志，优先释放磁盘

## 8 生命周期运维最佳实践
1. 三层链路周期逐级变长：Kafka缓冲周期 < 在线存储周期 < 冷归档周期
2. 审计日志独立流水线、独立Topic、独立数据表，不和普通业务日志共用TTL
3. 定期核对标签基数，防止大量无效日志持续占用磁盘
4. ES禁止超大索引，严格依靠按天滚动+ILM生命周期管理
5. ClickHouse定时删除无用旧分区，避免分区数量持续膨胀
6. TTL配置文件纳入Git管理，ArgoCD统一下发配置

## 9 常见故障与规避
1. TTL未生效：Loki检查compactor组件正常运行；ES检查ILM策略绑定；ClickHouse核对分区时间字段
2. 磁盘空间持续上涨：动态标签泛滥造成日志量暴涨，优化Fluent‑Bit过滤丢弃无用日志
3. 审计日志被误删：单独数据表、单独TTL，和业务日志物理隔离

## 10 后续文档指引
network‑debug.md 日志平台全套故障排查手册