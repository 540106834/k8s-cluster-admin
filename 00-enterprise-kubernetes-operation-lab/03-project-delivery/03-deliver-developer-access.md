# deliver-developer-access.md

## 开发人员RBAC权限、KubeConfig交付标准化操作手册

## 一、文档定位

本文针对企业K8s多环境集群，完成**开发人员最小权限RBAC授权、自定义ServiceAccount、用户kubeconfig生成、多环境权限隔离、权限回收**全流程标准化SOP；区分dev/uat/prod三套环境权限边界，遵循零信任最小权限原则，配套项目命名空间交付流程。  
前置依赖：  
create-project-workspace.md｜项目Namespace创建  
enable-private-image-access.md｜镜像拉取权限配置  
validate-project-environment.md｜项目环境验收  
下游关联：validate-project-environment.md、configure-project-resource-policy.md

## 二、权限设计核心规范

### 2.1 环境权限隔离原则

1. **dev开发环境**：完整读写权限，允许创建/删除Pod、Deployment、ConfigMap、调试容器exec/logs
2. **uat测试环境**：只读基础资源+有限写权限，禁止删除核心业务实例，仅允许重启、扩缩容
3. **prod生产环境**：**仅只读权限**，禁止任何写操作（创建/删除/重启Pod），仅运维管理员具备修改权限
4. 禁止开发人员跨环境访问，开发账号无法操作prod命名空间

### 2.2 最小权限RBAC模型

三层资源绑定：

1. ServiceAccount：集群内代表用户身份的账号
2. Role：单命名空间内权限规则（细分dev/uat/prod三套角色）
3. RoleBinding：将ServiceAccount与Role绑定，授予命名空间操作权限

### 2.3 角色权限划分模板

#### 1）DevDeveloper 开发角色（dev命名空间读写）

允许：

- 增删改查：Pod、Deployment、StatefulSet、ConfigMap、Secret、Service、Ingress
- 容器操作：kubectl exec、logs、port-forward调试
- 查看：Event、PV、PVC、NetworkPolicy
禁止：
- 删除Namespace、修改ResourceQuota/LimitRange、集群级CRD、节点操作

#### 2）UatTester 测试角色（uat命名空间读写受限）

允许：

- 查看所有资源、重启Deployment、调整副本数、查看日志/exec
禁止：
- 删除Deployment/StatefulSet、删除PVC、修改网络策略、修改配额

#### 3）ProdViewer 生产只读角色（prod命名空间纯查看）

仅允许：get/list/watch所有资源、查看日志、exec只读查询容器
禁止：所有写操作（create/update/patch/delete）

## 三、前置准备信息

1. 开发人员唯一标识：用户名 `dev-user`
2. 目标项目命名空间：`dev` / `uat-user-api` / `prod-user-api`
3. 集群APIServer访问地址、集群CA证书
4. 集群管理员cluster-admin权限执行授权操作

## 四、步骤1：创建开发人员全局ServiceAccount（集群级别）

每个开发人员一个独立SA，全局唯一，区分人员身份

```bash
# 命名规范：sa-{用户名}
export USER_NAME=dev-user
kubectl create sa $USER_NAME -n kube-system
# 添加人员标签便于权限管理
kubectl label sa $USER_NAME -n kube-system user=$USER_NAME department=business
```

## 五、步骤2：创建命名空间内Role权限模板

### 5.1 DevDeveloper 角色模板（dev命名空间）

dev-role.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-developer
  namespace: dev
rules:
# 核心业务资源全读写
- apiGroups: ["","apps","networking.k8s.io"]
  resources:
  - pods,deployments,statefulset,services,ingress,configmaps,secrets,persistentvolumeclaims
  verbs: ["create","list","get","watch","update","patch","delete"]
# 容器调试权限
- apiGroups: [""]
  resources: ["pods/exec","pods/log","pods/portforward"]
  verbs: ["create"]
# 查看事件存储
- apiGroups: [""]
  resources: ["events","persistentvolumes"]
  verbs: ["list","get","watch"]
```

### 5.2 UatTester 受限测试角色（uat）

uat-role.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: uat-tester
  namespace: uat-user-api
rules:
# 全部资源只读
- apiGroups: ["","apps","networking.k8s.io"]
  resources: ["*"]
  verbs: ["list","get","watch"]
# 允许重启、扩缩容，禁止删除
- apiGroups: ["apps"]
  resources: ["deployments","statefulsets"]
  verbs: ["update","patch"]
# 容器调试
- apiGroups: [""]
  resources: ["pods/exec","pods/log"]
  verbs: ["create"]
```

### 5.3 ProdViewer 生产只读角色（prod）

prod-role.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prod-viewer
  namespace: prod-user-api
rules:
- apiGroups: ["","apps","networking.k8s.io"]
  resources: ["*"]
  verbs: ["list","get","watch"]
# 仅日志、只读exec查询
- apiGroups: [""]
  resources: ["pods/log","pods/exec"]
  verbs: ["create"]
```

## 六、步骤3：RoleBinding 将SA绑定对应命名空间角色

### 6.1 开发人员绑定dev开发全权限

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-user-bind-dev
  namespace: dev
subjects:
- kind: ServiceAccount
  name: dev-user
  namespace: kube-system
roleRef:
  kind: Role
  name: dev-developer
  apiGroup: rbac.authorization.k8s.io
```

### 6.2 绑定uat测试受限权限

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-user-bind-uat
  namespace: uat-user-api
subjects:
- kind: ServiceAccount
  name: dev-user
  namespace: kube-system
roleRef:
  kind: Role
  name: uat-tester
  apiGroup: rbac.authorization.k8s.io
```

### 6.3 生产环境仅绑定只读查看权限

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-user-bind-prod
  namespace: prod-user-api
subjects:
- kind: ServiceAccount
  name: dev-user
  namespace: kube-system
roleRef:
  kind: Role
  name: prod-viewer
  apiGroup: rbac.authorization.k8s.io
```

### 批量执行创建

```bash
kubectl apply -f dev-role.yaml -f uat-role.yaml -f prod-role.yaml
kubectl apply -f dev-binding.yaml -f uat-binding.yaml -f prod-binding.yaml
```

## 七、步骤4：提取ServiceAccount Token，生成用户kubeconfig配置文件

### 7.1 提取SA永久token

```bash
export USER_NAME=dev-user
# 获取自动创建的secret名称（sa对应token secret）
SECRET_NAME=$(kubectl get sa $USER_NAME -n kube-system -o jsonpath="{.secrets[0].name}")
# 提取token内容
SA_TOKEN=$(kubectl get secret $SECRET_NAME -n kube-system -o jsonpath="{.data.token}" | base64 --decode)
# 提取集群CA证书
CA_CERT=$(kubectl config view --raw -o jsonpath="{.clusters[0].cluster.certificate-authority-data}")
# APIServer地址
APISERVER=$(kubectl config view --raw -o jsonpath="{.clusters[0].cluster.server}")
```

### 7.2 生成独立kubeconfig（交付给开发人员）

```bash
# 新建用户配置文件
cat > ./kubeconfig-$USER_NAME.yaml << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: $APISERVER
    certificate-authority-data: $CA_CERT
  name: k8s-cluster
contexts:
- context:
    cluster: k8s-cluster
    user: $USER_NAME
    namespace: dev # 默认打开开发命名空间
  name: $USER_NAME-context
current-context: $USER_NAME-context
users:
- name: $USER_NAME
  user:
    token: $SA_TOKEN
EOF
```

### 7.3 权限验证（管理员提前校验，再交付开发）

```bash
# 切换dev命名空间，测试创建Pod（应成功）
KUBECONFIG=./kubeconfig-dev-user.yaml kubectl create ns test-demo
# 切换prod命名空间，测试删除Pod（应返回403禁止）
KUBECONFIG=./kubeconfig-dev-user.yaml kubectl delete pod xxx -n prod-user-api
# 查看权限校验工具
kubectl auth can-i delete deployments -n prod-user-api --kubeconfig ./kubeconfig-dev-user.yaml
```

## 八、步骤5：交付开发人员使用说明

1. 交付文件：`kubeconfig-dev-user.yaml`
2. 使用方式：
   - Linux/Mac：复制至 `~/.kube/config`
   - Windows：kubectl指定环境变量 `$env:KUBECONFIG="kubeconfig.yaml"`
3. 权限边界告知：
   - dev：可随意增删调试资源
   - uat：不可删除核心业务
   - prod：仅能查看日志，禁止任何修改操作
4. 工具适配：IDE（K8s插件）、kubectl、kubecm、Lens均可加载该配置

## 九、权限回收流程（人员离职/调岗）

### 9.1 立即回收权限（阻断所有操作）

1. 删除所有RoleBinding绑定关系
```bash
kubectl delete rolebinding dev-user-bind-dev -n dev
kubectl delete rolebinding dev-user-bind-uat -n uat-user-api
kubectl delete rolebinding dev-user-bind-prod -n prod-user-api
```
2. 删除ServiceAccount，旧kubeconfig token立即失效
```bash
kubectl delete sa dev-user -n kube-system
```

### 9.2 归档记录人员权限回收操作日志，留存审计

## 十、高频权限故障排查

### 故障1：kubectl操作返回Error: Forbidden 403

根因：未绑定对应RoleBinding、Role缺少对应verbs操作权限、命名空间错误
排查：
```bash
# 校验是否具备对应操作权限
kubectl auth can-i create pods -n dev --kubeconfig 用户配置
# 查看当前用户绑定的角色
kubectl describe rolebinding -n dev | grep 用户名
```

### 故障2：开发人员无法kubectl exec进入容器

根因：Role缺少 `pods/exec` 子资源create权限
修复：在rules中补充对应子资源权限

### 故障3：uat环境开发可以删除Deployment

根因：uat角色verbs包含delete，需要移除delete仅保留update/patch

### 故障4：kubeconfig token失效，认证失败

根因：对应ServiceAccount被删除、关联Secret被删除，重新创建SA生成配置文件

### 故障5：开发人员可以查看集群全部Secret

根因：Role规则未细分资源，通配符*包含secrets，按需缩小资源范围

## 十一、生产运维标准化规范

1. 一人一独立ServiceAccount，禁止多人共用同一个权限配置文件
2. 严格区分三套环境权限，生产环境仅开放只读权限，杜绝开发修改生产资源
3. 权限遵循最小权限原则，不使用通配符全开权限，按需开放资源与verbs
4. 人员离职/调岗必须执行完整权限回收，删除SA与RoleBinding，立即失效kubeconfig
5. 定期巡检集群Role/RoleBinding，清理离职人员残留权限绑定
6. 交付kubeconfig前管理员必须完整校验权限边界，确认无超权访问
7. 禁止将集群cluster-admin管理员配置交付开发人员，所有操作使用细分RBAC角色

## 十二、关联文档索引

create-project-workspace.md 项目Namespace环境划分
validate-project-environment.md 项目环境权限交付验收标准
configure-project-resource-policy.md 资源配额、网络策略权限协同管控
06-network-debug.md 权限403故障排查流程
build-kubernetes-cluster.md 集群管理员kubeconfig配置说明