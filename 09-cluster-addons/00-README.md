# 00-README.md

# Kubernetes Add-ons 附加组件体系总览

## 一、文档说明
本目录存放云原生集群**生产必备附加组件（Add-ons）**，不属于K8s原生控制平面核心组件，但是构建完整平台工程、可观测、安全、存储、流量治理能力的基础设施底座。
所有组件遵循标准K8s资源模型，通过Deployment/DaemonSet/StatefulSet部署，依托CRD扩展集群能力。

## 二、组件分层划分
### 1. 网络基础层
- CoreDNS：集群DNS与服务发现底座，所有Pod域名解析依赖

### 2. 流量接入层
- Ingress Controller：集群统一七层流量入口，TLS终止、域名路由

### 3. 证书安全层
- cert-manager：证书自动化签发、轮换，管理集群内部TLS证书生命周期

### 4. 持久化存储层
- CSI Driver：容器存储标准接口，PV/PVC动态存储供给
- Snapshot Controller：卷快照、备份与数据恢复能力

### 5. 可观测体系
- Metrics Server：基础资源指标，HPA数据源
- Monitoring Stack（Prometheus Operator）：指标采集、告警、监控大盘
- Logging Stack（FluentBit/Loki/ES）：集群日志采集、存储、检索

### 6. 集群策略安全层
- Kyverno / OPA Gatekeeper：准入策略，资源校验、安全基线、规范管控

### 7. 弹性伸缩组件
- HPA/VPA/Cluster Autoscaler/Karpenter：Pod水平、垂直、节点自动扩缩容

### 8. 运维可视化工具
- Dashboard、Lens、kubectl扩展工具，集群可视化操作入口

### 9. 生命周期管理
- Add-on 升级、版本兼容、灰度变更、故障回滚标准化流程

## 三、目录清单
```
01-core-dns.md                   # CoreDNS 服务发现、解析流程与配置管理
02-metrics-server.md             # Metrics Server 资源指标采集与 HPA 数据来源
03-ingress-controller.md         # Ingress Controller 部署、路由、TLS 与流量入口
04-cert-manager.md               # 自动证书管理、ACME、Certificate 生命周期
05-csi-driver.md                 # CSI 驱动、云存储插件与动态供给
06-snapshot-controller.md        # VolumeSnapshot 快照管理与恢复流程
07-monitoring-stack.md           # Prometheus Operator、ServiceMonitor、Alertmanager
08-logging-stack.md              # Fluent Bit、Loki、Elasticsearch 日志体系
09-policy-engine.md              # Kyverno、OPA Gatekeeper 策略管理
10-autoscaling-components.md     # HPA、VPA、Cluster Autoscaler、Karpenter
11-dashboard-and-tools.md        # Dashboard、Lens、kubectl 插件等管理工具
12-addon-upgrade-management.md   # Add-on 生命周期、升级、兼容性管理
```

## 四、生产落地规范
1. **部署规范**
所有Add-ons独立命名空间管理；资源配额、探针、PodDisruptionBudget必须配置；尽量使用Helm标准化部署。
2. **版本兼容**
Add-ons版本必须匹配Kubernetes Minor版本，升级集群前先校验插件兼容矩阵。
3. **高可用规范**
核心组件CoreDNS、Ingress、Prometheus、cert-manager多副本部署，避免单点故障。
4. **权限最小化**
使用专用ServiceAccount、RBAC，禁止集群管理员权限；区分读写权限。
5. **监控告警**
所有Add-ons纳入监控体系，采集自身运行指标，配置副本缺失、错误率、资源压力告警。
6. **变更流程**
Add-ons升级执行灰度发布，预留回滚方案；生产禁止直接暴力删除组件资源。

## 五、组件依赖关系
1. CoreDNS为最底层基础组件，所有业务与其他Add-ons强依赖DNS；
2. Metrics Server是HPA前置依赖；
3. CSI驱动是有状态应用持久化存储依赖，Snapshot Controller依赖CSI快照能力；
4. Prometheus Operator可通过ServiceMonitor采集其余所有组件监控指标；
5. cert-manager常与Ingress配合，自动管理网关HTTPS证书；
6. 策略引擎（Kyverno/OPA）建议集群初始化阶段优先部署，提前建立安全基线。

如果你需要，我可以继续依次产出 `01-core-dns.md`，保持整套文档统一风格、生产SRE视角。