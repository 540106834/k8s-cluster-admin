# docs/04-workload/02-grafana.md
# kube-prometheus-stack Grafana 可视化运维手册
## 文档基础信息
- K8s：v1.32
- Chart基线：kube-prometheus-stack-65.1.0
- 存储：NFS `nfs-sc` 持久PVC
- 管控模式：Git Values + Operator自动管理ConfigMap/Secret
- 文档等级：★★★★★ 核心可视化负载文档
- 前置阅读：04-workload/01-prometheus.md、02-deployment/02-configuration.md

## 目录
1. Grafana Operator托管架构
2. 部署规格与多环境资源标准
3. 持久化存储设计（面板/账号/数据源）
4. 数据源统一配置（Prometheus HA、静态Secret管理）
5. 仪表板GitOps标准化管理（预注入面板、自定义面板）
6. 用户权限体系、RBAC与登录认证
7. 告警通知渠道配置（钉钉/邮件/企业微信）
8. 网络安全规范（Ingress TLS、NetworkPolicy、访问鉴权）
9. 日常运维操作（面板同步、重启、备份迁移、插件管理）
10. 常见故障定位核心指标与排查
11. 关联文档索引

---

# 1. Grafana Operator托管架构
## 1.1 组件流转链路
```
Git仓库values.yaml / 预定义dashboard ConfigMap
        ↓ helm upgrade下发
Prometheus Operator → 自动管理Grafana Deployment、PVC、Service、Ingress、Secret
        ↓ 容器启动加载
1. datasources.yaml 自动注入所有Prometheus HA数据源
2. dashboard provider配置自动拉取Git托管面板
3. admin账号密码从Secret读取，无需手动登录初始化
```
## 1.2 Operator自动化能力
1. 自动生成内置监控面板（节点、Pod、Deployment、PVC、API Server）；
2. 数据源热更新，修改values无需重启Grafana；
3. 内置ServiceAccount最小权限，仅读取监控命名空间资源；
4. 插件自动安装，无需手动进入容器下载。
## 1.3 无状态说明
Grafana Deployment单副本运行，无StatefulSet；数据依赖PVC持久存储，删除Pod不丢失配置/面板。

# 2. 部署规格与多环境资源标准
## 2.1 生产环境（多业务面板、多数据源、多用户）
```yaml
grafana:
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 4Gi
```
## 2.2 UAT测试环境
```yaml
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi
```
## 2.3 Dev开发环境
```yaml
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi
```
## 2.4 资源水位阈值
- 内存持续占用＞75%：扩容内存、清理无用大面板、限制并发查询；
- CPU持续＞80%：拆分大查询、缩短面板刷新间隔。

# 3. 持久化存储设计
## 3.1 PVC标准配置（values内置）
```yaml
grafana:
  persistence:
    enabled: true
    storageClassName: "nfs-sc"
    size: 30Gi
```
## 3.2 PVC内部数据分层
```
/var/lib/grafana
├── grafana.db  # SQLite核心库：用户账号、权限、数据源配置、告警渠道、手动创建面板
├── plugins/    # 第三方插件持久化
├── dashboards/ # 本地临时面板缓存（Git托管面板只读，不写入此处）
└── alerting/   # Grafana内置告警状态、静默记录
```
## 3.3 存储约束
1. 所有自定义临时面板、账号权限均存入SQLite，依赖NFS持久；
2. Git托管标准化面板以ConfigMap只读挂载，不会写入PVC；
3. StorageClass `reclaimPolicy: Retain`，卸载Chart不删除监控数据。

## 3.4 备份策略
1. 每日定时NFS层打包grafana.db；
2. 版本升级前手动备份PVC目录（参考02-deployment/03-upgrade.md）；
3. 标准化面板代码存入Git作为永久备份。

# 4. 数据源统一配置（Prometheus HA双实例）
## 4.1 自动注入Prometheus数据源配置
Operator自动生成datasource配置，对接双副本Prometheus Service实现查询高可用：
```yaml
grafana:
  prometheusDatasource:
    enabled: true
    url: http://kube-monitor-prometheus.monitoring.svc.cluster.local:9090
    access: proxy
    isDefault: true
```
查询负载均衡：Grafana自动轮询两个Prometheus Pod，单副本宕机自动切换。

## 4.2 多数据源扩展（Loki/MySQL/Redis）
通过grafana.additionalDataSources追加其他数据源，存入ConfigMap热加载：
```yaml
grafana:
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki-stack-gateway.monitoring.svc:3100
```

## 4.3 敏感配置管理（账号密码）
数据库、中间件数据源密码统一存入K8s Secret，禁止明文写values：
```yaml
grafana:
  additionalDataSources:
    - name: MySQL
      type: mysql
      url: mysql-service:3306
      secureJsonData:
        password:
          secretKeyRef:
            name: grafana-db-secret
            key: mysql-password
```

# 5. 仪表板GitOps标准化管理
## 5.1 两类面板分层规范
1. **内置基础面板（Chart自带）**
节点监控、K8s Pod/Deployment/StatefulSet、PVC存储、API Server，无需维护，Operator自动更新。
2. **业务自定义面板（Git托管）**
业务QPS、延迟、中间件监控、自定义告警大盘，统一存Git仓库，通过grafana.dashboardsProviders注入。

## 5.2 Git面板注入配置
```yaml
grafana:
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: business
        orgId: 1
        folder: Business
        type: file
        options:
          path: /var/lib/grafana/dashboards/business

  dashboards:
    business:
      api-dashboard:
        gnetId: null
        url: https://gitea.internal/devops/monitor-dash/raw/main/api-dashboard.json
        revision: 1
```
helm upgrade后自动拉取最新JSON面板，无需手动导入Grafana页面。

## 5.3 管控约束
1. 禁止业务人员在Grafana页面直接修改标准化大盘；所有变更提交Git；
2. 页面临时调试面板可存在SQLite，升级不丢失，但上线前必须固化至Git。

# 6. 用户权限体系与登录认证
## 6.1 默认Admin账号（Secret托管）
```yaml
grafana:
  adminPassword:
    existingSecret: grafana-admin-secret
    secretKey: admin-password
```
不硬编码密码，定期轮换Secret。

## 6.2 多组织/文件夹权限分层
1. 全局组织Org1：所有监控大盘；
2. 文件夹分层：Platform（集群基础）、Business（业务应用）、Storage（存储监控）；
3. 角色分级：Admin/Editor/Viewer，业务开发仅分配Viewer只读权限。

## 6.3 登录认证方案（生产强制开启）
### 6.3.1 OIDC统一登录（企业内部IDP）
对接内部账号系统，废弃本地账号：
```yaml
grafana:
  grafana.ini:
    auth.oidc:
      enabled: true
      client_id: grafana
      client_secret: $__file{/etc/secrets/oidc/client-secret}
      scopes: openid email profile
```
### 6.3.2 基础兜底账号
OIDC故障时使用admin本地账号应急登录。

# 7. 告警通知渠道配置
统一在values中配置，热加载无需重启Grafana：
```yaml
grafana:
  alerting:
    notificationChannels:
      - name: DingTalk-Business
        type: dingding
        uid: ding-business
        isDefault: false
        secureSettings:
          webhook:
            secretKeyRef:
              name: grafana-alert-secret
              key: ding-business-webhook
```
支持渠道：钉钉、企业微信、邮件、Slack；区分平台告警群、业务告警群。

# 8. 网络安全规范
## 8.1 Ingress强制TLS HTTPS
```yaml
grafana:
  ingress:
    enabled: true
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    tls: true
    hosts:
      - grafana.monitor.internal.com
```
## 8.2 NetworkPolicy隔离
```yaml
grafana:
  networkPolicy:
    enabled: true
```
入站仅放行：
1. Ingress Controller 80/443访问；
出站仅放行：
1. Prometheus/Loki等监控数据源端口；
2. 告警Webhook出口；
拒绝跨命名空间无授权访问。

## 8.3 Pod安全上下文（非Root运行）
```yaml
grafana:
  securityContext:
    runAsUser: 472
    runAsNonRoot: true
    fsGroup: 472
    allowPrivilegeEscalation: false
```

# 9. 日常运维标准操作
## 9.1 更新Git面板/数据源配置
```bash
helm upgrade kube-monitor /opt/monitor-chart/kube-prometheus-stack \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml
```
配置热加载，面板自动同步。

## 9.2 重启Grafana实例
```bash
kubectl rollout restart deployment kube-monitor-grafana -n monitoring
```

## 9.3 面板备份导出
1. Git托管面板：直接拉取仓库JSON；
2. 临时本地面板：Grafana页面导出JSON，提交固化至Git。

## 9.4 插件安装管理
在values统一声明插件，自动安装：
```yaml
grafana:
  plugins:
    - grafana-piechart-panel
    - grafana-loki-datasource
```

## 9.5 迁移Grafana完整配置
1. 停止Grafana Deployment；
2. 备份NFS目录grafana.db；
3. 新环境恢复PVC文件；
4. 启动Deployment，账号/面板/数据源完全复用。

# 10. 故障定位与核心监控指标
## 10.1 Grafana自身暴露监控指标（内置metrics）
- `grafana_http_request_duration_seconds`：面板加载延迟，突增代表查询过大；
- `grafana_datasource_request_total{status="5xx"}`：数据源连接失败计数；
- `grafana_alerting_notifications_sent_total`：告警推送成功/失败统计；
- `process_resident_memory_bytes`：Grafana内存占用，持续上涨存在内存泄漏。

## 10.2 高频故障速查
1. 面板无数据 → Prometheus数据源不通/查询语法错误/指标留存过期；
2. 登录页面打不开 → Ingress TLS配置错误、NetworkPolicy拦截；
3. 告警收不到 → Webhook密钥失效、出站网络拦截；
4. 面板修改重启后丢失 → 面板未存入Git，ConfigMap只读覆盖；
5. Pod频繁OOM → 并发查询过多、单面板大量复杂PromQL。

# 11. 关联文档索引
1. Prometheus采集与HA架构：04-workload/01-prometheus.md
2. Alertmanager告警分发：04-workload/03-alertmanager.md
3. Chart全局values配置：02-deployment/02-configuration.md
4. NFS存储PVC设计：03-storage/01-storage-design.md
5. 监控故障排查手册：09-troubleshooting/04-grafana-error.md
6. 业务监控面板开发规范：05-prometheus-operator/04-dashboard-standard.md