# loki/best‑practices.md
## 环境基线
- Kubernetes‑v1.32
- Loki 版本：3.3.0
- 存储后端：nfs‑sc NFS动态存储类
- 部署模式：distributed 分布式微服务架构

本文档整理生产环境标签规范、组件调优、存储策略、查询优化、安全管控、故障规避全套最佳实践。

## 一、标签（Label）管控规范，规避标签基数爆炸
标签基数过高是 Loki 最常见故障，索引内存飙升、集群写入卡顿。
### 1. 标签白名单原则
只保留用于筛选业务的有限标签，禁止动态、高基数字段作为标签
**允许标签**
`namespace_name、pod_name、deployment_name、container_name、env、app`
**禁止设置为标签**
traceId、requestId、uuid、用户ID、手机号、随机值、IP

> 所有动态唯一字段放置于日志正文，依靠正则进行检索。

### 2. 配置标签数量硬性限制
在 distributor 配置单条日志最大标签数量
```yaml
distributor:
  limits:
    max_label_names_per_series: 8
    max_label_value_length: 256
```

### 3. 高基数标签拦截
开启拒绝高基数序列，当单个标签数值过大直接丢弃该条日志并上报监控告警。
```yaml
distributor:
  limits:
    max_streams_per_user: 15000
```

### 4. Fluent‑Bit侧提前裁剪字段
在采集阶段清理无用 k8s 元数据
```ini
[FILTER]
    Name         modify
    Match        kube.*
    Remove_Field kubernetes.pod_ip
    Remove_Field kubernetes.host_ip
```

## 二、写入链路最佳实践
### 1. Ingester 配置
1. WAL预写日志强制开启，防止日志丢失
2. chunk‑idle‑period 设置 2h，定时刷新内存日志落地Chunk
3. 生产副本数 ≥3，写入副本复制因子等于3
```yaml
ingester:
  wal:
    enabled: true
  chunk_idle_period: 2h
  replication_factor: 3
```

### 2. Distributor
1. 多副本部署实现写入入口高可用
2. Fluent‑Bit配置多个Loki写入地址，做接入层负载均衡与故障容灾
3. 开启写入延迟监控，P95延迟高于200ms则扩容Ingester

### 3. 大规模集群前置Kafka
高并发集群采用缓冲架构：`Fluent‑Bit → Kafka → Loki`
削峰填谷，避免日志突发流量压垮写入链路。

## 三、存储层调优规范
1. Ingester WAL 使用独立PVC，禁止临时本地磁盘；
2. Chunk、TSDB索引存放NFS共享存储；
3. NFS单目录文件过多，依靠Compactor合并碎片化Chunk；
4. 磁盘水位：70%告警、80%严重告警、85%触发过期日志清理；
5. 环境差异化日志保存周期
    - dev：3d
    - uat：7d
    - prod业务日志：15d
    - 审计日志：90d

```yaml
limits_config:
  retention_period: "15d"
```

## 四、查询链路优化方案
### 1. Query‑Frontend
- 开启查询拆分、慢查询超时、查询缓存
- 长时间范围查询会被拆分为按小时的子任务并行执行
```yaml
queryFrontend:
  max_query_timeout: 30s
  cache_results: true
```

### 2. Querier
1. Chunk解压消耗大量CPU内存，查询高峰期依靠HPA自动弹性伸缩
2. 冷热查询分离：热日志交由只读Ingester查询，冷日志读取共享存储Chunk
3. 禁止一次性查询多天超大时间区间日志

### 3. LogQL 查询编写规范
1. 优先使用标签进行精准过滤，再使用正则匹配日志正文
```logql
{namespace_name="order",app="order‑service"} |= "Exception"
```
2. 避免无标签全量检索 `{}`，会扫描全部Chunk
3. 使用 `|=` 包含匹配，尽量不用昂贵的正则 `|~`
4. 聚合查询添加时间步长，减少计算压力

## 五、Compactor 后台组件规范
1. Compactor 只允许单实例运行，多实例会引发Chunk文件并发冲突；
2. 碎片Chunk合并周期避开业务高峰期；
3. 监控Compactor运行状态，一旦停止过期日志无法自动清理，磁盘会持续膨胀。

## 六、资源配置标准
|组件|CPU|内存|
|---|---|---|
|Distributor|2‑4核|2Gi‑4Gi|
|Ingester|4核|4Gi‑8Gi|
|Query‑Frontend|2核|2Gi|
|Querier|2‑4核|4Gi|
|Compactor|2核|2Gi|
|Index‑Gateway|2核|2Gi|

## 七、安全与脱敏规范
1. Fluent‑Bit Lua脚本对手机号、密码、token、密钥自动脱敏；
2. 日志平台RBAC权限隔离，不同命名空间日志只开放对应开发人员查看权限；
3. 禁止日志明文打印账号、密钥、银行卡等敏感信息；
4. Ingester、Index‑Gateway存储卷开启访问权限管控。

## 八、日常运维与故障避坑清单
1. Ingester缩容前先切换只读模式，等待内存Chunk全部落地再下线；
2. 升级Loki版本优先测试开发环境，再依次UAT、生产；
3. 定时备份Chunk存储目录与TSDB索引；
4. 重点监控指标：写入QPS、流(stream)数量、日志丢弃条数、磁盘使用率、查询超时数量；
5. NFS挂载故障优先排查存储服务、节点挂载状态，写入阻塞优先检查WAL磁盘是否占满；
6. 集群扩容优先扩容Ingester解决写入瓶颈，扩容Querier解决查询缓慢。

## 九、环境分层架构建议
- 小规模集群：single‑binary
- 中小型生产：simple‑scalable
- 大型企业集群：distributed微服务架构 + Kafka前置缓冲 + 冷热日志分离

## 十、后续文档指引
完成Loki模块之后，可以切换查看 elk/、clickhouse/目录下架构、部署、调优文档，做多日志存储方案对比选型。