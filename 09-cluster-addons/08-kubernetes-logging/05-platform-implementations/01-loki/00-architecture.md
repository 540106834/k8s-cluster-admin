# loki/architecture.md
## 1 环境基线
- Kubernetes v1.32
- 采集Agent：Fluent‑Bit
- 可选缓冲组件：Kafka
- 存储介质：NFS‑SC 动态存储类 / 对象存储
- Loki 版本：3.3.0

## 2 整体架构概述
Loki 是 Grafana 推出的云原生日志系统，核心设计思想：**只给标签建立索引，压缩存储原始日志正文**，相比 Elasticsearch 大幅降低内存、磁盘开销。
整体数据流链路：
> Pod标准输出 → containerd日志文件 → Fluent‑Bit采集、过滤、脱敏 → Distributor → Ingester内存缓存 → 压缩生成Chunk块 → 持久化存储；查询链路：Grafana → Query‑Frontend → Querier → 读取Chunk、解压、正则检索日志

## 3 分布式微服务组件分层架构
分布式模式拆分为多个独立无状态/有状态组件，各个组件可独立扩缩容：
1. **Distributor（分发器，无状态）**
2. **Ingester（写入存储，有状态）**
3. **Query‑Frontend（查询前端，无状态）**
4. **Querier（查询工作节点，无状态）**
5. **Compactor（块压缩清理，单实例）**
6. **Index‑Gateway（索引网关）**

### 3.1 Distributor
- 接收 Fluent‑Bit 推送上来的日志数据流
- 校验标签基数，拦截高基数动态标签，防止标签爆炸
- 根据标签哈希一致性哈希路由至对应 Ingester
- 多副本部署，承担写入负载均衡，无状态可以横向扩容

### 3.2 Ingester（核心写入组件）
- 接收Distributor转发过来的日志
- 内存缓存近期日志，按照时间打包成Chunk压缩块
- 将Chunk和标签索引持久化至后端存储
- 提供内存中未落地日志的实时查询
- StatefulSet部署，绑定PVC持久化存储；生产环境建议3副本保证高可用

### 3.3 Query‑Frontend
- 查询流量入口，接收来自Grafana的LogQL查询请求
- 大查询任务拆分、查询限流、超时管控、查询缓存
- 将拆分后的任务下发给Querier执行

### 3.4 Querier
- 无状态查询工作节点
- 并行查询Ingester内存热数据以及磁盘上的Chunk压缩文件
- 解压日志块、执行标签过滤、正文正则匹配
- 合并多条查询结果，向上返回至Query‑Frontend

### 3.5 Compactor
- 后台独立运行的组件
- 合并碎片化的小型Chunk，优化读取性能
- 根据TTL策略清理过期日志块，回收磁盘空间
- 重建、维护标签索引

### 3.6 Index‑Gateway
- 代理索引读取请求，隔离索引存储与查询组件
- 适配对象存储、NFS存储的索引访问

## 4 存储层架构
Loki分为Chunk日志块存储 + 标签索引存储两块数据
1. Chunk：经过高压缩的二进制日志块，压缩倍率可达10~15倍；存放NFS或者对象存储
2. Label‑Index：标签与Chunk之间的映射关系，仅存储筛选字段，不对日志正文建立索引

## 5 三种部署模式
1. **Single‑Binary 单二进制模式**
所有组件打包为一个程序；适合测试、小规模开发环境，无法单独扩容组件。
2. **Simple‑Scalable 简易分布式**
拆分写入组件与查询组件；中小型生产集群常用。
3. **Distributed 完整微服务分布式**
所有组件独立部署，Distributor、Ingester、Querier、Compactor分开扩容；大型集群标准架构。

## 6 完整流量链路详解
### 写入链路
1. Fluent‑Bit完成容器日志采集、k8s标签注入、无用日志过滤、敏感字段脱敏
2. 日志推送至Loki‑Distributor
3. Distributor校验标签，通过哈希路由分发日志到Ingester
4. Ingester内存缓冲日志，定时打包生成Chunk
5. Chunk与标签索引持久化NFS存储

### 查询链路
1. 用户在Grafana编写LogQL日志查询语句
2. 请求抵达Query‑Frontend，拆分查询、设置超时
3. Querier 并行访问Ingester读取内存热日志，读取磁盘Chunk冷日志
4. 解压压缩块、标签过滤、正文正则匹配
5. 结果汇总返回Grafana展示

## 7 架构优势与固有缺陷
### 优势
1. 资源开销低，磁盘占用远小于ES
2. 深度适配Kubernetes容器日志，原生支持标签体系
3. 架构组件解耦，写入、查询可以独立横向扩容
4. 支持日志TTL自动清理，运维成本低

### 架构短板
1. 日志正文没有倒排索引，模糊检索性能较差
2. 标签基数管控不当极易引发标签爆炸，造成索引内存溢出
3. 复杂全文检索场景不适合，需要对接Elasticsearch

## 8 生产环境架构最佳配置
1. Distributor：3副本，保障写入入口高可用
2. Ingester：3副本，StatefulSet挂载NFS‑SC持久化卷
3. Query‑Frontend：2副本
4. Compactor：单实例，后台执行块合并与过期清理
5. 采集端Fluent‑Bit严格管控标签白名单，动态字段写入日志正文
6. 大规模集群前置Kafka，实现日志削峰，多存储后端分流

## 9 后续文档指引
- components.md：各个组件详细参数、资源配置
- deployment.md：三种部署模式落地方案
- storage.md：Chunk存储、索引网关、持久化方案