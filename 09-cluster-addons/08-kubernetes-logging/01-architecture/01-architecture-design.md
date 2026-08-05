# architecture‑design.md
## 1 整体架构分层
日志平台采用**五层解耦架构**，自下而上分为数据源层、采集代理层、管道处理层、存储持久层、上层服务层，配套独立的管控层与安全层，实现数据流单向流转、配置统一管控。
```
业务数据源 → 节点采集Agent → 日志处理流水线 → 日志存储引擎 → 检索&可视化
```

### 层级详细说明
1. **数据源层**
集群内所有日志来源，是整个平台的数据入口：
- 容器 stdout/stderr，containerd 生成的容器日志文件
- 节点系统日志：`/var/log/syslog`、kubelet、kube‑proxy 组件日志
- Kubernetes‑apiserver 审计日志
- 业务容器挂载路径下落地的文件日志

2. **采集代理层（Agent层）**
每个工作节点部署1份 Vector DaemonSet 采集程序，负责本机全部日志源读取；
Agent 独立运行、配置资源配额，出现阻塞、崩溃不会干扰节点业务Pod；
具备本地磁盘缓冲区，网络故障、后端存储宕机时缓存日志，避免数据丢失。

3. **管道处理层（Pipeline）**
内置在采集Agent内部，一条标准处理链路：
`Input 日志读取 → Parser 日志解析 → Filter 过滤无用日志 → 字段提取&标签注入 → 敏感数据脱敏 → Buffer本地缓冲 → Output转发至存储组件`

4. **存储持久层**
分为索引存储与日志原始数据存储，当前环境主选用 Loki：
- 原始日志：分块压缩存放，降低磁盘占用
- 索引：标签索引，基于 namespace、pod、workload、ip 快速过滤
- 持久化介质：集群 NFS‑SC StorageClass，为 Loki 组件提供PVC

5. **上层服务层**
- 查询接口：Loki‑Query 接收 Grafana、API 的检索请求
- 可视化：Grafana 日志面板、多维度日志筛选
- 告警：异常错误日志通过 Prometheus 规则触发告警

6. **配置管控层**
- 所有采集规则、解析模板、脱敏规则存放于Git仓库
- Argo‑CD GitOps 同步配置，自动重载Agent配置
- 离线 Helm‑Chart 存放在 MinIO 对象存储

7. **安全底座层**
Agent 和存储组件之间开启 TLS 传输加密；
RBAC 管控日志查看权限；流水线完成手机号、密钥、token自动脱敏。

## 2 完整数据流链路
### 2.1 容器日志生成流程
1. 业务程序打印标准输出
2. containerd 将 stdout/stderr 重定向至节点宿主机日志文件
3. Vector‑Agent 通过文件监听读取日志源

### 2.2 节点侧处理
1. Input 模块监听日志文件、审计日志socket
2. Parser 按照容器运行时日志格式拆分时间戳、容器名称、命名空间、日志正文
3. 注入K8s元数据标签：ns、pod‑name、deployment、node‑name
4. 过滤器丢弃垃圾日志、健康检查访问日志
5. 正则匹配敏感字段进行掩码脱敏
6. 缓冲区缓存日志，等待后端连接正常后批量推送

### 2.3 远端存储写入
1. Agent 通过TLS协议推送日志至Loki‑Distributor
2. Distributor 接收、校验、根据标签哈希分片
3. 日志压缩之后写入Chunk块存储，索引存入数据库
4. 后台定时执行过期清理，按照留存周期删除老旧日志

### 2.4 用户查询链路
1. 用户在 Grafana 输入检索条件，指定命名空间、Pod、日志关键词
2. Grafana 调用 Loki‑Query 接口
3. Query 组件查询标签索引，定位对应的日志块
4. 读取压缩Chunk、解压、返回结构化日志结果

## 3 网络拓扑结构
1. DaemonSet 采集Agent运行于全部集群节点，仅在集群内网通信
2. Loki 组件（Distributor、Ingester、Query）部署独立命名空间
3. Agent → Loki 流量走集群Service内网，开启TLS加密
4. Grafana 对接Loki数据源，对外经由Ingress提供访问入口
5. 日志组件禁止暴露公网，所有访问经由集群内网网关

## 4 高可用架构设计
1. Agent：节点DaemonSet，单节点故障仅丢失当前节点采集能力，其余节点不受影响
2. Loki‑Distributor：多副本无状态部署，负责负载均衡接收采集端流量
3. Loki‑Ingester：多副本，日志块多副本写入，避免单实例故障丢失数据
4. 存储层依托NFS共享存储，保障持久化数据多节点可访问

## 5 架构约束与设计取舍
1. Agent 不做重型计算，复杂日志解析、转换前置在节点侧完成，减轻存储组件压力
2. 开启本地磁盘缓冲，优先保障日志不丢失，其次控制推送延迟
3. 元数据标签克制添加，标签过多会造成Loki索引膨胀、查询变慢
4. 配置全部交由Git管理，禁止手动修改Agent运行时配置

## 6 后续关联文档
- component‑selection.md：采集器、存储、可视化组件对比选型
- deployment‑model.md：DaemonSet、集中式、混合部署模式对比
- kubernetes‑log‑lifecycle.md：日志完整生命周期详解