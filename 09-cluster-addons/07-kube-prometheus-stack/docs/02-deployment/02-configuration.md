# docs/02-deployment/02-configuration.md
# kube-prometheus-stack values.yaml 离线环境配置规范手册
## 文档基础信息
- K8s 集群：v1.32
- Chart 版本：kube-prometheus-stack-65.1.0
- 存储：NFS StorageClass `nfs-sc`
- 交付：MinIO 离线 Chart 包 + Git 管控配置
- 镜像仓库：内网私有 Harbor
- 文档等级：★★★★★ 核心配置文档
- 前置阅读：01-installation.md

## 目录
1. 配置分层管理规范（Git 多环境拆分）
2. 全局基础配置（镜像、命名空间、RBAC、拉取密钥）
3. Prometheus 核心配置（HA、TSDB、NFS持久化、采集、保留周期）
4. Alertmanager 配置（存储、路由、告警渠道Secret引用）
5. Grafana 配置（持久化、管理员密钥、大盘自动加载、Ingress）
6. 采集组件配置（node-exporter / kube-state-metrics）
7. CRD 管控配置（ServiceMonitor/PrometheusRule 全局过滤）
8. 网络安全配置（NetworkPolicy 开关）
9. 离线环境专属约束配置
10. 配置变更 GitOps 标准流程
11. 配置校验工具与命令
12. 关联文档索引

---

# 1. 配置分层管理规范（Git 目录标准）
## 1.1 多环境文件拆分
Git 仓库路径 `kube-monitor/values/`
- `values-base.yaml`：全局公共基础配置（镜像仓库、存储类、RBAC、镜像密钥），所有环境通用
- `values-prod.yaml`：生产环境独配（资源规格、15天数据保留、HA双副本、完整告警渠道、大容量PVC）
- `values-uat.yaml`：测试环境独配（单副本、7天数据保留、小容量存储、简化告警）
- `values-dev.yaml`：开发环境（精简资源、关闭持久化、仅本地告警）

## 1.2 多文件合并安装规则
离线安装时使用多 `-f` 叠加加载，环境配置覆盖基础配置：
```bash
helm install kube-monitor /opt/monitor-chart/kube-prometheus-stack \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml
```

## 1.3 配置拆分原则
1. 全局公共项统一放入 base，禁止多环境重复编写；
2. 存储容量、副本数、数据保留周期、告警渠道按环境差异化；
3. 敏感信息（webhook、密码）**禁止写入values**，全部外置K8s Secret；
4. 业务自定义ServiceMonitor/PrometheusRule不写入Chart values，独立存Git `crd/` 目录，Chart安装后单独apply。

---

# 2. 全局基础配置 values-base.yaml
## 2.1 离线镜像仓库统一替换（核心离线配置）
```yaml
global:
  imageRegistry: harbor.example.com/library
  imagePullSecrets:
    - name: harbor-pull-secret
  storageClass: nfs-sc
```
- `imageRegistry`：所有组件镜像自动拼接内网Harbor前缀，彻底屏蔽外网镜像源；
- `imagePullSecrets`：全局指定镜像拉取密钥，所有Pod自动继承；
- `storageClass`：全局默认存储类，所有有状态组件默认使用 `nfs-sc`。

## 2.2 全局RBAC权限开启
```yaml
prometheusOperator:
  rbac:
    create: true
    clusterRole: true
```
Operator 需集群级权限，读取全Namespace资源元数据。

## 2.3 全局标签规范（统一Label标准，参考10-best-practices/02-label-standard.md）
```yaml
commonLabels:
  platform: monitor
  chart: kube-prometheus-stack
  env: prod
```
所有控制器、Service、PVC自动携带统一标签，便于筛选清理。

## 2.4 关闭外网仓库（离线强制）
```yaml
prometheusOperator:
  prometheusConfigReloader:
    image:
      repository: prometheus-config-reloader
grafana:
  plugins:
    install: false # 离线无外网，禁止自动下载插件
```

---

# 3. Prometheus 核心配置（values-prod 差异化重点）
## 3.1 高可用 + NFS持久化存储（生产强制）
```yaml
prometheus:
  prometheusSpec:
    replicas: 2 # 生产双副本HA
    retention: 15d # 数据保留周期，参考03-storage/02-data-retention.md
    retentionSize: "450GB" # 容量上限，超出自动压缩删除旧数据
    storageSpec:
      volumeClaimTemplate:
        storageClassName: nfs-sc
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 500Gi
        metadata:
          labels:
            app: prometheus-storage
```

## 3.2 资源限制（容量规划标准 10-best-practices/01-resource-planning.md）
```yaml
    resources:
      requests:
        cpu: 2000m
        memory: 4Gi
      limits:
        cpu: 4000m
        memory: 8Gi
```

## 3.3 抓取全局配置
```yaml
    scrapeInterval: 30s # 指标抓取间隔
    evaluationInterval: 1m # 规则评估周期
    scrapeTimeout: 10s
    enableRemoteWrite: false # 未部署Thanos前关闭远端写
    serviceMonitorSelector: # 仅匹配平台管控监控
      matchLabels:
        platform: monitor
    serviceMonitorNamespaceSelector:
      matchLabels:
        monitor-enabled: "true" # 仅采集带标签命名空间业务
```

## 3.4 内置采集开关
```yaml
    kubelet:
      enabled: true # 自动采集节点cAdvisor容器指标
    selfMonitor:
      enabled: true # Prometheus自监控
```

## 3.5 预计算/告警规则外置
不将业务规则写入values，统一使用独立 `PrometheusRule` CRD，热加载无需重启Prometheus。

---

# 4. Alertmanager 配置
## 4.1 NFS持久化存储
```yaml
alertmanager:
  alertmanagerSpec:
    replicas: 1
    storage:
      volumeClaimTemplate:
        storageClassName: nfs-sc
        resources:
          requests:
            storage: 20Gi
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: 1000m
        memory: 2Gi
```

## 4.2 告警路由、分组、抑制（Secret引用webhook，无明文）
values中仅配置路由逻辑，webhook地址从Secret读取：
```yaml
    alertmanagerConfiguration:
      global:
        resolveTimeout: 5m
      route:
        groupBy: ['namespace', 'app', 'severity']
        groupWait: 30s
        groupInterval: 5m
        repeatInterval: 4h
        receiver: "default-dingtalk"
        routes:
          - match:
              severity: critical
            receiver: "critical-dingtalk"
      receivers:
        - name: critical-dingtalk
          webhookConfigs:
            - urlFromSecret:
                name: alert-webhook-secret
                key: dingtalk_critical_url
        - name: default-dingtalk
          webhookConfigs:
            - urlFromSecret:
                name: alert-webhook-secret
                key: dingtalk_normal_url
```
> 敏感webhook地址提前通过 `kubectl create secret` 创建，绝不写values明文。

## 4.3 告警抑制规则
```yaml
      inhibitRules:
        - sourceMatch:
            severity: critical
            alertname: NodeDown
          targetMatch:
            severity: critical
          equal: ['namespace', 'node']
```
节点宕机时抑制该节点下所有Pod失联告警，减少告警刷屏。

---

# 5. Grafana 完整配置
## 5.1 NFS持久化、管理员账号外置Secret
```yaml
grafana:
  enabled: true
  persistence:
    enabled: true
    storageClassName: nfs-sc
    size: 30Gi
  adminPasswordSecret: grafana-admin
  adminUserSecret: grafana-admin
```

## 5.2 自动导入Git托管Dashboard
Chart支持读取ConfigMap大盘，Git中dashboard清单部署为独立ConfigMap，标签匹配自动导入Grafana：
```yaml
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: 'default'
        orgId: 1
        folder: 'K8s集群'
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default
```

## 5.3 TLS HTTPS Ingress 配置
```yaml
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.class: nginx
      cert-manager.io/cluster-issuer: cluster-ca
    hosts:
      - grafana.monitor.example.com
    tls:
      - secretName: grafana-tls-cert
        hosts:
          - grafana.monitor.example.com
```

## 5.4 数据源自动注入Prometheus
```yaml
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://kube-monitor-prometheus.monitoring.svc.cluster.local:9090
          access: proxy
          isDefault: true
```

## 5.5 离线约束：关闭在线插件安装
```yaml
  plugins:
    install: false
```

---

# 6. 基础设施采集组件配置
## 6.1 node-exporter（DaemonSet全节点部署）
```yaml
prometheus-node-exporter:
  enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 300m
      memory: 256Mi
  hostNetwork: true
  rootfsMount: true # 读取宿主机磁盘指标
```

## 6.2 kube-state-metrics（集群资源元指标）
```yaml
kube-state-metrics:
  enabled: true
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi
  prometheus:
    monitor:
      enabled: true
      selfMonitor: true
```

---

# 7. CRD 全局过滤配置（管控采集范围）
控制Prometheus自动发现哪些命名空间、哪些业务指标，避免全集群无差别抓取：
```yaml
prometheus:
  prometheusSpec:
    podMonitorSelector:
      matchLabels:
        platform: monitor
    podMonitorNamespaceSelector:
      matchLabels:
        monitor-enabled: "true"
    ruleSelector:
      matchLabels:
        platform: monitor
```
业务Namespace必须打上标签 `monitor-enabled: "true"` 才会被自动采集，实现采集权限隔离。

---

# 8. 网络安全配置 NetworkPolicy
```yaml
prometheusOperator:
  networkPolicy:
    enabled: true # 开启组件内部网络隔离
grafana:
  networkPolicy:
    enabled: true
prometheus:
  prometheusSpec:
    networkPolicy:
      enabled: true
```
所有监控组件启用NetworkPolicy，仅允许组件内部互通，外部Pod无法直接访问Prometheus/Grafana端口，详见07-security/02-network-security.md。

---

# 9. 离线环境专属强制约束配置
以下配置为离线环境必填，缺失会导致安装/运行异常：
1. 全局 `imageRegistry` 指向内网Harbor，无外网镜像；
2. `grafana.plugins.install: false` 禁止在线拉取插件；
3. 不配置外网Alert渠道（邮件外网SMTP禁用），仅使用内网钉钉/企业微信Webhook；
4. 所有存储强制 `storageClassName: nfs-sc`，禁用hostPath临时存储；
5. 关闭Prometheus远端写入remoteWrite（无外网对象存储，Thanos后期单独扩展）；
6. 镜像拉取密钥全局注入，不依赖节点外网镜像缓存。

---

# 10. 配置变更 GitOps 标准流程
## 10.1 变更规范
1. 修改对应环境values文件，**禁止直接kubectl edit集群资源**；
2. 本地执行配置校验，确认无语法错误；
3. Git提交，填写变更说明（资源扩容/存储调整/告警规则修改）；
4. 执行helm dry-run预发布校验；
5. 执行helm upgrade滚动更新；
6. 验证组件Pod滚动更新完成、功能正常；
7. 留存变更记录，写入运维变更台账。

## 10.2 预校验dry-run命令（变更前必执行）
```bash
helm upgrade kube-monitor /opt/monitor-chart/kube-prometheus-stack \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml \
--dry-run --debug
```
dry-run无报错再执行真实upgrade。

---

# 11. 配置校验工具与常用命令
1. 校验values yaml语法
```bash
yamllint ./values/*.yaml
```
2. 渲染完整K8s资源清单，查看最终生成配置
```bash
helm template kube-monitor /opt/monitor-chart/kube-prometheus-stack \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml > render-output.yaml
```
3. 查看当前集群生效values配置
```bash
helm get values kube-monitor -n monitoring
```
4. 查看完整发布渲染清单
```bash
helm get manifest kube-monitor -n monitoring
```

---

# 12. 关联文档索引
1. 离线部署流程：01-installation.md
2. Helm版本升级：03-upgrade.md
3. NFS存储规划：03-storage/01-storage-design.md
4. 告警规则CRD：05-prometheus-operator/03-prometheusrule.md
5. 网络安全策略：07-security/02-network-security.md
6. TLS域名接入：07-security/03-tls-ingress.md
7. 资源容量标准：10-best-practices/01-resource-planning.md
8. 标签统一规范：10-best-practices/02-label-standard.md