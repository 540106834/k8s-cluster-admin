# kubernetes‑logging‑deployment 部署文档
## 1 项目概述
该仓库为基于 Helm 构建、适配 Kubernetes‑v1.32 的企业级日志采集平台部署工程；
整体组件：**Fluent‑Bit（DaemonSet 节点采集）+ Loki（日志存储）+ Grafana（日志可视化查询）**，支持离线环境、Harbor私有镜像仓库、GitOps版本管控，可扩展 Kafka 缓冲、Elasticsearch、ClickHouse 多后端存储。

### 整体数据流
容器 stdout/stderr → containerd json‑file 日志文件 → Fluent‑Bit 采集、解析、过滤、脱敏 → Loki持久化存储 → Grafana 日志检索面板

## 2 环境前置基线
1. Kubernetes：v1.32
2. 容器运行时：containerd
3. 存储资源：集群可用 NFS‑StorageClass `nfs‑sc`，为 Loki 提供持久化PVC
4. 镜像仓库：离线 Harbor，所有组件镜像提前同步至私有仓库
5. 包管理工具：Helm3
6. 集群网络：CNI网络插件正常，节点之间网络互通

## 3 目录结构说明
```
kubernetes-logging-deployment/
├── README.md                                      # 日志平台部署说明
├── 01-namespace/                                  # 命名空间资源
│   └── namespace.yaml                             # logging独立命名空间
├── 02-fluent-bit/                                 # 日志采集组件 Fluent‑Bit
│   ├── values.yaml                                # Helm 参数配置
│   ├── config.yaml                                # input/parser/filter/output流水线规则
│   ├── install.sh                                 # 一键部署脚本
│   └── uninstall.sh                               # 卸载清理脚本
├── 03-loki/                                       # Loki日志存储
│   ├── values.yaml                                # Helm‑Loki配置
│   ├── storage.yaml                               # PVC、NFS持久化声明
│   ├── install.sh
│   └── uninstall.sh
├── 04-grafana/                                    # 可视化查询面板
│   ├── datasource.yaml                            # Loki数据源
│   └── dashboard/                                 # 日志监控看板JSON
├── 05-operations/                                 # 运维脚本与故障文档
│   ├── health-check.sh                            # 全组件健康巡检脚本
│   └── troubleshooting.md                         # 线上故障排查手册
└── 06-offline/                                    # 离线镜像迁移方案
    ├── images.txt                                  # 全部组件镜像清单
    └── harbor-sync.sh                              # 批量同步镜像至Harbor脚本
```

## 4 部署顺序
严格遵守下面安装顺序，防止组件依赖异常
1. 创建 logging 命名空间
2. 部署 Fluent‑Bit 采集器
3. 部署 Loki 存储服务
4. 配置 Grafana 数据源、导入日志仪表盘
5. 执行健康校验脚本，验证全链路日志采集
6. 离线环境优先执行镜像同步脚本

## 5 分步部署操作
### 5.1 创建命名空间
```bash
kubectl apply -f 01-namespace/namespace.yaml
```

### 5.2 安装 Fluent‑Bit 日志采集端
```bash
cd 02-fluent-bit
chmod +x install.sh
./install.sh
```
- 以 DaemonSet 运行于所有 Worker 节点
- 自动挂载宿主机容器日志目录、磁盘缓冲目录
- 流水线内置日志解析、k8s元数据注入、无用日志过滤、敏感字段脱敏

### 5.3 部署 Loki 日志存储
```bash
cd 03-loki
chmod +x install.sh
./install.sh
```
- 使用 nfs‑sc 动态供给持久化存储
- Distributor、Ingester、Query‑Frontend、Compactor 多组件高可用部署
- 内置日志TTL过期自动清理策略

### 5.4 Grafana 数据源与看板
1. 配置Loki数据源
```bash
kubectl apply -f 04-grafana/datasource.yaml
```
2. 在Grafana控制台导入 dashboard 目录下的日志查询面板

## 6 离线环境部署流程
1. 编辑 `06-offline/images.txt`，录入所有Fluent‑Bit、Loki、Grafana镜像
2. 执行镜像同步脚本，把公共镜像批量推送至内网Harbor仓库
```bash
cd 06-offline
chmod +x harbor-sync.sh
./harbor-sync.sh
```
3. 修改各个组件 values.yaml，替换镜像地址为内网Harbor地址

## 7 日常运维
### 7.1 健康检查
```bash
cd 05-operations
chmod +x health-check.sh
./health-check.sh
```
巡检内容：Pod运行状态、Fluent‑Bit日志丢弃数量、Loki写入延迟、PVC磁盘使用率、K8s标签基数。

### 7.2 故障排查
查阅 `05‑operations/troubleshooting.md`，覆盖日志采集失败、Loki标签爆炸、磁盘爆满、查询超时、日志丢失等常见故障。

## 8 卸载流程
卸载顺序：Grafana → Loki → Fluent‑Bit → namespace
```bash
# 卸载采集端
cd 02-fluent-bit && ./uninstall.sh
# 卸载存储
cd 03-loki && ./uninstall.sh
# 删除命名空间
kubectl delete ns logging
```

## 9 生产环境最佳实践
1. 所有yaml、流水线配置纳入Git仓库管理，使用ArgoCD实现GitOps持续部署
2. 严格管控Loki标签，禁止traceId、请求ID等动态随机值作为标签，规避标签基数爆炸
3. Fluent‑Bit开启宿主机磁盘缓冲，网络故障阶段缓存日志，防止日志丢失
4. 区分dev/uat/prod三套环境，配置差异化日志TTL保存周期
5. 开启磁盘水位告警，监控日志磁盘占用、日志丢弃指标、查询超时指标
6. 审计日志可扩展Kafka中间缓冲层，分流写入ClickHouse用于日志统计分析

## 10 后续扩展方向
- 接入Kafka实现日志削峰、异步缓冲
- 对接Elasticsearch用于全文关键字检索
- ClickHouse实现访问日志、审计日志大盘统计
- 定时备份Loki快照、Grafana面板、告警规则