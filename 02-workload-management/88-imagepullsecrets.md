# 私有仓库镜像凭证配置 ImagePullSecrets（08-imagepullsecrets.md）Ubuntu22.04 离线生产版

## 1. 文档概述

### 1.1 文档定位

本文属于**集群初始化（cluster-init）**后置配置规范，Kubernetes 官方推荐私有镜像仓库认证方案。用于解决内网 Harbor/私有镜像仓库**镜像私有、需要账号密码授权拉取镜像**问题，统一集群镜像凭证管理标准。

### 1.2 适用场景

- 内网私有 Harbor 仓库，镜像设置私有权限，节点无法直接拉取镜像
- 多命名空间、多业务统一私有仓库凭证配置
- 工作负载（Deployment/StatefulSet/DaemonSet）私有镜像启动
- 集群初始化阶段全局配置默认仓库拉取凭证

### 1.3 方案选型说明

- **推荐方案：ImagePullSecrets（本文方案）**：K8s 官方标准方案、资源隔离、权限可控、命名空间隔离、无节点全局污染，生产首选
- 备选方案：节点 docker/containerd 登录仓库：节点全局生效、权限不可控、多租户不安全，**生产禁止优先使用**

## 2. 原理说明

ImagePullSecrets 本质是 `kubernetes.io/dockerconfigjson` 类型 Secret：存储私有仓库域名、登录账号、密码；Pod 调度拉取镜像时，kubelet 自动携带该 Secret 认证信息访问私有仓库，完成镜像拉取。  
特性：**命名空间级别资源，仅同命名空间 Pod 可以引用**，跨 NS 无法直接复用。

## 3. 方法一：Kubernetes 官方标准方案（ImagePullSecret）

流程：创建仓库认证 Secret → 工作负载/Pod 绑定凭证拉取私有镜像

### 3.1 创建 Docker 仓库认证 Secret（核心命令）

在**业务所在命名空间**执行创建命令（直接复制生产执行）

```bash
# 创建私有Harbor仓库拉取凭证 secret
kubectl create secret docker-registry harbor-secret \
  --docker-server=harbor.jinshaoyong.com \
  --docker-username=dev \
  --docker-password='Sage@123' \
  -n default
```

#### 参数释义

- `docker-registry`：固定Secret类型，docker仓库认证专用
- `harbor-secret`：secret名称，全局自定义，业务绑定使用该名称
- `docker-server`：内网Harbor仓库域名/IP，必须和镜像完整域名一致
- `docker-username/docker-password`：Harbor仓库项目授权账号密码
- `-n`：指定业务命名空间，Secret 隔离生效

### 3.2 YAML格式创建（留存备份，集群初始化推荐）

集群初始化建议留存yaml文件，方便批量重建、环境复刻

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-secret
  namespace: default
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: eyJhdB9yZG9ja2VyLmppbnNoYW95b25nLmNvbSI6eyJ1c2VybmFtZSI6ImRldiIsInBhc3N3b3JkIjoi5L2g5oWV5Lmg5pawIn19

```

### 3.3 Pod/工作负载绑定凭证使用

Pod Spec 层级配置 **imagePullSecrets**，控制器全部通用（Deployment/StatefulSet/DaemonSet）

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: private-api-pod
  namespace: default
spec:
  # 核心配置：绑定私有仓库拉取凭证（官方标准字段）
  imagePullSecrets:
  - name: harbor-secret
  containers:
  - name: api-service
    image: harbor.jinshaoyong.com/prod/api-service:v1.0.0

```

### 3.4 Deployment 生产业务完整绑定示例

适配前文 **03-deployment-management.md** 生产模板，直接嵌入使用

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
  template:
    spec:
      # 全局Pod绑定镜像拉取密钥
      imagePullSecrets:
      - name: harbor-secret
      containers:
      - name: api-service
        image: harbor.jinshaoyong.com/prod/api-service:v1.0.0

```

## 4. 进阶：集群全局默认生效（集群初始化必配）

逐个业务绑定过于繁琐，集群初始化阶段配置**命名空间默认ServiceAccount绑定ImagePullSecrets**，该命名空间下**所有Pod自动复用凭证，无需逐个配置**

### 4.1 绑定默认服务账号

```bash
# 编辑命名空间默认sa
kubectl edit sa default -n default

```

### 4.2 添加镜像凭证

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: default
# 添加全局镜像拉取密钥
imagePullSecrets:
- name: harbor-secret

```

✅ 生效效果：当前命名空间下所有新建Pod、控制器**无需配置imagePullSecrets字段，自动拉取私有Harbor镜像**

## 5. 日常运维实操命令

```bash
# 查看创建的镜像凭证Secret
kubectl get secret harbor-secret -n default

# 查看secret详细配置
kubectl describe secret harbor-secret -n default

# 删除过期镜像凭证
kubectl delete secret harbor-secret -n default

```

## 6. 生产环境约束与红线规范

- **生产强制优先使用 ImagePullSecrets 官方方案**，禁止全部节点登录私有仓库做全局认证
- Secret 按命名空间隔离配置，禁止放到 kube-system/default 全局命名空间滥用
- Harbor弱密码、高危账号禁止写入集群ImagePullSecret，遵循最小权限原则
- 仓库密码变更后，同步更新集群harbor-secret，否则镜像拉取失败
- 离线生产集群，配合 `IfNotPresent` 镜像策略使用，提升发布稳定性

## 7. 常见故障排错

### 7.1 报错：ImagePullBackOff / ErrImagePull 401 Unauthorized

根因：账号密码错误、secret跨命名空间引用、仓库域名不匹配  
解决：重新执行创建命令更新密码；同命名空间引用；保证docker-server和镜像域名完全一致

### 7.2 报错：secret not found

根因：Pod和Secret不在同一个命名空间；Secret名称填写错误  
解决：同NS创建并引用；核对secret名称

### 7.3 SA绑定全局凭证不生效

根因：存量Pod不会自动生效，仅新建Pod生效；重建存量业务Pod即可

## 8. 关联文档

- 集群全局初始化基线：`00-cluster-init-readme.md`
- Deployment生产管理规范：`03-deployment-management.md`
- 私有Harbor仓库部署规范：`07-offline-harbor.md`

