# Deployment 实战管理规范（03\-deployment\-management\.md）Ubuntu22\.04 离线生产版

## 1\. 文档说明（实战导向）

本文摒弃冗余理论，聚焦 **生产环境 Deployment 日常运维全实操**，适配 Ubuntu22\.04、K8s v1\.32、离线 Harbor 集群。覆盖：标准创建、灰度发布、版本更新、暂停/恢复发布、扩缩容、重建重启、下线删除、生产踩坑、故障速排。所有命令、YAML 模板**可直接生产复用**，为无状态业务唯一标准运维文档。

**适用业务**：Web 服务、API 网关、微服务、后台常驻无状态业务。

**核心特性**：滚动更新、零停机发布、多版本回溯、自愈重建，生产无状态业务**强制使用 Deployment**，禁止裸 Pod 运行。

## 2\. 生产标准 Deployment YAML 模板（直接复用）

生产上线**必须严格套用此模板**，包含资源限制、全套探针、优雅终止、滚动更新策略，适配离线生产环境。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: prod-api
  labels:
    app: api-service
    env: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
  # 生产滚动更新核心策略
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  # 保留历史版本数（用于回滚）
  revisionHistoryLimit: 10
  # 禁止自动扩缩容外的无效调度
  progressDeadlineSeconds: 600
  template:
    metadata:
      labels:
        app: api-service
    spec:
      # 生产常驻业务固定重启策略
      restartPolicy: Always
      containers:
      - name: api-service
        image: harbor.offline.com/prod/api-service:v1.0.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        # 资源配额约束（生产必填）
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 512Mi
        # 全套生产探针（零停机发布核心）
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 2
        startupProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 20
        # 优雅停机（杜绝连接报错）
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh","-c","sleep 3"]

```

**生产关键参数解释**：

- `maxUnavailable: 0`：发布过程**保证业务不降级、不丢实例**

- `maxSurge: 1`：最多超配1个实例，平稳灰度

- `revisionHistoryLimit: 10`：保留10个历史版本，支持随时回滚

- `IfNotPresent`：适配离线环境，优先本地镜像，无需外网拉取

## 3\. 日常实操命令（生产高频）

### 3\.1 创建/应用 Deployment

```bash
# 标准创建/更新
kubectl apply -f deployment-api.yaml -n prod-api

# 快速查看状态
kubectl get deploy -n prod-api
kubectl get pods -n prod-api -o wide

```

### 3\.2 查看详细发布状态

```bash
# 查看发布进度、版本、就绪数
kubectl rollout status deploy api-service -n prod-api

# 查看历史版本记录
kubectl rollout history deploy api-service -n prod-api

# 查看指定版本详细变更内容
kubectl rollout history deploy api-service --revision=2 -n prod-api

```

### 3\.3 镜像版本更新（生产灰度发布唯一方式）

```bash
# 离线环境更新镜像版本，触发滚动发布
kubectl set image deploy api-service api-service=harbor.offline.com/prod/api-service:v1.0.1 -n prod-api

# 实时盯发布进度
kubectl rollout status deploy api-service -n prod-api

```

### 3\.4 扩缩容实操

```bash
# 手动扩容至5副本
kubectl scale deploy api-service --replicas=5 -n prod-api

# 手动缩容至2副本（低峰操作）
kubectl scale deploy api-service --replicas=2 -n prod-api

```

### 3\.5 业务重启实操（生产优雅重启）

```bash
# 优雅滚动重启（不丢业务、不中断服务）
kubectl rollout restart deploy api-service -n prod-api

```

### 3\.6 暂停/恢复发布（紧急冻结变更）

```bash
# 暂停发布（暂停所有更新、冻结版本）
kubectl rollout pause deploy api-service -n prod-api

# 恢复发布
kubectl rollout resume deploy api-service -n prod-api

```

### 3\.7 下线删除 Deployment

```bash
# 仅删除当前Deployment，保留命名空间、配置
kubectl delete deploy api-service -n prod-api

# 彻底清空该命名空间所有业务（下线专用）
kubectl delete ns prod-api

```

## 4\. 生产零停机发布核心流程（标准上线步骤）

所有生产版本迭代**必须严格执行此步骤**，禁止暴力重建、删除Pod。

1. **发布前校验**：确认当前集群Pod全部就绪、无重启、无报错日志

2. **执行镜像更新**：kubectl set image 触发滚动更新

3. **实时监控进度**：rollout status 观察发布完成

4. **业务校验**：核对接口可用性、日志、QPS、错误率

5. **留存版本**：确认无误后留存历史版本，用于紧急回滚

## 5\. 版本回滚实战（生产紧急兜底）

### 5\.1 快速回滚上一个版本

```bash
kubectl rollout undo deploy api-service -n prod-api

```

### 5\.2 回滚至指定历史版本

```bash
# 先查看版本列表
kubectl rollout history deploy api-service -n prod-api

# 回滚指定revision版本
kubectl rollout undo deploy api-service --revision=3 -n prod-api

```

**实战要点**：回滚后必须观察3分钟，确认Pod就绪、业务无报错、日志正常。

## 6\. 生产高频故障排查（实战速排）

### 6\.1 发布卡住、长时间更新不完

**现象**：新Pod无法就绪、滚动更新停滞、新旧Pod并存

**根因**：就绪探针失败、端口占用、配置错误、镜像缺失

**排查命令**：

```bash
kubectl describe deploy api-service -n prod-api
kubectl describe pod <异常pod> -n prod-api
kubectl logs <异常pod> -n prod-api

```

### 6\.2 业务频繁重启

**根因**：存活探针超时、OOM内存溢出、程序死锁、配置加载失败

**处理**：查看容器退出日志、调整资源limit、优化探针参数、修复程序bug

### 6\.3 离线环境镜像拉取失败

**根因**：镜像未上传内网Harbor、镜像标签错误、imagePullPolicy配置不当

**处理**：统一使用 `IfNotPresent`，提前预推镜像至离线仓库

### 6\.4 发布后部分Pod就绪失败

**根因**：ConfigMap/Secret挂载异常、初始化脚本失败、权限不足

**处理**：核对配置文件完整性、目录权限、初始化命令

## 7\. 生产红线（强制禁止）

- 禁止生产无状态业务使用裸Pod、StatefulSet托管

- 禁止生产Deployment不配置资源requests/limits，防止资源抢占

- 禁止关闭探针、关闭优雅停机，导致发布报错、连接中断

- 禁止暴力删除Deployment重建发布，必须使用滚动更新

- 禁止生产发布开启 `maxUnavailable>0`，避免发布降级

- 禁止离线环境使用 `Always` 镜像拉取策略，引发拉取失败

## 8\. 关联实战文档

- 滚动发布管理：`11-rollout-management.md`

- 版本回滚实战：`12-rollback-management.md`

- 工作负载排障：`15-workload-troubleshooting.md`

- Pod生命周期与探针规范：`02-pod-lifecycle.md`

> （注：部分内容可能由 AI 生成）
