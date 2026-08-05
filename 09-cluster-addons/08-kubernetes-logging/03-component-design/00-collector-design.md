# collector‑design.md
## 1.环境基线
- Kubernetes v1.32
- 容器运行时：containerd
- 采集组件：Fluent‑Bit
- 消息中间件：Kafka（大型集群异步缓冲）
- 存储后端：Loki / Elasticsearch / ClickHouse
- 配置管理：GitOps + Argo‑CD，配置热加载；离线Chart存放于MinIO
- 部署模式：DaemonSet，仅调度至Worker工作节点

## 2.整体架构设计
### 2.1 组件拓扑
1. DaemonSet 在全部 Worker 节点运行 Fluent‑Bit Pod，一个节点对应一个采集实例
2. Pod 挂载宿主机日志目录、磁盘缓冲目录
3. 节点侧完成日志读取、解析、过滤、元数据注入、脱敏、缓冲
4. 日志输出至 Kafka 集群做削峰缓冲；小规模环境可直连日志存储
5. 所有流水线配置由ArgoCD从Git仓库同步，支持配置热重载，无需重启Pod

### 2.2 命名空间规划
- logging‑agent：存放 Fluent‑Bit DaemonSet、配置ConfigMap
- logging‑kafka：消息缓冲集群
- logging‑storage：Loki、ES、ClickHouse
- logging‑grafana：可视化面板

## 3.DaemonSet 核心调度与亲和性设计
1. 使用 node‑affinity 禁止 Pod 调度至 control‑plane 控制节点
2. 容忍所有普通节点污点，保证每一台Worker节点均可部署采集器
3. 资源配额隔离，设置 requests 与 limits，防止日志洪峰抢占节点业务CPU、内存
```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## 4.宿主机目录挂载清单
|宿主机路径|容器内挂载路径|作用|
|---|---|---|
|/var/log/containers|/var/log/containers|读取containerd容器日志|
|/var/log|/var/log|kubelet、操作系统系统日志|
|/var/lib/fluent‑bit/buffer|/buffer|磁盘持久化缓冲目录，网络故障缓存日志|

> 缓冲目录必须使用宿主机本地磁盘，禁止依赖PVC、NFS；磁盘IO延迟会阻塞日志推送。

## 5.流水线ConfigMap结构拆分
采用多ConfigMap分离配置，方便Git管理：
1. fluent‑bit‑input.conf：各类日志源tail输入配置
2. fluent‑bit‑parser.conf：containerd‑json、Java堆栈、nginx日志解析规则
3. fluent‑bit‑filter.conf：过滤规则、k8s元数据注入、字段修改、敏感信息脱敏
4. fluent‑bit‑output.conf：输出至Kafka或者各类存储后端

## 6.缓冲区架构设计（日志防丢核心）
1. 优先开启内存缓冲，承担日常日志吞吐
2. 当后端网络异常、Kafka堆积、存储宕机，日志自动下沉至宿主机磁盘缓冲
3. 磁盘缓冲设置最大存储空间上限，避免目录占满宿主机磁盘
4. 链路恢复后缓冲区内日志自动按顺序补发
```ini
[SERVICE]
  Mem_Buf_Limit 64M
[INPUT]
  Name tail
  Buffer_Chunk_Size 512k
  Buffer_Max_Size 5M
[BUFFER]
  Type filesystem
  Path /buffer
  Max_Space 10G
```

## 7.输出层架构方案
### 方案A：小规模集群直连模式
Fluent‑Bit通过HTTP插件直接推送日志至存储组件
- 业务容器日志 → Loki
- 需要全文检索日志 → Elasticsearch
- 审计统计日志 → ClickHouse

### 方案B：生产环境Kafka缓冲架构（推荐）
1. 日志按照类型分流至独立Topic
    - container‑log：普通容器业务日志
    - node‑system‑log：kubelet、操作系统日志
    - k8s‑audit‑log：apiserver审计日志
2. Topic分区数量依据集群节点规模、日志吞吐量规划，副本数 ≥2
3. 下游独立消费端消费消息，实现日志多存储分发

## 8.监控指标设计
Fluent‑Bit开启内置Prometheus监控指标，接入集群监控平台，重点观测指标：
- input_records：读取日志总行数
- output_records：成功推送日志条数
- dropped_records：丢弃日志数量（故障告警核心指标）
- buffer‑size：内存缓冲、磁盘缓冲占用大小
- retry_count：后端推送重试次数，用于判断网络或者后端故障

## 9.生产环境硬性约束
1. 采集器禁止运行在控制面节点，减少管控节点资源压力
2. 磁盘缓冲目录使用本地磁盘，禁止远端存储挂载
3. 严格控制Kubernetes标签数量，防止Loki标签基数爆炸
4. 采集流水线全部预处理逻辑放在Agent节点侧，减轻后端存储压力
5. 审计日志使用独立流水线、独立Kafka Topic，不和业务日志混杂
6. 配置由Git统一管控，开启热重载，配置变更不需要重启Fluent‑Bit Pod

## 10.常见架构层面风险与规避
1. **日志轮转丢失**：tail插件开启持久化偏移记录，保存读取点位
2. **缓冲磁盘打满**：配置Max_Space上限，超出之后丢弃早期日志，触发告警
3. **标签泛滥**：只保留namespace、pod、deployment、node等必要索引标签
4. **Kafka消息堆积**：监控分区消费延迟，及时扩容分区数量与消费实例

## 11.后续文档指引
storage‑design.md，Loki、Elasticsearch、ClickHouse存储层架构设计