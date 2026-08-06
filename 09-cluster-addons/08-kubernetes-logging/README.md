# Kubernetes‑Logging 日志平台 · README.md
## 1 平台概述
本项目为企业级 Kubernetes 集群日志完整解决方案，负责容器标准输出、容器运行时日志、节点系统日志、集群审计日志的采集、过滤、存储、检索、可视化与生命周期管理。
整套架构面向生产SRE运维标准，支持离线部署、资源管控、数据加密、敏感数据脱敏、高可用容灾、自动过期清理、平台自监控，适配基于NFS‑StorageClass持久化、GitOps配置管理的云原生环境。

## 2 技术栈基线
- 集群版本：Kubernetes v1.32
- 采集器：Vector（优先）/ Fluent‑Bit
- 存储后端：Loki（轻量化）/ Elasticsearch（全文检索场景）
- 可视化入口：Grafana
- 部署方式：DaemonSet节点侧采集、StatefulSet有状态存储组件、Helm Chart离线安装、MinIO托管安装包、Git维护全部配置文件
- 运行时：containerd

## 3 目录结构说明
```
kubernetes-logging/
│
├── README.md                                      # Kubernetes日志平台设计总览
│
├── 01-architecture/                               # 日志平台整体架构设计
│   ├── overview.md                                # 日志平台目标、范围、整体架构
│   ├── architecture-design.md                     # 采集、存储、查询整体架构
│   ├── component-selection.md                     # Fluent Bit/Vector、ES/Loki等组件选型
│   └── deployment-model.md                        # DaemonSet、集中式、混合部署模型
│
├── 02-log-flow/                                   # Kubernetes日志数据流转过程
│   ├── kubernetes-log-lifecycle.md                # Pod日志从产生到查询的完整生命周期
│   ├── container-runtime-log.md                   # containerd/docker日志机制和存储路径
│   └── collector-pipeline.md                      # Input、Parser、Filter、Buffer、Output流程
│
├── 03-component-design/                            # 日志平台组件设计
│   ├── collector-design.md                        # 日志采集器设计(DaemonSet、资源、配置)
│   ├── storage-design.md                          # 日志存储设计(索引、分片、副本)
│   ├── query-design.md                            # 日志查询和检索设计
│   └── visualization-design.md                    # Kibana/Grafana日志展示设计
│
├── 04-storage-management/                          # 日志存储生命周期管理
│   ├── retention-policy.md                        # 日志保存周期和清理策略
│   ├── capacity-planning.md                       # 日志容量评估和资源规划
│   ├── index-management.md                        # Index、Shard、Lifecycle管理
│   └── backup-restore.md                          # 日志备份恢复方案
│
├── 05-platform-implementations/                  # 日志平台实现方案
│   ├── overview.md                              # Loki、ELK、ClickHouse方案对比
│   │
│   ├── loki/
│   │   ├── architecture.md                      # Loki整体架构
│   │   ├── components.md                        # Distributor、Ingester、Querier等组件
│   │   ├── deployment.md                        # Single Binary / Simple Scalable / Distributed
│   │   ├── storage.md                           # TSDB、Object Storage、Index Gateway
│   │   ├── scaling.md                           # 横向扩容设计
│   │   └── best-practices.md                    # 标签设计、查询优化
│   │
│   ├── clickhouse/
│   │   ├── architecture.md                      # ClickHouse日志架构
│   │   ├── components.md                        # Fluent Bit、Kafka、Vector、ClickHouse
│   │   ├── deployment.md                        # 单节点、Cluster部署
│   │   ├── table-design.md                      # MergeTree、Partition、Order By
│   │   ├── scaling.md                           # Shard、Replica扩容
│   │   └── best-practices.md                    # TTL、Compression、Materialized View
│   │
│   └── elk/
│       ├── architecture.md                      # ELK整体架构
│       ├── components.md                        # Beats、Logstash、ES、Kibana
│       ├── deployment.md                        # 单节点、多节点部署
│       ├── index-design.md                      # Index、Template、ILM
│       ├── scaling.md                           # Hot/Warm/Cold架构
│       └── best-practices.md                    # Shard、副本、Mapping优化
│
├── 06-security-design/                             # 日志安全设计
│   ├── rbac-design.md                             # Kubernetes日志访问权限设计
│   ├── tls-design.md                              # 日志传输加密设计
│   ├── sensitive-log-management.md                # 密码Token等敏感信息保护
│   └── audit-logging.md                           # Kubernetes审计日志设计
│
├── 07-operation-management/                        # 日常运维管理
│   ├── monitoring.md                              # 日志平台自身监控指标
│   ├── troubleshooting.md                         # 常见故障排查流程
│   ├── upgrade-strategy.md                        # 组件升级和版本管理策略
│   └── operation-guide.md                         # 日常维护规范
│
└── docs/                                           # 辅助文档
    ├── glossary.md                                # 日志平台相关术语
    └── references.md                              # 官方文档和参考资料
```

## 4 平台核心能力
1. **多源日志采集**：容器stdout/stderr、容器运行时日志、节点内核日志、kube‑audit审计日志、业务内部文件日志
2. **管道预处理**：日志解析、字段提取、标签注入、日志过滤、敏感字段脱敏、格式转换、缓冲区背压
3. **分层存储**：冷热数据分离、日志过期自动清理、索引分片管理、快照备份
4. **检索可视化**：Grafana日志查询面板、容器/命名空间/工作负载维度筛选、链路日志关联
5. **传输安全**：采集端‑存储端TLS加密、RBAC访问权限隔离、禁止明文密钥与令牌落地日志
6. **平台可观测**：采集器丢弃条数、推送延迟、存储写入速率、磁盘使用率等指标接入Prometheus告警

## 5 环境约束与生产规范
1. 采集组件固定DaemonSet部署，每节点一个采集Agent，避免单点采集故障
2. Agent资源做严格QoS限制，防止日志突增抢占节点CPU、内存
3. 所有日志配置交由Git管理，通过GitOps下发，禁止Pod内本地修改配置
4. 存储组件使用独立StorageClass(nfs‑sc)完成持久化，数据盘与系统盘隔离
5. 制定日志保存周期，非核心业务日志短期留存，审计日志长期归档

## 6 文档阅读顺序
1. 01‑architecture → 架构与组件选型
2. 02‑log‑flow → 熟悉日志完整数据流
3. 03‑component‑design → 各组件部署配置方案
4. 04‑storage‑management → 存储生命周期管理
5. 05‑reliability‑design → 稳定性、故障场景、扩容方案
6. 06‑security‑design → 权限、加密、脱敏、审计日志
7. 07‑operation‑management → 上线后全套运维手册

## 7 风险清单
- 节点磁盘爆满：容器标准输出日志驱动轮询策略不合理
- 日志丢失：Agent缓冲区溢出、网络抖动、后端存储写入阻塞
- 敏感数据泄露：业务代码打印账号、密钥、Token
- 查询缓慢：索引分片不合理、日志标签泛滥、未做字段过滤

## 8 交付产物
- 全套yaml/helm‑values配置
- 部署SOP、故障排查手册、容量计算公式、告警规则、运维巡检清单