# docs/01-overview/01-architecture.md
# kube-prometheus-stack 企业监控平台整体架构文档
## 文档基础信息
- 集群K8s版本：v1.32
- Chart版本：kube-prometheus-stack-65.1.0
- 存储介质：NFS StorageClass `nfs-sc`
- 交付模式：离线MinIO托管Helm Chart包，Git管控配置与values
- 文档等级：★★★★★ 核心顶层架构文档

## 一、架构整体定位
本平台基于 **Prometheus Operator + kube-prometheus-stack Helm Chart** 构建企业级Kubernetes全栈可观测平台，统一承载集群基础设施监控、容器业务监控、中间件指标采集、多维度告警、可视化大盘能力；采用CRD声明式管理监控生命周期，完全贴合K8s原生管控模型，适配离线私有化部署，数据持久化依托集群NFS存储，支持后期无缝扩展Thanos实现长期指标存储。

### 核心设计目标
1. 原生K8s CRD驱动，所有监控资源Git化版本管控，满足GitOps交付标准
2. 全组件数据持久化，依托NFS统一存储层，保障监控数据不随Pod销毁丢失
3. 分层解耦架构：采集层、存储层、计算规则层、告警层、可视化层完全隔离
4. 离线交付兼容：Chart包、镜像、配置文件统一归档至MinIO对象存储分发
5. 可横向扩展：支持新增业务Exporter、多集群Thanos联邦、自定义告警大盘
6. 完整安全边界：RBAC鉴权、NetworkPolicy访问控制、TLS加密Ingress、Secret敏感配置隔离

## 二、平台全局分层架构（五层模型）
### 2.1 底层：Kubernetes资源底座（依赖层）
集群基础资源，为监控平台提供运行环境
1. 计算资源：集群Node节点、Namespace（专用监控命名空间 `monitoring`）
2. 存储资源：NFS StorageClass `nfs-sc`，提供PVC持久化卷，承载Prometheus TSDB、Grafana面板配置、Alertmanager告警状态
3. 镜像仓库：私有Harbor，离线导入kube-prometheus-stack全组件镜像
4. 离线分发层：MinIO对象存储，存储Helm Chart二进制包、离线脚本、配置模板
5. 配置仓库：Git仓库，统一管理values.yaml、ServiceMonitor、PrometheusRule、Dashboard Json、网络安全策略

### 2.2 管控层：Prometheus Operator（控制平面核心）
Operator是整个监控平台的控制器中枢，Chart自动部署，核心职责：
1. 识别集群5类监控CRD资源，自动协调创建对应工作负载：
    - `Prometheus`：定义Prometheus服务实例（单副本/高可用集群）
    - `Alertmanager`：定义告警管理器集群实例
    - `ServiceMonitor`：自动发现Service后端Pod指标端点
    - `PodMonitor`：直接发现裸Pod指标端点（无Service场景）
    - `PrometheusRule`：预加载告警规则、预计算Recording规则
2. 动态生成Prometheus/Alertmanager配置文件，热重载配置无需重启Pod
3. 自动管理RBAC权限、Service、Headless Service、PVC持久化存储
4. 监控组件故障自愈，Pod异常自动重建，绑定原有NFS存储恢复数据
5. 对接kube-state-metrics，采集K8s原生资源元数据（Deployment/Pod/Node/PVC状态）

### 2.3 采集层：指标数据收集组件（数据源层）
负责从集群、节点、业务容器拉取metrics指标，分三大采集源
#### 2.3.1 基础设施采集组件（Chart内置）
1. **kube-state-metrics**：K8s资源元指标（副本数、Pod状态、PVC容量、事件、HPA伸缩状态）
2. **node-exporter**：宿主机硬件指标（CPU、内存、磁盘IO、网络、磁盘使用率、负载）
3. **cadvisor（内置kubelet集成）**：容器资源指标（单容器CPU/内存/磁盘读写、OOM记录）

#### 2.3.2 业务自定义采集（ServiceMonitor/PodMonitor驱动）
1. 中间件Exporter：mysql-exporter、redis-exporter、kafka-exporter、elasticsearch-exporter
2. 业务应用内置metrics：Java/Python/Go应用暴露 `/metrics` 端点
3. 第三方硬件/系统自定义Exporter（扩展层自定义开发接入）

#### 采集调度逻辑
Operator读取ServiceMonitor/PodMonitor标签匹配规则，动态生成Prometheus scrape任务，周期性拉取指标，统一写入TSDB存储。

### 2.4 存储&规则计算层：Prometheus 时序数据库
平台核心时序存储，基于TSDB存储所有采集指标，NFS持久化PVC挂载数据目录
1. **指标存储**：按配置保留周期（retention）存储时序样本，支持分片压缩、块存储
2. **规则引擎**
    - RecordingRule：预聚合高频查询指标（集群总QPS、节点平均负载），降低查询压力
    - AlertingRule：定义阈值告警规则，匹配指标异常后推送告警至Alertmanager
3. **高可用模式**：支持多副本Prometheus集群，共享NFS存储或远端读写分离（后期对接Thanos）
4. 自监控：内置采集自身运行指标，监控Prometheus抓取延迟、存储块写入、内存占用、目标实例状态

### 2.5 告警处理层：Alertmanager 告警收敛分发
独立组件，接收Prometheus推送的告警事件，做二次处理
1. 告警分组、路由分流：按业务、环境、组件分发至不同接收渠道
2. 告警降噪：重复告警抑制、静默窗口、告警分组等待
3. 多渠道通知：钉钉/企业微信/邮件/短信/WEBHOOK
4. 持久化告警状态：NFS存储告警静默、抑制配置，Pod重建不丢失告警策略

### 2.6 可视化展示层：Grafana
指标可视化终端，对接Prometheus数据源，承载大盘展示
1. 内置K8s集群、Node、容器通用Dashboard模板
2. 支持导入自定义业务大盘（Git统一托管Json面板）
3. 多租户权限隔离：RBAC细分只读/编辑/管理员面板权限
4. 持久化存储：NFS保存面板配置、数据源、用户账号、告警面板快照

## 三、CRD资源与组件数据流完整链路
```
Git仓库(配置) → Helm(MinIO离线Chart) → Prometheus Operator(管控层)
    ↓
┌─────────────────────────────────────────────────────────┐
│ CRD资源：ServiceMonitor / PodMonitor / PrometheusRule   │
└───────────────────┬─────────────────────────────────────┘
                    ↓
指标采集源(node-exporter/kube-state-metrics/业务Pod) → Prometheus TSDB(NFS持久化)
                    ↓
        ┌───────────┴───────────┐
        ↓                       ↓
PrometheusRule规则计算      Grafana 查询时序指标可视化
        ↓
Alertmanager（分组/静默/路由）→ 告警推送至企业微信/钉钉
```

## 四、组件依赖拓扑关系
1. **强制前置依赖**
    - K8s v1.32集群、可用NFS StorageClass `nfs-sc`
    - 私有Harbor镜像仓库（离线组件镜像）
    - MinIO离线Chart存储（kube-prometheus-stack-65.1.0压缩包）
    - Git配置仓库（所有监控CRD、values、大盘配置）
2. **组件依赖顺序**
    1. Prometheus Operator（控制器，优先启动）
    2. kube-state-metrics / node-exporter（基础设施采集）
    3. Prometheus实例（依赖Operator、PVC存储、采集Exporter）
    4. Alertmanager（依赖Prometheus推送告警）
    5. Grafana（依赖Prometheus数据源）
3. **扩展依赖（可选）**
    - Thanos：依赖Prometheus远端存储对象存储MinIO，实现长期指标归档
    - 自定义Exporter：依赖ServiceMonitor/PodMonitor配置自动发现

## 五、存储分层设计（对接03-storage/存储模块）
全平台所有有状态组件统一使用集群 `nfs-sc` 持久化PVC，区分三类存储用途：
1. Prometheus TSDB存储：时序指标原始数据（大容量核心存储）
2. Alertmanager存储：告警静默、抑制状态、通知历史
3. Grafana存储：面板配置、用户权限、数据源配置
> 详细容量规划、数据保留策略、NFS性能调优参考 03-storage/01-storage-design.md / 03-storage/02-data-retention.md

## 六、离线部署架构链路（适配MinIO Chart仓库）
1. 离线前置：Chart二进制包 `kube-prometheus-stack-65.1.0.tgz` 上传至MinIO桶
2. Git仓库存储自定义values.yaml、CRD资源清单
3. 部署流程：Helm客户端从MinIO拉取Chart包，结合Git values渲染资源，下发至v1.32集群
4. 镜像供给：安装时从私有Harbor拉取所有组件镜像，无需外网访问

## 七、安全架构分层（对接07-security安全模块）
1. **权限层 RBAC**
    - Operator绑定集群级权限，允许读取全Namespace资源
    - Grafana细分命名空间只读权限，业务人员隔离访问范围
2. **网络层 NetworkPolicy**
    - 管控组件内部互通，外部禁止直接访问Prometheus/Alertmanager/Grafana端口
    - 仅允许Ingress网关七层流量接入可视化页面
3. **接入层 TLS Ingress**
    Grafana、Prometheus Web UI通过HTTPS域名对外暴露，证书由Secret管理
4. **敏感配置 Secret**
    告警WEBHOOK密钥、数据库账号、Grafana管理员密码、MinIO/Harbor凭证统一存入Secret，禁止明文写values

## 八、平台扩展架构（对接08-extension扩展模块）
1. **长期存储扩展：Thanos**
    Prometheus本地NFS短期存储 + MinIO对象存储长期归档，全局统一查询网关
2. **业务采集扩展：自定义Exporter**
    基于PodMonitor/ServiceMonitor接入自研业务指标采集程序
3. **可视化扩展：自定义Dashboard**
    Git统一管理业务大盘Json模板，部署时自动导入Grafana
4. **集群扩展：多集群联邦**
    多套K8s集群Prometheus数据聚合至中心Thanos查询节点

## 九、架构约束与版本兼容说明
1. K8s集群版本锁定v1.32，Chart固定版本65.1.0，禁止跨大版本随意升级
2. 存储强制使用集群统一NFS StorageClass `nfs-sc`，不支持本地hostPath临时存储生产使用
3. 所有监控资源强制Git托管，禁止集群内直接kubectl edit修改资源（破坏GitOps一致性）
4. 离线环境依赖MinIO存放Chart包，无外网Chart源访问能力
5. 生产Prometheus开启高可用双副本，避免单实例故障丢失监控采集能力

## 十、关联文档索引
1. 同目录：02-component-overview.md 各组件详细职责、参数、数据流详解
2. 02-deployment/01-installation.md 离线完整部署流程
3. 03-storage/01-storage-design.md NFS持久化存储详细设计
4. 05-prometheus-operator/ 各CRD资源使用手册
5. 07-security/ 平台RBAC、网络、证书安全规范
6. 08-extension/01-thanos.md 长期存储扩展架构
7. 09-troubleshooting/ 架构相关故障排查指南
8. 10-best-practices/01-resource-planning.md 平台资源容量规划标准