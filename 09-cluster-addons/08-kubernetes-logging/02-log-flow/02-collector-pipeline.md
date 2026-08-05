# collector‑pipeline.md
## 1 前置环境基线
- Kubernetes‑v1.32、containerd 运行时
- 采集组件：Fluent‑Bit
- 可选缓冲中间件：Kafka
- 后端存储：Loki / Elasticsearch / ClickHouse
- 整体流水线链路：`Input → Parser → Filter → Kubernetes‑Meta → Modify → 脱敏处理 → Buffer → Output`

## 2 Pipeline整体工作流程
Fluent‑Bit 流水线为串行插件执行模式，日志逐条经过各个处理阶段；
大规模集群架构下输出端优先投递 Kafka 做消息削峰，再由消费组件分发至各类存储。
```
Input(文件监听、socket、系统日志)
→ Parser(JSON解析、日志格式拆分)
→ Filter(丢弃无用日志、黑名单过滤)
→ Kubernetes过滤器(注入Pod元数据标签)
→ Modify(新增、删除、重命名字段)
→ 正则脱敏(密钥、手机号、账号掩码)
→ Buffer(内存缓冲 + 磁盘持久化缓冲)
→ Output(推送Kafka / Loki / ES / ClickHouse)
```

## 3 各阶段详细说明
### 3.1 Input 输入插件
负责读取各类日志源，生产环境主要启用三类输入源
1. **tail（容器标准输出日志）**
监听宿主机 `/var/log/containers/*.log`，自动处理日志文件轮转、追踪新日志文件；
配置开启文件监控、保存读取偏移，重启之后不会从头重读日志。
2. **tail（节点组件日志）**
采集 kubelet、kube‑proxy、syslog 节点系统日志。
3. **tcp / unix‑socket（apiserver审计日志）**
接收审计日志socket数据流，独立流水线，不和业务日志混合。

> 配置要点：开启 `mem‑buf‑limit`，防止突发日志占用过高内存。

### 3.2 Parser 日志解析插件
负责解析 containerd 输出的单行JSON日志
原始日志示例：
```json
{"time":"2026-08-05T10:30:00Z","stream":"stdout","log":"request‑info"}
```
解析之后拆分出三个独立字段
- time：日志时间戳
- stream：stdout / stderr
- log：日志正文

同时支持自定义解析规则：Nginx访问日志、Java堆栈、业务结构化日志。

### 3.3 Filter 日志过滤
用于丢弃不需要采集的日志，减轻后端存储压力
常见过滤规则：
1. 丢弃健康检查接口频繁打印的访问日志
2. 过滤DEBUG级别调试日志
3. 丢弃空日志、换行垃圾日志
4. 基于命名空间、Pod标签黑名单过滤测试容器日志

### 3.4 Kubernetes 元数据注入过滤器
Fluent‑Bit kubernetes 插件通过容器ID调用 kube‑apiserver 获取Pod元数据，自动注入标签字段：
- kubernetes.namespace_name
- kubernetes.pod_name
- kubernetes.container_name
- kubernetes.deployment_name
- kubernetes.node_name
- pod 自定义labels

标签是 Loki 进行日志筛选的核心索引字段，需要严格管控标签数量，避免标签基数爆炸。

### 3.5 Modify 字段修改阶段
该阶段完成日志结构二次加工：
- 新增自定义环境标签（env:prod / env:uat / env:dev）
- 删除冗余、无用字段，精简日志结构体
- 字段重命名、字段值替换
- 添加日志采集节点时间戳

### 3.6 敏感数据脱敏
依靠正则插件对日志正文进行掩码处理，规避密钥、账号、手机号、token泄露
脱敏示例规则：
- 手机号：138****0000
- 密钥、Bearer‑Token：***secret***
- 数据库账号密码进行遮蔽

### 3.7 Buffer 缓冲区（故障防丢核心）
分为内存缓冲、磁盘缓冲两层，为生产环境必开配置
1. 内存缓冲区：优先缓存日志，吞吐速度快；
2. 当后端存储不可用、Kafka堆积、网络故障时，日志下沉写入宿主机磁盘缓冲；
3. 磁盘缓冲目录必须挂载宿主机本地磁盘，不依赖容器内部存储；
4. 服务恢复后，缓冲区数据自动补发至后端。

缓冲策略：
- 小规模集群：内存缓冲即可
- 生产集群：强制开启磁盘持久化缓冲

### 3.8 Output 输出插件（多后端分流）
根据集群规模与业务需求选择输出链路
1. **小规模集群：直连存储**
    - Loki：http 输出插件推送日志
    - Elasticsearch：es插件直接写入索引
    - ClickHouse：http接口批量写入
2. **中大型生产集群：优先输出 Kafka**
- 按照日志类型划分Topic：container‑log、node‑syslog、audit‑log
- 利用Kafka实现削峰、异步、多存储分发
- 独立消费端消费Topic，分流至不同存储引擎

## 4 多流水线隔离设计
生产环境建议配置三条互相独立的流水线，日志物理隔离
1. 容器业务日志流水线
2. 节点操作系统、kubelet组件日志流水线
3. apiserver 审计日志专属流水线，独立Topic、独立存储

## 5 Fluent‑Bit 流水线生产最佳实践
1. 解析、过滤、脱敏逻辑全部放在节点Agent侧处理，减轻后端存储计算压力
2. 严格控制K8s标签数量，非必要字段不要添加标签索引
3. 磁盘缓冲目录单独挂载宿主机磁盘，缓冲区磁盘上限做好限制
4. 流水线配置交由Git仓库托管，ArgoCD实现配置热重载，无需重启Pod
5. 不同类型日志使用独立输出Topic，避免审计日志被业务日志污染
6. 开启采集器监控指标，上报Prometheus，监控日志读取条数、丢弃条数、发送延迟

## 6 常见流水线故障点
1. tail插件日志轮转偏移丢失，造成日志漏采
2. 标签数量过多，Loki索引膨胀、查询缓慢
3. 磁盘缓冲目录空间耗尽，日志直接丢弃
4. Kafka分区不足引发消息堆积，阻塞整条流水线
5. 正则脱敏规则编写错误，引发整条日志字段解析失败

## 7 后续文档指引
collector‑design.md 讲解 Fluent‑Bit DaemonSet 部署、资源配置、高级参数