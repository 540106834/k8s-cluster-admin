针对你的场景：

* Kubernetes: **v1.32**
* Helm Chart: **kube-prometheus-stack-65.1.0**
* Storage: **NFS StorageClass (`nfs-sc`)**
* Helm Chart来源: **离线 MinIO**
* Git 管理部署代码
* MinIO 管理二进制 Chart 包

建议工程化目录如下：

```text
kube-prometheus-stack/                         # Kubernetes监控平台工程
│
├── README.md                                  # 项目说明、部署入口、使用指南
├── VERSION                                    # 版本信息(K8s/Helm/Chart/Operator/Prometheus)
├── CHANGELOG.md                               # 版本变更记录
│
├── chart/                                     # Helm Chart信息管理
│   └── README.md                              # Chart版本、来源、依赖说明
│
├── docs/                                      # 设计与运维文档
│   ├── 01-architecture.md                     # 监控平台架构设计(Prometheus Operator/Grafana)
│   ├── 02-deployment.md                       # 安装、升级、回滚、卸载流程
│   ├── 03-storage-design.md                   # PVC、StorageClass、NFS存储设计
│   ├── 04-alerting-design.md                  # Alertmanager告警架构和规则设计
│   ├── 05-security-design.md                  # RBAC、TLS、访问控制设计
│   └── 06-troubleshooting.md                  # 常见故障排查手册
│
├── helm/                                      # Helm部署配置
│   ├── values.yaml                            # 通用Helm配置
│   ├── values-dev.yaml                        # 开发环境配置
│   ├── values-prod.yaml                       # 生产环境配置
│   └── dashboards/                            # Grafana Dashboard管理
│       ├── kubernetes-cluster.json            # Kubernetes集群监控面板
│       ├── node-exporter.json                 # 节点资源监控面板
│       └── application.json                   # 应用业务监控面板
│
├── manifests/                                 # Helm之外维护的Kubernetes资源
│   ├── namespace.yaml                         # monitoring命名空间定义
│   ├── ingress.yaml                           # Grafana/Prometheus访问入口
│   ├── service-monitor/                       # 业务ServiceMonitor扩展
│   │   └── README.md                          # ServiceMonitor接入规范
│   └── prometheus-rule/                       # Prometheus告警规则扩展
│       └── README.md                          # 自定义告警规则规范
│
├── scripts/                                   # 自动化部署脚本
│   ├── install.sh                             # 安装kube-prometheus-stack
│   ├── upgrade.sh                             # Helm升级操作
│   ├── rollback.sh                            # Helm版本回滚
│   ├── uninstall.sh                           # 卸载监控组件
│   ├── verify.sh                              # 部署结果验证
│   └── health-check.sh                        # 运行状态健康检查
│
├── offline/                                   # 离线部署资源管理
│   ├── chart-info.yaml                        # Chart版本和MinIO信息
│   └── download-chart.sh                      # 从MinIO下载Helm Chart
│
├── images/                                    # 镜像供应链管理
│   ├── images.txt                             # 所需容器镜像清单
│   └── sync-images.sh                         # 镜像同步到Harbor
│
└── examples/                                  # 使用案例模板
    ├── servicemonitor-example.yaml            # 业务监控接入示例
    └── prometheusrule-example.yaml            # 告警规则编写示例
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
