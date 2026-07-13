# 最小 GitOps 案例：Git+Argo CD 同步 Kubernetes 集群

**核心架构**：Git 保存 Kubernetes 期望状态 YAML，Argo CD 持续监听仓库变更，自动同步至 K8s 集群  
**核心场景**：开发提交 nginx 版本修改 → Git 推送 → Argo CD 检测差异 → 自动更新 Kubernetes Deployment

---

## 1. 整体流程

```Plain Text
开发人员修改YAML
       ↓
Git Commit / Push
       ↓
Git仓库(k8s-manifest)
       ↓
Argo CD（持续监听）
       ↓
kubectl apply 自动执行
       ↓
Kubernetes Cluster
       ↓
Pod滚动更新
```

---

## 2. Git 仓库目录结构

```Plain Text
k8s-manifest
├── nginx
│   └── deployment.yaml  # 业务部署资源清单
└── argocd
    └── nginx-app.yaml   # ArgoCD应用同步配置
```

---

## 3. K8s 业务资源 YAML（deployment.yaml）

```Plain Text
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
```

仓库提交命令：

```Plain Text
git add .
git commit -m "deploy nginx"
git push
```

提交后 Git 存储期望状态：`nginx:1.25`

---

## 4. Argo CD 应用配置（nginx-app.yaml）

```Plain Text
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx
spec:
  # 关联Git配置仓库
  source:
    repoURL: https://git.example.com/k8s-manifest.git
    path: nginx
  # 目标部署集群与命名空间
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  # 自动同步、清理、自愈策略
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

应用生效命令：

```Plain Text
kubectl apply -f nginx-app.yaml
```

---

## 5. Argo CD 首次同步流程

1. 检测：Argo CD 监听 Git 仓库，发现存在 nginx 部署配置，集群无对应资源
2. 执行：自动执行 `kubectl apply` 应用配置
3. 结果：集群创建 nginx Deployment、对应 Pod 资源

---

## 6. 版本更新自动同步流程

1. 开发修改镜像版本（状态变更）

原配置：`image: nginx:1.25` → 修改为：`image: nginx:1.26`

2. 推送变更至远端仓库

```Plain Text
git commit -m "upgrade nginx"
git push
```

3. Argo CD 差异检测

Git 期望状态：`nginx:1.26`｜集群实际状态：`nginx:1.25`，识别状态不一致

4. 自动执行更新：触发 K8s 滚动更新，删除旧 Pod、拉起新版本 Pod

---

## 7. GitOps 自愈能力（防集群手动篡改）

场景：人为直接修改集群资源 `kubectl edit deployment nginx`，将镜像改为 `nginx:latest`

状态对比：

- Git 基准状态：`nginx:1.26`（唯一可信源）
- 集群实际状态：`nginx:latest`
- Argo CD 判定：资源状态 **OutOfSync（不同步）**

自愈结果：Argo CD 自动重新应用 Git 配置，将集群镜像恢复为 `nginx:1.26`

**核心逻辑**：Git 存储最终期望状态，K8s 集群被动对齐 Git 基准，杜绝集群手动变更

---

## 8. 最小运行组件及作用

|组件|核心作用|
|---|---|
|Git(GitHub/GitLab)|存储K8s资源声明式配置，作为唯一真实数据源|
|Argo CD|状态同步器，监听Git变更、对比集群状态、自动对齐自愈|
|Kubernetes|业务最终运行环境，接收Argo CD的标准化配置变更|

---

## 9. GitOps 与传统 CI/CD 发布区别

### 传统 CI/CD 流程

开发 → CI 构建 → 直接执行 kubectl apply → K8s 集群  
**弊端**：CI 持有集群权限，变更无统一版本追溯，易出现集群配置漂移

### GitOps 流程

开发 → Git 提交留存变更 → Argo CD 自动同步 → K8s 集群

**核心优势**：

- 所有配置变更留存 Git，可追溯、可回滚
- 集群权限仅授权 Argo CD，规避人为误操作
- 禁止直接操作生产集群，所有变更标准化、流程化
- 自带状态自愈，保障集群配置与期望状态一致

**GitOps 核心定义**：并非通过 Git 直接发布，而是**以 Git 为唯一期望状态源头，由 Argo CD 持续驱动 K8s 集群实际状态与期望状态一致**。

