# loki/scaling.md
## 环境基线
- Kubernetes‑v1.32
- Loki‑3.3.0
- 存储后端：nfs‑sc NFS动态存储类
- 分布式部署模式：distributed微服务架构
本文档覆盖写入链路、查询链路、Ingester哈希环扩容、缩容、故障迁移、读写分离、集群水平扩容全套方案

## 1、组件扩容原则
Loki读写链路组件完全解耦，可以分开进行伸缩
1. **写入链路（Distributor、Ingester）**：负责日志接收、路由、缓存、生成Chunk；写入瓶颈优先扩容Ingester
2. **查询链路（Query‑Frontend、Querier）**：负责日志检索、Chunk解压、正则匹配；查询卡顿优先增加Querier副本
3. Index‑Gateway、Compactor属于后台组件，一般不需要频繁扩容

|组件|扩容触发条件|伸缩方式|
|---|---|---|
|Distributor|写入QPS高、请求延迟上涨、写入报错|无状态Deployment直接增加副本|
|Ingester|内存负载高、单实例日志量大、Chunk堆积|调整哈希环，新增Ingester节点|
|Query‑Frontend|大量慢查询、查询排队超时|Deployment扩容|
|Querier|日志检索缓慢、解压CPU占用高|无状态水平扩容|
|Index‑Gateway|索引读取IO压力过高|增加副本，开启索引缓存|
|Compactor|Chunk碎片太多、合并速度跟不上碎片生成|仅允许单实例，不可多副本|

## 2、Distributor 水平扩容
Distributor属于无状态接入层，所有实例共用一套一致性哈希环
1. 多个Distributor负载均衡接收Fluent‑Bit推送的日志
2. 内部哈希配置统一，标签哈希之后路由到相同Ingester
3. 扩容操作：直接修改Deployment副本数量
```bash
kubectl scale deployment loki‑distributor -n logging --replicas=5
```
> Fluent‑Bit可以配置多个loki写入地址，实现写入接入层负载均衡与故障冗余

## 3、Ingester 哈希环扩容（核心难点）
Ingester是有状态组件，依靠一致性哈希环分配日志序列
### 3.1 新增Ingester完整流程
1. 直接扩容StatefulSet副本，新的Ingester启动并加入哈希环
2. 哈希环发生重映射，一部分标签序列路由至新节点
3. 旧Ingester将对应系列刷新为Chunk落地共享存储
4. 新流入日志写入新Ingester；历史冷数据依旧保存在原有存储
5. 整个过程不会丢失日志，不需要手动迁移存量Chunk

### 3.2 Ingester缩容下线步骤（安全操作顺序）
1. 先将要下线的Ingester设置为**只读模式**，不再接收新写入流量
```yaml
ingester:
  lifecycler:
    ring:
      readonly: true
```
2. 等待内存中全部日志刷新落地Chunk至NFS共享存储
3. 确认WAL数据已经持久化完毕
4. 缩减StatefulSet副本数，销毁该实例
5. 哈希环重新平衡，剩余Ingester承接全部写入流量

### 3.3 生产硬性规范
- 生产环境Ingester副本最少3个，保障写入副本复制因子replication_factor=3
- 不要强制删除正在运行Ingester的Pod，容易造成内存日志丢失
- WAL持久化PVC不要随Pod删除，保留用于故障恢复

## 4、查询链路扩容
### Query‑Frontend
查询流量入口，负责拆分大范围LogQL查询、限流、缓存
- 大量长时间范围日志查询会加重前端压力，直接增加副本
- 开启查询缓存可以大幅减轻Querier压力

### Querier 工作节点扩容
Querier是最容易出现资源瓶颈的组件
1. 查询大量冷Chunk时需要解压二进制日志块，消耗大量CPU、内存
2. 高峰期日志检索超时、Grafana查询缓慢，优先扩容Querier
3. Querier为无状态组件，可以弹性伸缩，配合HPA实现自动扩缩容
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: loki‑querier‑hpa
  namespace: logging
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: loki‑querier
  minReplicas: 2
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

## 5、Index‑Gateway 索引层扩容
所有TSDB索引读取请求经过网关代理
- 多副本部署分担索引IO压力
- 依靠内存缓存热点TSDB索引，减少NFS重复读取
- 索引访问延迟上涨时直接增加副本数量

## 6、读写分离架构（大型集群）
1. **写入Ingester**：专注日志接收、内存缓存、生成Chunk
2. **只读Ingester**：专门承接热日志查询流量，分担写入Ingester查询压力
3. Querier优先访问只读节点查询近期热日志；冷日志直接读取NFS‑Chunk

## 7、Ingester 故障节点迁移流程
1. 故障Ingester Pod异常崩溃
2. 依靠WAL预写日志重启回放，恢复内存日志
3. 无法恢复时，哈希环自动把流量转移至剩余健康Ingester
4. 旧节点Chunk保存在共享NFS存储，Querier仍然可以正常读取历史日志

## 8、存储层面扩容
1. NFS存储空间不足：扩容存储后端、扩容PV容量
2. 文件数量太多：依靠Compactor合并小Chunk，减少碎片文件
3. 超大规模集群切换后端至MinIO对象存储，解除单目录文件上限约束

## 9、集群扩容最佳实践
1. 写入链路压力优先增加Ingester，不要单纯扩容Distributor
2. 查询卡顿优先扩容Querier，Querier是日志解压计算层
3. Inester缩容必须先走只读模式、刷新Chunk，再销毁实例
4. 开启Querier的HPA弹性伸缩，应对早晚峰查询流量波动
5. replication‑factor保持为3，保证一条日志分发至3个Ingester实现高可用
6. Compactor只允许单实例运行，多实例会引发Chunk并发冲突损坏

## 10、后续文档
- best‑practices.md：标签规范、LogQL查询优化、线上故障规避、调优清单