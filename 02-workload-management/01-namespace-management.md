# 01-namespace-management.md

## 一、文档基础信息

- 归属目录：`02-workload-management/`
- 前置阅读：`02-workload-management/00-README.md`
- 集群环境：Kubernetes v1.32.13 单Master集群，内网Harbor镜像仓库
- 核心范围：Namespace原理、生命周期管理、资源配额、四层环境隔离规范、清理回收、安全规范、故障排查

## 二、Namespace 底层原理

### 2.1 定义

Namespace 是K8s内置**资源逻辑隔离单元**，用于在同一集群内划分独立资源分组，实现多环境、多业务、多团队隔离。  
Namespace 的实际价值主要是资源隔离、权限隔离、资源管理和生命周期管理。它不是物理隔离，而是 Kubernetes API 层面的逻辑隔离。
底层本质：

1. 所有带namespace字段的资源（Pod/Deployment/Service/ConfigMap/PVC等）隶属于某一个命名空间；
2. Cluster级资源（Node/CRD/ClusterRole/StorageClass）**不归属任何namespace**，全局共享；
3. 不同Namespace内同名资源互不冲突，例如 `fat/nginx` 和 `prod/nginx` 是两套独立工作负载。

| 价值          | 一句话说明                                             |
| ----------- | ------------------------------------------------- |
| **资源隔离**    | 将不同业务、环境或团队的 Kubernetes 资源逻辑分组，避免资源混杂。            |
| **名称隔离**    | 允许不同 Namespace 内创建同名资源，避免资源名称冲突。                  |
| **权限隔离**    | 通过 RBAC 控制用户或团队只能管理指定 Namespace 内的资源。             |
| **资源配额管理**  | 通过 ResourceQuota 限制 Namespace 的 CPU、内存、对象数量等资源使用。 |
| **网络隔离**    | 结合 NetworkPolicy 控制不同 Namespace 之间的网络访问权限。        |
| **生命周期管理**  | 通过 Namespace 统一管理业务资源的创建、删除和回收。                   |
| **监控与成本统计** | 按 Namespace 聚合资源指标，实现业务监控、容量分析和成本核算。              |
| **系统组件隔离**  | 将 Kubernetes 系统组件与业务应用分离，提升集群管理清晰度。               |

### 2.2 集群内置默认命名空间

```
# 1. default
未指定namespace时资源默认创建在此，临时测试使用，业务禁止部署于此
# 2. kube-system
集群核心系统组件：calico、coredns、metrics-server、kube-proxy，集群内部组件专用
# 3. kube-public
公共只读资源，存放集群公共ConfigMap，所有用户可读
# 4. kube-node-lease
节点心跳租约资源，kubelet自动维护，禁止人工操作
```

### 2.3 隔离边界说明
1. **资源隔离**：Pod、Service、Deployment、Secret、PVC等资源互相隔离；
2. **网络不隔离**：同集群所有Namespace Pod互通，如需网络隔离需搭配Calico NetworkPolicy；
3. **权限隔离**：配合RBAC，限制用户仅能操作指定Namespace；
4. **资源配额隔离**：绑定ResourceQuota/LimitRange，限制单Namespace最大CPU/内存/Pod数量。

## 三、四层环境划分标准（核心设计：DEV本地 + FAT测试 + UAT预生产 + PROD生产）
### 3.1 环境分层说明
1. **DEV（本地开发环境，不在集群内）**
   - 载体：开发人员本地PC、Docker Desktop、本地Kind/minikube
   - 用途：代码调试、本地自测、单元测试，**不上集群**
   - 约束：无集群Namespace，不占用集群资源，数据仅本地留存

2. **FAT（功能测试环境，集群命名空间：fat）**
   - 使用人群：研发、测试工程师
   - 用途：完整功能联调、自动化用例、迭代版本测试
   - 数据：模拟测试数据，每日定时清理重置
   - 准入：开发提测镜像，完成单元测试后部署至fat

3. **UAT（用户验收预生产环境，集群命名空间：uat）**
   - 使用人群：测试、产品、业务验收人员
   - 用途：完全复刻生产配置、流量模型、中间件规格，业务全流程验收
   - 数据：脱敏生产仿真数据，每周重置一次
   - 准入：FAT全量用例通过后，同步镜像与配置至uat

4. **PROD（线上生产环境，集群命名空间：prod）**
   - 使用人群：运维管理员，仅极小范围授权
   - 用途：对外提供真实业务服务，承载真实用户流量
   - 数据：真实业务核心数据，禁止随意重置、删除
   - 准入：UAT验收通过、发布评审完成后灰度上线

### 3.2 集群Namespace标准清单
| Namespace名称 | 环境层级 | 访问权限 | 资源配额松紧 | 数据生命周期 |
|--------------|----------|----------|--------------|--------------|
| fat | 功能测试 | 研发+测试可读写 | 宽松，上限中等 | 每日自动清空回收 |
| uat | 预生产验收 | 测试只读、运维可读写 | 中等，对齐生产规格 | 每周重置数据 |
| prod | 线上生产 | 仅运维管理员读写 | 严格，资源上限高、限制严谨 | 长期持久，禁止自动清理 |

### 3.3 统一标签规范（所有业务ns强制打标）
```yaml
metadata:
  labels:
    env: fat/uat/prod
    business: order/user/pay
    owner: ops@shturl.
```

## 四、Namespace 基础生命周期管理
### 4.1 创建命名空间（两种方式）
#### 方式1：命令行快速批量创建四层集群环境ns
```bash
# 一次性创建fat/uat/prod
for ns in fat uat prod;do kubectl create ns $ns;done
```

#### 方式2：声明式YAML（生产推荐，纳入版本管理）
```yaml
# ns-fat.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: fat
  labels:
    env: fat
    business: common
```
```bash
kubectl apply -f ns-fat.yaml
# 同理创建uat.yaml、prod.yaml
```

### 4.2 查看命名空间清单
```bash
# 全部命名空间
kubectl get ns
# 按环境标签过滤
kubectl get ns -l env=prod
# 查看完整资源定义
kubectl get ns fat -o yaml
```

### 4.3 切换kubectl默认操作环境
```bash
# 默认操作fat环境
kubectl config set-context --current --namespace=fat
# 切换至预生产uat
kubectl config set-context --current --namespace=uat
# 切换生产prod
kubectl config set-context --current --namespace=prod

# 查看当前默认环境
kubectl config view | grep namespace
```

### 4.4 删除命名空间（高危分级管控）
**`删除Namespace会级联删除内部所有资源（Pod/Deployment/Service/PVC/Secret等），不可恢复。`**
1. fat环境：测试可自行删除重建，风险低
2. uat环境：需测试负责人确认后执行
3. prod环境：双人复核、提前备份etcd快照+全资源yaml才可执行

```bash
# 删除测试fat命名空间
kubectl delete ns fat
```

#### 删除卡死解决方案（存在Finalizer阻塞）
```bash
kubectl edit ns 卡住的命名空间名称
# 删除spec.finalizers数组内所有内容，保存后自动回收
```

## 五、分环境资源配额管控（ResourceQuota + LimitRange）
### 5.1 LimitRange：容器默认资源约束
所有环境强制部署，防止容器无限制抢占节点资源
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: fat
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    max:
      cpu: "4"
      memory: "8Gi"
    type: Container
```

### 5.2 ResourceQuota 分环境配额标准
#### fat（测试宽松配额）
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota
  namespace: fat
spec:
  hard:
    pods: "80"
    requests.cpu: "16"
    requests.memory: 32Gi
    limits.cpu: "32"
    limits.memory: 64Gi
    persistentvolumeclaims: "30"
```

#### uat（预生产对齐生产规格，中等配额）
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota
  namespace: uat
spec:
  hard:
    pods: "50"
    requests.cpu: "12"
    requests.memory: 24Gi
    limits.cpu: "24"
    limits.memory: 48Gi
    persistentvolumeclaims: "20"
```

#### prod（生产严格配额，保障稳定性）
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota
  namespace: prod
spec:
  hard:
    pods: "40"
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    persistentvolumeclaims: "15"
```

### 5.3 查看配额占用
```bash
kubectl describe resourcequota ns-quota -n fat
kubectl get resourcequota --all-namespaces
```

## 六、分环境资源自动回收规范
### 6.1 FAT环境：每日自动清空所有业务资源
```bash
#!/bin/bash
# /usr/local/src/post-install/workload/clean-fat.sh
NS=fat
kubectl delete deploy,sts,ds,job,cronjob,svc,ingress,cm,secret,pvc -n ${NS} --all
echo "FAT环境资源已每日清空完成"
```
配置定时任务每日凌晨2点执行，重置测试环境数据。

### 6.2 UAT环境：每周日凌晨全量重置
同清理脚本，仅执行周期改为每周一次，保留一周验收数据。

### 6.3 PROD环境：禁止自动清理
仅人工按需删除闲置负载，删除前必须导出资源备份、执行etcd快照。

### 6.4 单环境快速清空（保留Namespace不删除）
```bash
# 清空uat所有业务资源
kubectl delete all,cm,secret,pvc -n uat --all
```

## 七、四层环境安全隔离规范

1. **DEV本地环境隔离**
   开发本地仅用于自测，镜像禁止推送生产Harbor，本地数据不与集群互通，不接入内网中间件。
2. **FAT测试环境权限**
   研发、测试账号授予fat命名空间edit权限，禁止访问uat/prod；
   测试数据库、Redis与预生产/生产完全隔离，不共享实例。
3. **UAT预生产环境权限**
   测试人员仅view只读权限，仅运维拥有编辑发布权限；
   网络层面通过NetworkPolicy禁止fat环境Pod访问uat中间件。
4. **PROD生产环境权限（最高安全等级）**
   - 仅运维管理员拥有操作权限；
   - 所有变更走发布流程，禁止临时kubectl操作；
   - NetworkPolicy拦截fat/uat主动访问prod数据库、缓存；
   - 删除prod资源、命名空间必须双人复核+提前全量备份。
5. **Secret密钥隔离**
   fat/uat/prod三套独立密钥，严禁跨环境复用敏感配置、数据库账号密码。

## 八、常用操作速查
```bash
# 批量创建集群三层环境ns
for ns in fat uat prod;do kubectl create ns $ns;done

# 导出单环境全量资源备份（发布/删除前必执行）
kubectl get all,cm,secret,pvc -n prod -o yaml > /usr/local/src/post-install/workload/backup/prod-$(date +%Y%m%d).yaml

# 批量查看各环境Pod数量
for ns in fat uat prod;do echo "==== ${ns} ====";kubectl get pods -n ${ns} | wc -l;done
```

## 九、常见故障排查
1. **创建Pod提示 `exceeded quota`**
   当前Namespace ResourceQuota资源耗尽，清理闲置负载或上调对应环境配额。
2. **删除Namespace长时间Terminating卡死**
   存在资源Finalizer阻塞，编辑资源/ns清空finalizer字段即可释放。
3. **研发无法操作uat/prod**
   RBAC权限仅绑定fat命名空间，需单独申请uat只读权限，生产仅运维开放。
4. **fat Pod能连通prod数据库**
   未配置NetworkPolicy网络隔离，补充策略限制跨环境访问。
5. **LimitRange未自动填充容器资源**
   对应命名空间未部署LimitRange资源，重新apply对应yaml。

## 十、关联文档
1. 上层总览：`00-README.md` 工作负载管理目录介绍
2. 资源管控配套：`07-resource-management.md` 配额完整详解
3. 权限绑定：`05-kubeconfig-management/04-user-kubeconfig.md` 按环境划分权限用户
4. 网络隔离补充：`06-cni-calico.md` NetworkPolicy跨环境访问控制
5. 数据备份兜底：`etcd-backup.md` 生产变更前置快照规范
6. 故障汇总：`10-workload-troubleshooting.md`