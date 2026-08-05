# docs/02-deployment/01-installation.md
# kube-prometheus-stack 离线完整安装手册
## 文档基础信息
- K8s 集群版本：v1.32
- Chart 版本：kube-prometheus-stack-65.1.0
- 持久化存储：NFS StorageClass `nfs-sc`
- Chart 托管：离线 MinIO 对象存储（tgz 二进制包）
- 配置管控：Git 仓库统一管理 values、CRD、大盘模板
- 镜像源：本地私有 Harbor（全组件离线镜像）
- 文档等级：★★★★★ 核心部署文档
- 前置阅读：01-overview/01-architecture.md、01-overview/02-component-overview.md

## 目录
1. 安装前置环境校验清单
2. 离线资源前置准备（MinIO Chart、Harbor 镜像、Git 配置）
3. 集群前置资源创建（Namespace、拉取密钥、NFS StorageClass）
4. Helm 离线 Chart 拉取流程（MinIO 源）
5. Git values 配置规范与渲染说明
6. Helm 完整安装命令（分步执行）
7. 安装后验证全流程（组件、存储、采集、告警、Grafana）
8. 安装失败快速排查指引
9. 关联文档索引

---

# 1. 安装前置环境校验清单
## 1.1 集群基础校验（必须全部通过）
```bash
# 1. K8s 版本校验，锁定 v1.32
kubectl version --short
# Server Version: v1.32.x
root@k8s-master-192-168-122-100:~# kubectl version 
Client Version: v1.32.0
Kustomize Version: v5.5.0
Server Version: v1.32.0

# 2. NFS StorageClass 就绪 nfs-sc
kubectl get sc nfs-sc
# 输出显示 Provisioner 正常，无报错

# 3. 私有 Harbor 连通性 + 镜像拉取 Secret
kubectl get secret harbor-pull-secret -n default
kubectl run test-pull --image=harbor.example.com/library/busybox:latest --rm

root@k8s-master-192-168-122-100:~# kubectl get secrets harbor-pull-secret 
NAME                 TYPE                             DATA   AGE
harbor-pull-secret   kubernetes.io/dockerconfigjson   1      4d20h

# 4. MinIO Chart 存储桶可访问（存放 kube-prometheus-stack-65.1.0.tgz）
root@k8s-master-192-168-122-100:~# mc ls minio/helm-charts/kube-prometheus-stack/kube-prometheus-stack-65.1.0.tgz 
[2026-07-29 17:37:25 CST] 577KiB STANDARD kube-prometheus-stack-65.1.0.tgz

# 5. Git 配置仓库拉取正常（values、CRD、dashboard json）
git clone git@git.example.com:platform/kube-monitor.git
```

## 1.2 资源容量前置规划（参考 10-best-practices/01-resource-planning.md）

- Prometheus StatefulSet：2C4G，PVC 500Gi `nfs-sc`
- Alertmanager StatefulSet：0.5C1G，PVC 20Gi `nfs-sc`
- Grafana Deployment：1C2G，PVC 30Gi `nfs-sc`
- node-exporter DaemonSet：每节点 0.1C128Mi
- kube-state-metrics：0.5C1G

## 1.3 离线资源包校验

MinIO 桶内必须存在 Chart 压缩包：
`kube-prometheus-stack-65.1.0.tgz`

## 1.4 权限前置
执行操作账号拥有集群 admin 权限，可创建 CRD、ClusterRole、PVC、Namespace。

---

# 2. 离线资源前置准备

## 2.1 MinIO 上传 Chart 包（已提前完成，部署仅校验）

1. 外网机器下载官方 Chart
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm pull prometheus-community/kube-prometheus-stack --version 65.1.0
```
2. 使用 `mc` 上传至离线 MinIO
```bash
mc cp kube-prometheus-stack-65.1.0.tgz minio-monitor/charts/
```

## 2.2 全组件镜像离线推送到 Harbor

kube-prometheus-stack 包含镜像清单：
```bash
root@k8s-master-192-168-122-100:~# helm template monitoring kube-prometheus-stack-65.1.0.tgz \
> | grep "image:" \
> | sed 's/.*image: //' \
> | sort -u
"docker.io/bats/bats:v1.4.1"
"docker.io/grafana/grafana:11.2.1"
"quay.io/kiwigrid/k8s-sidecar:1.27.4"
"quay.io/prometheus-operator/prometheus-operator:v0.77.1"
"quay.io/prometheus/alertmanager:v0.27.0"
"quay.io/prometheus/prometheus:v2.54.1"
quay.io/prometheus/node-exporter:v1.8.2
registry.k8s.io/ingress-nginx/kube-webhook-certgen:v20221220-controller-v1.5.1-58-g787ea74b6
registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
```

离线导出镜像，批量导入私有 Harbor，values 中统一替换 `image.repository` 为内网 Harbor 地址。

## 2.3 Git 配置仓库目录说明
```
kube-monitor/
├── values/
│   └── values-prod.yaml      # 生产环境完整 values（存储、RBAC、存储类、镜像源、告警渠道）
├── crd/                      # 自定义监控资源模板（ServiceMonitor/PrometheusRule）
├── dashboards/               # Grafana 自定义大盘 JSON
├── security/                 # NetworkPolicy、RBAC 权限清单
└── scripts/                  # 部署校验、导入脚本
```

---

# 3. 集群前置资源创建（部署第一步）
## 3.1 创建监控专用 Namespace
```bash
kubectl create namespace monitoring
```

## 3.2 绑定全局镜像拉取密钥（所有Pod自动拉取Harbor镜像）
```bash
# 将 default 命名空间的镜像密钥复制至 monitoring
kubectl get secret harbor-pull-secret -n default -o yaml | kubectl apply -n monitoring -f -

# 绑定命名空间默认ServiceAccount
kubectl patch serviceaccount default -n monitoring -p '{"imagePullSecrets": [{"name": "harbor-pull-secret"}]}'
```

## 3.3 校验 NFS StorageClass 全局可用
无需新建，集群已预置 `nfs-sc`，values 中直接引用 `storageClassName: nfs-sc`。

## 3.4 提前创建告警渠道 Secret（钉钉/企业微信 webhook，禁止明文写values）
```bash
kubectl create secret generic alert-webhook-secret -n monitoring \
--from-literal=dingtalk_url="https://oapi.dingtalk.com/robot/send?access_token=xxx"
```

## 3.5 提前创建 Grafana 管理员账号 Secret
```bash
kubectl create secret generic grafana-admin -n monitoring \
--from-literal=admin-user=admin \
--from-literal=admin-password=Monitor@2026
```

---

# 4. Helm 从离线 MinIO 拉取 Chart 包
## 4.1 配置 MinIO 为本地 Helm 仓库
```bash
# 配置 MinIO  helm repo（使用 S3 协议）
helm repo add minio-charts s3://minio-monitor/charts --username=minio-admin --password=MinIO@Pass
helm repo update minio-charts

# 检索离线 Chart
helm search repo minio-charts/kube-prometheus-stack --versions
# 确认输出 65.1.0 版本
```

## 4.2 拉取 Chart 至本地临时目录
```bash
mkdir -p /opt/monitor-chart
helm pull minio-charts/kube-prometheus-stack --version 65.1.0 -d /opt/monitor-chart
tar -zxvf /opt/monitor-chart/kube-prometheus-stack-65.1.0.tgz -C /opt/monitor-chart/
```

---

# 5. Git values 配置说明（values-prod.yaml 核心关键配置）
## 5.1 核心配置项摘要（完整模板在 Git 仓库）
1. 全局镜像仓库替换为内网 Harbor
```yaml
global:
  imageRegistry: harbor.example.com/library
```
2. 统一持久化存储 `nfs-sc`
```yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        storageClassName: nfs-sc
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 500Gi
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        storageClassName: nfs-sc
        resources:
          requests:
            storage: 20Gi
grafana:
  persistence:
    storageClassName: nfs-sc
    size: 30Gi
```
3. 告警渠道引用 Secret，不写明文
4. 开启 Prometheus HA 双副本
5. 开启 RBAC 集群全资源读取权限
6. 内置 node-exporter、kube-state-metrics 启用
7. Grafana 管理员账号引用外部 Secret
8. 配置数据保留周期 `retention: 15d`（参考 03-storage/02-data-retention.md）

## 5.2 配置管理规范
- 禁止本地修改 values，所有变更提交 Git；
- 多环境区分 values-prod / values-uat；
- 所有自定义 ServiceMonitor、PrometheusRule 单独存 Git crd 目录，Chart 安装完成后统一 apply。

---

# 6. Helm 离线完整安装命令
## 6.1 进入 Git 仓库目录，拉取最新配置
```bash
cd /opt/kube-monitor
git pull origin main
VALUES_FILE="./values/values-prod.yaml"
CHART_PATH="/opt/monitor-chart/kube-prometheus-stack"
```

## 6.2 执行 Helm Install（核心部署命令）
```bash
helm install kube-monitor ${CHART_PATH} \
  -n monitoring \
  -f ${VALUES_FILE} \
  --create-namespace \
  --version 65.1.0
```

## 6.3 等待 Chart 组件 Pod 全部就绪
```bash
kubectl get pods -n monitoring -w
# 预期全部状态 Running，无 CrashLoopBackOff
```

## 6.4 导入 Git 托管自定义监控 CRD（业务采集规则、告警规则）
Chart 仅内置基础规则，业务自定义资源统一从 Git 加载：
```bash
# 导入所有 ServiceMonitor、PodMonitor、PrometheusRule
kubectl apply -f ./crd/
# 导入 Grafana 自定义大盘
kubectl apply -f ./dashboards/
# 导入网络安全策略
kubectl apply -f ./security/
```

## 6.5 部署 Ingress 暴露 Grafana / Prometheus WebUI（HTTPS TLS）
```bash
kubectl apply -f ./security/ingress-tls.yaml
```

---

# 7. 安装后全链路验证流程（分步校验）
## 7.1 组件状态校验
```bash
# 1. 校验所有控制器运行正常
kubectl get deploy,statefulset,daemonset -n monitoring

# 2. 校验 CRD 资源已创建
kubectl get crd | grep monitoring.coreos.com

# 3. 校验 PVC 全部绑定 nfs-sc，状态 Bound
kubectl get pvc -n monitoring
```

## 7.2 Prometheus 采集目标校验
```bash
# 进入 Prometheus Web 查看 Targets
kubectl port-forward svc/kube-monitor-prometheus -n monitoring 9090:9090
# 访问 localhost:9090/targets，所有 node-exporter、kubelet、kube-state-metrics UP
```

## 7.3 告警规则校验
```bash
# 查看所有加载的 PrometheusRule
kubectl get prometheusrule -n monitoring
# Prometheus UI → Rules，无加载失败报错
```

## 7.4 Alertmanager 校验
```bash
kubectl port-forward svc/kube-monitor-alertmanager -n monitoring 9093:9093
# 查看路由、抑制、分组配置正常
```

## 7.5 Grafana 可视化校验
1. 通过 HTTPS Ingress 域名登录 Grafana；
2. 校验 Prometheus 数据源自动创建；
3. 校验内置 K8s Node/Pod 大盘正常加载；
4. 校验 Git 自定义业务大盘全部导入。

## 7.6 持久化存储校验
删除 Prometheus Pod，观察重建后历史指标数据不丢失：
```bash
kubectl delete pod kube-monitor-prometheus-0 -n monitoring
# Pod 重建完成后，查询历史指标存在，证明 NFS 挂载持久化生效
```

## 7.7 告警通知渠道验证
手动触发测试告警，验证钉钉/企业微信可正常接收通知。

---

# 8. 安装失败快速排查指引（对应 09-troubleshooting/01-install-error.md）
1. **镜像拉取失败**
   - 检查 harbor-pull-secret 是否复制至 monitoring 命名空间；
   - 校验 values 内 imageRegistry 内网地址正确。
2. **PVC Pending 无法绑定**
   - 查看 NFS StorageClass nfs-sc 配置；
   - 检查 NFS 服务端权限、目录读写权限；参考 09-troubleshooting/03-pvc-error.md
3. Prometheus Operator CrashLoop
   - 校验集群 RBAC 权限、CRD 创建权限；
4. Target 全部 Down
   - 检查 ServiceMonitor labelSelector、namespaceSelector 匹配规则；
5. Alertmanager 告警发送失败
   - 校验 webhook Secret key 名称、接口连通性。

---

# 9. 关联文档索引
1. 顶层架构：01-overview/01-architecture.md / 01-overview/02-component-overview.md
2. 配置参数详解：02-deployment/02-configuration.md
3. 版本升级流程：02-deployment/03-upgrade.md
4. NFS 存储规划：03-storage/01-storage-design.md
5. CRD 使用手册：05-prometheus-operator/ 全套文档
6. 故障排查：09-troubleshooting/01-install-error.md、09-troubleshooting/03-pvc-error.md
7. 资源容量规划：10-best-practices/01-resource-planning.md
8. 安全 TLS 接入：07-security/03-tls-ingress.md