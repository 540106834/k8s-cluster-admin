# kubernetes-platform-design/04-application-delivery.md
## 文档元信息
- 模块：标准化应用交付体系
- 优先级：★★★★★ 业务落地核心标准
- 依赖文档：00-platform-overview.md、02-namespace-resource-governance.md、03-image-supply-chain.md
- 关联模块：05-network-security、06-storage-platform、07-observability、08-secret-management、14-platform-engineering
- 适用角色：平台SRE、应用架构师、CI/CD工程师、研发、GitOps运维

## 1. 模块定位与核心目标
### 1.1 定位
归属平台四层「应用业务运行层」，定义全平台统一应用交付标准，统一所有业务无状态/有状态/定时任务的资源模型、发布流程、流量暴露、配置伸缩规范。
上层对接GitOps自助交付平台，下层依赖租户隔离、镜像供应链、网络、存储、密钥能力，是研发接触最频繁的标准层。

### 1.2 核心目标
1. 统一应用资源模板，消除业务自定义差异化YAML，降低学习与维护成本
2. 标准化多发布策略，灰度/蓝绿/滚动/金丝雀全流程可控、可回滚
3. 配置、密钥、流量、存储、弹性伸缩统一规范，禁止业务非标写法
4. 全链路绑定标签规范，实现资源计量、观测、权限、审计统一筛选
5. 交付流程强约束：所有资源由Git管理，禁止临时kubectl直改集群
6. 与镜像供应链联动，仅允许合规镜像部署，阻断非法镜像流入业务Pod

### 1.3 解决业务痛点
- 各业务YAML写法不统一，运维排查、平台改造成本极高
- 发布方式混乱，部分业务直接滚动重启无灰度，线上故障无法快速止损
- 配置硬编码写死在Deployment，变更必须重新构建镜像
- 密钥明文存放、混写在ConfigMap，敏感数据泄露风险高
- 无统一弹性伸缩标准，流量突增导致服务雪崩
- 流量暴露规则杂乱，Ingress域名、证书、限流无统一管控

## 2. 统一应用资源分层模型
所有业务应用资源分为四层，严格分层管理，禁止层级混用
1. **工作负载层**：Deployment/StatefulSet/DaemonSet/CronJob（业务运行主体）
2. **流量网关层**：Service、Ingress、Middleware网关（内外流量接入）
3. **配置密钥层**：ConfigMap、Secret、ExternalSecret（静态配置与敏感数据）
4. **持久化存储层**：PVC、Snapshot（数据持久化，对接06-storage-platform）

### 2.1 强制全局标签规范（所有资源必带）
```yaml
labels:
  platform.company.com/env: prod
  platform.company.com/team: pay
  platform.company.com/app: order-service
  platform.company.com/owner: dev@pay-team.com
  platform.company.com/version: 8a3f2d1 # 镜像commit sha
```
Annotation扩展：发布工单ID、灰度比例、资源创建时间、资源负责人。

## 3. 标准化工作负载规范
### 3.1 负载选型强制规则
| 负载类型 | 使用场景 | 强制约束 |
|---|---|---|
| Deployment | 无状态微服务、API服务 | 默认滚动更新；生产必须配置HPA |
| StatefulSet | MySQL、Redis、MQ等有状态中间件 | 必须绑定PVC，禁止临时存储；固定网络标识 |
| DaemonSet | 节点采集、日志、网络插件 | 仅限平台运维组件，业务禁止使用 |
| CronJob | 定时任务、数据同步脚本 | 并发策略Forbid；超时自动终止；保留历史Job记录10条 |

### 3.2 Pod通用标准化配置（所有Pod强制）
1. 资源约束：必须配置`requests/limits`，由LimitRange兜底校验（02-namespace-resource-governance）
2. 安全上下文：默认非root用户，禁止特权容器、hostNetwork/hostPID（10-workload-security）
3. 探针三要素：`livenessProbe/readinessProbe/startupProbe`，无探针直接拦截发布
4. 容器生命周期：preStop优雅关闭，预留30s等待流量排空
5. 镜像规范：仅允许平台Harbor镜像，Tag固定Git Commit SHA，禁用latest（03-image-supply-chain）
6. 日志标准：容器输出stdout/stderr，禁止落地宿主机本地文件

### 3.3 发布策略标准化（统一4种发布模式，平台模板封装）
#### 1）滚动发布（默认Dev/Test）
- maxSurge: 25%，maxUnavailable: 0
- 零停机，适用于无状态兼容版本迭代

#### 2）灰度金丝雀（Staging/Prod推荐）
- 基于权重分流，先发布10% Pod验证，无问题再全量放量
- 流量拆分依赖Service+Ingress路由权重，无需修改业务代码
- 支持一键回滚，保留灰度记录审计

#### 3）蓝绿发布（核心支付、订单等强一致性业务）
- 两套完整副本集切换，切换瞬间完成，无部分实例新旧版本共存
- 双倍资源消耗，仅核心业务允许使用，需审批扩容配额

#### 4）定时分批发布（大数据、离线任务）
- 分批次按节点池灰度，避免批量重启抢占资源
- 适配夜间低峰发布，降低业务影响

### 3.4 发布流程强制约束
1. 所有版本变更提交Git仓库，ArgoCD自动同步（GitOps，14-platform-engineering）
2. 发布前自动执行前置校验：镜像漏洞检查、资源配额校验、网络策略校验
3. 发布过程全量指标监控：错误率、延迟、CPU内存、Pod就绪状态
4. 内置熔断规则：5xx错误率>5%自动暂停发布，触发告警

## 4. 流量暴露标准：Service + Ingress
### 4.1 Service统一规范
1. **ClusterIP（默认）**：服务内部调用，禁止业务直接使用NodePort
2. **NodePort**：仅平台运维组件使用，业务禁止申请
3. **LoadBalancer**：生产公网业务统一通过Ingress转发，不直接创建LB类型Service
4. Service端口规范：业务http统一8080，grpc 9090，监控metrics 9091，全局统一端口标准

### 4.2 Ingress南北向流量管控（联动05-network-security）
1. 域名规范：`{app}.{env}.company.com`，自动签发HTTPS证书（cert-manager 11-addon-management）
2. 强制规则：所有生产Ingress必须开启TLS 1.2+，禁止HTTP明文访问
3. 限流、熔断、IP黑白名单统一在Ingress配置，业务无需自建网关
4. 路由隔离：不同团队域名分组管理，禁止跨团队域名复用
5. 路径重写、跨域配置统一封装为Ingress模板，业务仅填写业务参数

## 5. 配置与敏感数据管理（联动08-secret-management）
### 5.1 ConfigMap 非敏感配置
1. 存放：开关、超时、静态地址、日志级别等非涉密文本
2. 禁止存放数据库账号、密钥、token、证书
3. 挂载方式：volume挂载为文件，不使用环境变量注入，支持热更新

### 5.2 Secret / ExternalSecret 敏感数据
1. 短密钥、数据库密码、API Token、证书统一使用ExternalSecret对接Vault
2. 禁止原生Secret硬编码明文，禁止写入Git仓库
3. 密钥自动轮换，Pod自动重载密钥无需重启
4. 细粒度权限：业务仅能读取自身Namespace密钥，无法跨团队访问

### 5.3 配置分层原则
- 全局公共配置：平台统一全局ConfigMap，所有Namespace只读挂载
- 团队公共配置：团队共享ConfigMap，同Namespace多应用复用
- 应用私有配置：单个应用独立ConfigMap，隔离变更影响范围

## 6. 弹性伸缩体系标准
### 6.1 HPA CPU/内存基础伸缩（所有生产应用强制）
全局模板阈值：
- CPU阈值70%，内存阈值80%
- 最小副本数2，最大副本数由ResourceQuota上限约束
- 冷却周期：扩容3min，缩容5min，防止抖动

### 6.2 自定义指标HPA（微服务高并发场景）
支持QPS、队列长度、消息堆积等业务自定义指标，对接Prometheus适配器
### 6.3 集群自动伸缩（CAS）
节点池自动扩容配合HPA，Pod无法调度时自动新增节点，联动09-compute-resource-management

## 7. 存储绑定规范（联动06-storage-platform）
1. 无状态应用：仅使用emptyDir临时存储，重启数据丢失
2. 有状态中间件：必须绑定PVC，指定对应环境StorageClass
3. 数据备份：生产PVC自动开启定时快照，保留7天回滚点
4. 禁止宿主机目录挂载hostPath，统一CSI持久化存储

## 8. 可观测标准化埋点（联动07-observability-platform）
所有应用交付必须内置统一观测能力，准入控制器校验缺失则拦截：
1. Metrics：暴露/metrics端口，Prometheus自动采集
2. Logging：标准JSON日志输出，携带app/team/env标签
3. Tracing：自动注入opentelemetry环境变量，链路上报平台Jaeger
4. 告警阈值模板统一预置，业务仅需调整告警等级

## 9. 全流程交付流水线（GitOps闭环）
1. 代码提交 → CI构建镜像+漏洞扫描 → 推送Harbor（03-image-supply-chain）
2. 更新GitOps仓库YAML，修改镜像Tag、副本数、配置参数
3. ArgoCD检测Git变更，自动同步至对应Namespace
4. 执行发布策略，实时监控发布健康度指标
5. 发布完成生成审计记录，同步观测大盘更新

## 10. 安全约束与准入校验规则
OPA/Admission Controller拦截以下违规交付：
1. 镜像来源非企业Harbor、使用latest标签、高危漏洞镜像
2. Pod未配置requests/limits、无健康探针、特权容器
3. 生产环境Ingress未开启HTTPS明文流量
4. 敏感密码存放至ConfigMap，未使用ExternalSecret
5. 资源超出Namespace ResourceQuota上限
6. 缺少标准env/team/app标签

## 11. 落地强制禁忌规范
1. 禁止直接kubectl create/apply裸操作集群，所有资源必须Git托管
2. 禁止业务使用NodePort、LoadBalancer直曝公网，统一Ingress网关
3. 禁止密钥存放ConfigMap、Git仓库明文密钥
4. 禁止生产无HPA自动伸缩，单副本业务必须审批
5. 禁止hostPath、hostNetwork、特权容器业务负载
6. 禁止自定义发布脚本绕过平台GitOps流水线发布
7. 禁止硬编码镜像地址、浮动latest标签

## 12. 跨模块协作边界
1. 02-namespace-resource-governance：所有应用资源隔离在专属Namespace，受Quota/LimitRange管控
2. 03-image-supply-chain：交付流程校验镜像合规性，阻断未扫描高危镜像
3. 05-network-security：应用Pod网络访问受Namespace NetworkPolicy管控，Ingress统一流量安全策略
4. 06-storage-platform：应用PVC统一使用平台StorageClass，快照备份标准化
5. 07-observability：交付资源自动注入采集标签，统一监控日志链路
6. 08-secret-management：应用敏感配置由ExternalSecret对接Vault统一托管
7. 14-platform-engineering：平台提供标准化应用Helm模板、自助发布工单、GitOps仓库管理
8. 15-compliance-audit：所有发布变更、资源更新操作全量审计日志留存180天