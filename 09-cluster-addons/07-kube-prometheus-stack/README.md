场景：

* Kubernetes: **v1.32**
* Helm Chart: **kube-prometheus-stack-65.1.0**
* Storage: **NFS StorageClass (`nfs-sc`)**
* Helm Chart来源: **离线 MinIO**
* Git 管理部署代码
* MinIO 管理二进制 Chart 包

建议工程化目录如下：

```text
kube-prometheus-stack/
│
├── README.md                                         # 项目说明、部署流程、目录介绍
├── CHANGELOG.md                                      # 版本更新记录
├── VERSION                                           # 当前 Helm Chart 版本
│
├── charts/
│   └── kube-prometheus-stack-65.1.0.tgz              # 离线 Helm Chart（可由 MinIO 下载）
│
├── values/
│   ├── values.yaml                                   # 平台实际使用配置（唯一维护文件）
│   ├── values-default.yaml                           # 官方默认 values（仅用于升级对比）
│   └── images.txt                                    # Chart 最终依赖镜像列表
│
├── scripts/
│   ├── install.sh                                    # 首次部署
│   ├── upgrade.sh                                    # Helm 升级
│   ├── rollback.sh                                   # Helm 回滚
│   ├── uninstall.sh                                  # 卸载监控平台
│   ├── template.sh                                   # 渲染 Kubernetes Manifest
│   ├── export-images.sh                              # 导出 Chart 实际依赖镜像
│   ├── sync-harbor.sh                                # 同步镜像至 Harbor
│   ├── pull-chart.sh                                 # 从 MinIO 下载 Helm Chart
│   ├── validate.sh                                   # 校验 values.yaml 配置
│   └── health-check.sh                               # 部署完成健康检查
│
├── manifests/
│   ├── rendered.yaml                                 # helm template 渲染结果（可选）
│   └── crds.yaml                                     # 独立 CRD（可选）
│
├── examples/
│   ├── servicemonitor/                               # ServiceMonitor 示例
│   ├── podmonitor/                                   # PodMonitor 示例
│   ├── prometheusrule/                               # PrometheusRule 示例
│   └── grafana-dashboard/                            # Grafana Dashboard 示例
│
├── docs/                                               # 文档中心：平台设计、部署、运维、扩展
│   │
│   ├── 01-overview/                                   # ★★★★★ 平台概览：架构设计、组件关系、整体认知
│   │   │
│   │   ├── 01-architecture.md                         # ★★★★★ 平台整体架构：Operator、Prometheus、Grafana、Alertmanager、Exporter、CRD关系
│   │   └── 02-component-overview.md                   # ★★★★★ 组件说明：各组件职责、数据流、依赖关系
│   │
│   ├── 02-deployment/                                 # ★★★★★ 部署交付：离线安装、配置管理、版本升级
│   │   │
│   │   ├── 01-installation.md                         # ★★★★★ 离线安装流程：MinIO、Helm、Harbor、Namespace、部署步骤
│   │   ├── 02-configuration.md                        # ★★★★★ values.yaml配置规范、参数说明、环境差异管理
│   │   └── 03-upgrade.md                             # ★★★★★ Helm升级流程、版本兼容、升级检查
│   │
│   ├── 03-storage/                                    # ★★★★★ 数据存储：Prometheus数据持久化设计
│   │   │
│   │   ├── 01-storage-design.md                       # ★★★★★ 存储设计：NFS、StorageClass、PVC规划、生产存储方案
│   │   └── 02-data-retention.md                       # ★★★★☆ Prometheus数据保留、容量规划、TSDB管理
│   │
│   ├── 04-monitoring-components/                      # ★★★★★ 核心监控组件：采集、存储、展示、告警
│   │   │
│   │   ├── 01-prometheus.md                           # ★★★★★ Prometheus架构、TSDB、采集流程、性能优化
│   │   ├── 02-grafana.md                              # ★★★★★ Grafana Dashboard、数据源、权限管理
│   │   ├── 03-alertmanager.md                         # ★★★★★ Alertmanager路由、分组、静默、通知
│   │   └── 04-exporters.md                            # ★★★★★ Node Exporter、kube-state-metrics、自定义Exporter
│   │
│   ├── 05-prometheus-operator/                        # ★★★★★ Kubernetes原生监控扩展模型
│   │   │
│   │   ├── 01-servicemonitor.md                       # ★★★★★ ServiceMonitor原理、Selector、NamespaceSelector、监控接入
│   │   ├── 02-podmonitor.md                           # ★★★★☆ PodMonitor原理、Pod采集场景
│   │   ├── 03-prometheusrule.md                       # ★★★★★ PrometheusRule告警规则管理
│   │   └── 04-recordingrule.md                        # ★★★★☆ RecordingRule预计算指标、查询优化
│   │
│   ├── 06-operations/                                 # ★★★★★ 日常运维：平台运行管理
│   │   │
│   │   ├── 01-daily-operation.md                      # ★★★★★ 状态检查、资源调整、扩缩容
│   │   ├── 02-backup-restore.md                       # ★★★★☆ 配置备份、数据恢复、灾备方案
│   │   ├── 03-rollback.md                             # ★★★★★ Helm Revision管理、回滚流程
│   │   └── 04-health-check.md                         # ★★★★★ 健康检查、监控自监控
│   │
│   ├── 07-security/                                  # ★★★★☆ 安全设计：权限、网络、证书、密钥
│   │   │
│   │   ├── 01-rbac.md                                # ★★★★☆ RBAC权限设计
│   │   ├── 02-network-security.md                     # ★★★☆☆ NetworkPolicy、安全边界
│   │   ├── 03-tls-ingress.md                          # ★★★★☆ HTTPS、证书、Ingress访问
│   │   └── 04-secret-management.md                    # ★★★★☆ 密钥、密码、敏感配置管理
│   │
│   ├── 08-extension/                                 # ★★★☆☆ 平台扩展能力：大型集群、高级场景
│   │   │
│   │   ├── 01-thanos.md                              # ★★★☆☆ Thanos长期存储、对象存储、全局查询
│   │   ├── 02-custom-exporter.md                     # ★★★★☆ 自定义Exporter开发接入
│   │   └── 03-custom-dashboard.md                    # ★★★★☆ 自定义Grafana Dashboard规范
│   │
│   ├── 09-troubleshooting/                            # ★★★★★ 故障排查：生产问题处理能力
│   │   │
│   │   ├── 01-install-error.md                        # ★★★★★ 安装失败排查
│   │   ├── 02-target-down.md                          # ★★★★★ Target Down排查
│   │   ├── 03-pvc-error.md                            # ★★★★★ PVC Pending、Storage异常
│   │   ├── 04-rule-error.md                           # ★★★★☆ PrometheusRule错误排查
│   │   └── 05-performance.md                          # ★★★★★ Prometheus性能问题排查
│   │
│   └── 10-best-practices/                             # ★★★★★ 企业规范：平台长期治理
│       │
│       ├── 01-resource-planning.md                    # ★★★★★ CPU、Memory、Storage容量规划
│       ├── 02-label-standard.md                       # ★★★★★ Label、Selector规范
│       ├── 03-monitoring-standard.md                  # ★★★★★ 监控接入规范、指标设计、告警规范
│       └── 04-maintenance-standard.md                 # ★★★★☆ 平台维护规范、版本管理、变更流程
│
└── tests/
    ├── deploy-nginx.yaml                             # 测试应用
    ├── servicemonitor.yaml                           # ServiceMonitor 测试
    ├── podmonitor.yaml                               # PodMonitor 测试
    └── prometheusrule.yaml                           # 告警规则测试
```

---

# MinIO 仓库设计

MinIO 不放 Git。

单独：

```text
minio
│
└── helm-charts
    │
    └── kube-prometheus-stack
        │
        └── kube-prometheus-stack-65.1.0.tgz
```

完整路径：

```text
http://192.168.122.51:9000/helm-charts/
└── kube-prometheus-stack/
    └── kube-prometheus-stack-65.1.0.tgz
```

---

# 每个目录职责

## docs

用于平台文档。

例如：

### architecture.md

描述：

```text
kube-prometheus-stack

Prometheus Operator
        |
        |
Prometheus CR
        |
        |
ServiceMonitor
        |
        |
业务服务
```

---

### storage-design.md

描述：

```text
Prometheus
    |
PVC
    |
StorageClass nfs-sc
    |
nfs-subdir-external-provisioner
    |
NFS Server
```

---

# config

存放 Helm 配置。

例如：

```text
config/
|
├── values.yaml
|
└── values-prod.yaml
```

区别：

## values.yaml

基础配置：

```yaml
prometheus:
  enabled: true

grafana:
  enabled: true

alertmanager:
  enabled: true
```

---

## values-prod.yaml

生产覆盖：

```yaml
prometheus:

  prometheusSpec:

    retention: 30d

    storageSpec:

      volumeClaimTemplate:

        spec:

          storageClassName: nfs-sc

          resources:

            requests:

              storage: 100Gi
```

安装：

```bash
helm install \
-f config/values.yaml \
-f config/values-prod.yaml
```

---

# scripts

## install.sh

职责：

1. 从 MinIO 下载 Chart
2. 创建 namespace
3. Helm install

流程：

```text
install.sh

     |
     |
wget MinIO

     |
     |
helm install

     |
     |
verify
```

---

## upgrade.sh

升级：

```bash
helm upgrade
```

例如：

65.1.0

升级：

65.2.0

---

## rollback.sh

版本回退：

```bash
helm history
```

然后：

```bash
helm rollback
```

---

## verify.sh

自动检查：

```bash
kubectl get pods -n monitoring

kubectl get pvc -n monitoring

kubectl get prometheus -n monitoring

kubectl get servicemonitor -n monitoring
```

---

# manifests

不要大量放 Helm 生成 YAML。

只放外围资源。

例如：

## namespace.yaml

```yaml
apiVersion: v1
kind: Namespace

metadata:

  name: monitoring
```

## ingress.yaml

未来：

```text
grafana.example.com
prometheus.example.com
```

---

# images.txt

记录离线镜像。

例如：

```text
quay.io/prometheus-operator/prometheus-operator:v0.77.0

quay.io/prometheus/prometheus:v2.47.0

quay.io/prometheus/alertmanager:v0.27.0

grafana/grafana:11.x

registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.x

quay.io/prometheus/node-exporter:v1.x
```

用于：

```text
公网环境
 |
 docker pull
 |
 docker save
 |
 Harbor
 |
 内网 Kubernetes
```

---

# VERSION

记录版本：

```text
Kubernetes=v1.32.0

Helm=3.17.x

Chart=kube-prometheus-stack-65.1.0

Prometheus Operator=v0.77.0

Prometheus=v2.47.0

StorageClass=nfs-sc
```

---

# 最终企业化结构

你的整个 Kubernetes 平台建议：

```text
kubernetes-cluster-infrastructure

├── 01-node-preparation
├── 02-cluster-bootstrap
├── 03-network
├── 04-storage
│
├── 05-security
│
├── 06-cluster-addons
│
│   ├── ingress-nginx
│   ├── cert-manager
│   ├── nfs-provisioner
│   │
│   └── monitoring
│       └── kube-prometheus-stack
│
├── 07-logging
│
├── 08-backup
│
└── 09-disaster-recovery
```

这个结构已经接近企业 SRE / Platform Engineering 团队管理 Kubernetes 基础设施的方式。你现在的版本组合可以直接作为一个 Kubernetes 1.32 生产基线。
