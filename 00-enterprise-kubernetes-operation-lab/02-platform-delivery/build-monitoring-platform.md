# build-monitoring-platform.md
# Prometheus + Grafana 企业级集群监控平台完整部署手册
## 一、文档定位
本文基于 Helm 标准化部署**Prometheus Operator**全栈监控体系，覆盖集群节点、容器Pod、Service、ETCD、Ingress、CSI存储、自定义业务指标采集；包含告警中心AlertManager、持久化存储、大盘模板、持久化、高可用、权限管理、告警通知、故障排查，是企业K8s集群运维观测核心平台。
前置依赖：
build-kubernetes-cluster.md｜集群基础环境就绪
build-storage-platform.md｜监控数据持久化StorageClass
validate-cluster-health.md｜集群交付监控验收标准
下游关联：build-log-platform.md、06-network-debug.md

## 二、整体架构分层
### 2.1 五层监控架构
1. **采集层（Exporter）**
   - node-exporter：宿主机硬件指标（CPU/内存/磁盘/网卡）
   - kube-state-metrics：K8s资源指标（Pod/Deployment/PV/Event）
   - cAdvisor：容器资源使用率（内置kubelet）
   - 组件专用Exporter：etcd-exporter、blackbox-exporter、mysql-exporter、redis-exporter
2. **控制平面（Prometheus Operator）**
   CRD自定义资源：Prometheus、ServiceMonitor、PodMonitor、Alertmanager、AlertRule
3. **存储计算层（Prometheus Server）**
   时序数据库，拉取指标、规则预计算、告警判断，持久化至PVC
4. **可视化层（Grafana）**
   内置集群大盘、自定义业务大盘，支持多数据源、面板告警
5. **告警通知层（AlertManager）**
   告警分组、降噪、抑制、路由分发（钉钉/企业微信/短信/邮件）

### 2.2 资源规划标准
1. 独立命名空间：`monitoring`，隔离监控组件与业务
2. Prometheus：2副本高可用，分片存储防止单点丢失监控数据
3. AlertManager：3副本集群，告警高可用不丢失告警
4. 持久化存储：使用集群StorageClass，监控数据保留15天
5. 资源配额：根据集群规模区分小型/中大型集群配置limits/requests

### 2.3 集群监控覆盖范围
✅ 基础设施：节点CPU、内存、磁盘IO、磁盘使用率、网卡流量、软中断
✅ K8s集群资源：Pod就绪状态、副本数、调度失败、容器OOM、PV/PVC
✅ 控制平面：ETCD读写延迟、apiserver请求耗时、控制器/调度器状态
✅ 网络：Ingress七层QPS、TCP连接、网络策略丢包、CNI隧道流量
✅ 存储：CSI卷IO、磁盘使用率、快照任务状态
✅ 业务自定义指标：应用暴露/metrics业务接口指标

## 三、前置环境校验
1. 集群StorageClass就绪，支持动态PVC供给监控持久化数据
2. 集群网络正常，所有节点9100(node-exporter)端口互通
3. 告警通知渠道（钉钉机器人/企业微信webhook）提前创建，获取webhook地址
4. 内核参数调优完成，容器/宿主机指标采集无权限拦截
5. 集群证书正常，apiserver鉴权完整

## 四、步骤1：添加Helm官方仓库（kube-prometheus-stack）
```bash
# 添加Prometheus Operator官方helm仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

# 创建独立监控命名空间
kubectl create ns monitoring
```

## 五、步骤2：自定义values.yaml 标准化配置（企业生产完整版）
### 核心配置说明：高可用、持久化、告警、大盘、自动采集
```yaml
# 全局命名空间
namespaceOverride: monitoring

# 1. Prometheus Operator核心控制器
prometheusOperator:
  replicas: 2
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {cpu: 500m, memory: 512Mi}

# 2. Prometheus Server 高可用配置
prometheus:
  prometheusSpec:
    replicas: 2 # 双副本高可用
    retention: 15d # 指标数据保留15天
    resources:
      requests: {cpu: 1000m, memory: 2Gi}
      limits: {cpu: 2000m, memory: 4Gi}
    # 持久化存储
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: nfs-sc
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Gi
    # 自动采集所有ServiceMonitor/PodMonitor
    serviceMonitorSelector:
      matchLabels:
        prometheus: k8s
    podMonitorSelector:
      matchLabels:
        prometheus: k8s
    # 内置告警规则（集群异常、节点故障、Pod崩溃）
    ruleSelector:
      matchLabels:
        prometheus: k8s
    # 禁用未使用功能，节省资源
    enableAdminAPI: false
    # 采集间隔
    scrapeInterval: 30s
    evaluationInterval: 30s

# 3. AlertManager 告警集群（3副本高可用）
alertmanager:
  alertmanagerSpec:
    replicas: 3
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: nfs-sc
          resources:
            requests:
              storage: 20Gi
    # 告警降噪、分组、通知渠道配置文件
    alertmanagerConfigSelector:
      matchLabels:
        prometheus: k8s

# 4. Grafana 可视化面板
grafana:
  enabled: true
  persistence:
    enabled: true
    storageClassName: nfs-sc
    size: 20Gi
  adminPassword: "Admin@2026" # 初始管理员密码，部署后修改
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default
  # 内置集群通用大盘模板
  dashboards:
    default:
      node:
        gnetId: 1860 # 节点硬件大盘
      k8s-cluster:
        gnetId: 7249 # K8s集群资源大盘
      ingress:
        gnetId: 9614 # Ingress七层流量大盘
      etcd:
        gnetId: 3070 # ETCD监控大盘
  # 数据源自动关联Prometheus
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus-operated:9090
        isDefault: true
  # 对外暴露Ingress访问Grafana
  ingress:
    enabled: true
    ingressClassName: nginx-public
    hosts:
    - grafana.example.com
    tls: true

# 5. 内置采集组件：node-exporter / kube-state-metrics
kube-state-metrics:
  enabled: true
  resources:
    requests: {cpu: 100m, memory: 128Mi}

prometheus-node-exporter:
  enabled: true
  # 全节点DaemonSet采集硬件指标
  daemonset:
    enabled: true

# 6. 黑盒探测：HTTP/TCP端口连通性监控
blackboxExporter:
  enabled: true
```

## 六、步骤3：执行Helm部署
```bash
helm install k8s-monitor prometheus-community/kube-prometheus-stack \
-n monitoring \
-f values-prometheus.yaml
```

## 七、步骤4：告警通知配置（AlertManager钉钉/企业微信）
### 7.1 创建AlertManagerConfig自定义资源（告警路由、webhook）
```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: alert-webhook
  namespace: monitoring
  labels:
    prometheus: k8s
spec:
  route:
    groupBy: ['alertname','namespace']
    groupWait: 10s
    groupInterval: 10s
    repeatInterval: 5m # 告警每5分钟重复推送
    receiver: 'dingtalk'
  receivers:
  - name: 'dingtalk'
    webhookConfigs:
    - url: "https://oapi.dingtalk.com/robot/send?access_token=xxx"
      sendResolved: true # 告警恢复推送通知
```
参数说明：
- groupWait：同一故障告警延迟聚合，防止瞬时大量告警风暴
- repeatInterval：持续故障重复推送间隔
- sendResolved：告警自动恢复后推送恢复通知

### 7.2 内置集群告警规则（集群故障、资源水位）
自动加载通用告警规则，覆盖：
1. 节点NotReady、节点磁盘使用率>85%、内存水位>90%
2. Pod CrashLoopBackOff、副本数缺失、OOM Kill
3. ETCD磁盘满、API服务器响应延迟高
4. Ingress 5xx错误率突增、服务端口无法连通
5. PVC未绑定、存储卷读写IO报错

## 八、步骤5：业务应用自定义指标采集（ServiceMonitor）
业务容器暴露 `/metrics` 接口，通过ServiceMonitor自动接入Prometheus：
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: biz-app-monitor
  namespace: biz
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      app: api-server
  endpoints:
  - port: http
    path: /metrics
    interval: 30s
```
Prometheus Operator自动发现并持续拉取业务自定义指标，Grafana可绘制业务QPS、耗时、错误率大盘。

## 九、步骤6：全平台验收测试
### 9.1 组件状态校验
```bash
# 所有监控Pod全部Ready，无重启崩溃
kubectl get pods -n monitoring
# 查看Prometheus/AlertManager CR资源
kubectl get prometheus,alertmanager -n monitoring
# ServiceMonitor/PodMonitor资源正常识别
kubectl get servicemonitor -A
```

### 9.2 指标采集验证
1. Grafana登录 `grafana.example.com`，查看节点大盘CPU/内存/磁盘指标持续刷新
2. K8s集群大盘查看Pod、Deployment副本状态、资源分配率
3. ETCD、Ingress大盘指标无缺失、无断图

### 9.3 告警通知验证
手动制造故障（暂停某个Deployment副本、磁盘打满模拟），验证：
1. 5分钟内钉钉推送告警消息，包含故障命名空间、资源、故障详情
2. 故障恢复后自动推送恢复通知

## 十、高可用与性能优化规范
1. Prometheus双副本、AlertManager三副本，杜绝监控单点故障
2. 监控数据独立存储PVC，禁止与业务共用磁盘，避免IO争抢
3. 区分采集间隔：硬件30s、业务指标15s、长周期大盘5m，减少存储占用
4. 配置告警抑制规则：节点宕机时屏蔽该节点所有Pod衍生告警，避免风暴
5. 定期清理无用大盘、废弃ServiceMonitor，减少Prometheus计算压力
6. 大集群拆分多Prometheus分片，分别采集基础设施/业务指标，降低单实例负载

## 十一、生产高频故障排查
### 故障1：Grafana大盘无数据，指标断图
根因：ServiceMonitor标签不匹配、Prometheus Pod崩溃、PVC存储挂载失败
排查：`kubectl logs -n monitoring prometheus-0`、校验serviceMonitor标签

### 故障2：磁盘使用率告警不触发
根因：node-exporter未正常采集磁盘指标、告警规则标签过滤、采集间隔过长

### 故障3：告警仅推送一次，故障持续无重复通知
根因：AlertManager repeatInterval参数未配置或配置过大

### 故障4：Prometheus 内存持续暴涨、OOM重启
根因：集群规模过大，采集目标过多，未分片；保留时长过长存储压力大
修复：拆分Prometheus分片，缩短retention保留时间，上调内存limits

### 故障5：业务自定义指标完全采集不到
根因：ServiceMonitor端口/路径填写错误、Pod防火墙拦截metrics端口
排查：curl PodIP:port/metrics 验证接口可正常访问

## 十二、生产运维落地规范
1. 监控平台独立存储PVC，定时备份Grafana大盘配置与告警规则
2. 所有生产集群必须开启多副本高可用Prometheus+AlertManager
3. 告警分层分级：紧急故障（节点宕机/数据库失联）推送短信，普通资源水位仅钉钉
4. 禁止将监控组件部署至业务节点，资源预留隔离，避免业务抢占监控资源
5. 集群交付验收强制校验监控大盘、告警推送（纳入validate-cluster-health.md）
6. 定期清理过期监控数据，监控磁盘使用率阈值80%触发扩容告警
7. 业务上线必须配套ServiceMonitor接入监控，无指标采集禁止投产

## 十三、关联文档索引
build-kubernetes-cluster.md 集群基础环境部署
build-storage-platform.md 监控持久化PVC StorageClass配置
build-ingress-platform.md Grafana外网Ingress域名访问配置
build-log-platform.md 日志平台与监控联动告警
validate-cluster-health.md 集群监控交付验收标准
06-network-debug.md Ingress/节点网络指标故障排查