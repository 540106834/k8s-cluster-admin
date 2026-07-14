# cluster‑deploy‑docs/authorization.md

## 一、文档基础信息

- 文件路径：`cluster‑deploy‑docs/authorization.md`
- 前置文档：`authentication.md`、`kubeconfig.md`
- 集群版本：Kubernetes‑1.32.13，apiserver授权模式启用RBAC（`--authorization‑mode=RBAC`），关闭ABAC、Web‑Hook授权（仅准入阶段使用Admission‑Webhook）。
- 执行顺序：Authentication（认证：确认是谁） → Authorization（授权：确认可以做什么） → Admission‑Control（准入控制）。
- 文档内容：RBAC核心4种资源对象,内置Role/ClusterRole、RoleBinding/ClusterRoleBinding、权限判定逻辑、命名空间隔离、生产权限划分模型、权限排查命令、DEV/FAT/UAT/PROD权限约束。

## 二、RBAC核心原理

1. RBAC全称：Role‑Based Access Control，基于角色访问控制；K8s只允许通过RBAC做权限管控。
2. 主体（Subject）分为三类：
    1. 普通用户：X509证书中的CN字段，例如 `dev‑user`；
    2. ServiceAccount：`system:serviceaccount:命名空间:sa名称`；程序访问集群使用；
    3. 用户组（Groups）：`system:masters`、`system:nodes`、`system:serviceaccounts`。
3. 权限对象分为两级：
    - Role：仅限**单个命名空间内部生效**；
    - ClusterRole：集群全局资源（Node、PersistentVolume、Namespace、ClusterRole）或者跨命名空间授权。
4. 绑定对象：Binding把主体和角色关联起来。
    - RoleBinding：命名空间级别绑定；
    - ClusterRoleBinding：集群全局绑定。

组合公式：

> - 命名空间权限：`Role + RoleBinding`
> - 全局权限：`ClusterRole + ClusterRoleBinding`
> - 常用组合：ClusterRole可以被RoleBinding引用，实现全局角色仅在某个namespace生效（最常用）。

## 三、RBAC四个核心资源详解

### 1. Role（命名空间内角色）

限定在指定namespace内，只能定义该命名空间下资源权限。
yaml示例：
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: prod
  name: pod-view-role
rules:
- apiGroups: [""]
  resources: ["pods","pods/log"]
  verbs: ["get","list","watch"] # 允许的动作：get list watch create delete update patch
```
verbs可选值：`get、list、watch、create、delete、update、patch、deletecollection`。

### 2. RoleBinding（命名空间绑定）

把User、ServiceAccount、Group和Role或者ClusterRole绑定到当前namespace。
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: prod
  name: dev-binding
subjects:
- kind: User
  name: dev-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```
重点：roleRef引用ClusterRole时，权限仅在本namespace生效。

### 3. ClusterRole（集群级角色）

不在任何namespace，作用范围集群全局：

1. 集群资源：Node、PV、Namespace、ClusterRole；
2. 也可以定义普通资源权限，供多个namespace复用。

K8s内置一批默认ClusterRole（系统预设，生产高频使用）：

1. `cluster‑admin`：超级管理员，对应`system:masters`用户组，可以执行全部操作；
2. `admin`：命名空间管理员，可以增删改当前namespace所有资源；不能删除namespace；
3. `edit`：编辑权限，可以创建修改Pod、Deployment、Service；不能查看资源配额和集群配置；
4. `view`：只读权限，只能查看资源，不能修改删除（开发人员标准权限）；
5. `system:node`：kubelet内置角色；
6. `system:scheduler`、`system:controller‑manager`：控制平面组件内置权限。

### 4. ClusterRoleBinding（集群全局绑定）

将主体和ClusterRole做全局绑定，所有命名空间都生效。
示例：把运维用户绑定全局管理员（生产禁止随意使用）

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-binding
subjects:
- kind: User
  name: ops-user
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

## 四、四种组合使用场景（生产落地选择）

1. **场景1：仅单个命名空间授权（推荐）**
    ClusterRole(edit/view/admin) + RoleBinding，只给指定namespace分配权限。
    > 开发人员标准方案：引用内置`view` ClusterRole，通过RoleBinding绑定至FAT命名空间。
2. **场景2：自定义权限在多个namespace复用**
    编写自定义ClusterRole，在每个namespace创建RoleBinding引用它。
3. **场景3：集群级别权限（查看Node、PV）**
    ClusterRole + ClusterRoleBinding，谨慎使用。
4. **场景4：ServiceAccount授权给Pod内部程序**

    创建SA → RoleBinding绑定SA和ClusterRole → Pod挂载SA‑Token访问apiserver。

```yaml
subjects:
- kind: ServiceAccount
  name: prometheus-sa
  namespace: kube-monitoring
```

## 五、权限判定优先级逻辑（理解排障关键）

1. 如果用户属于`system:masters`用户组，直接拥有cluster‑admin权限，绕过RBAC校验；
2. 分别检查：
    - RoleBinding授予的命名空间内权限；
    - ClusterRoleBinding授予的集群全局权限；
3. 权限取并集：任意一条规则允许即可执行操作；全部拒绝才返回403；
4. 匿名用户`system:anonymous`默认没有任何权限，生产严禁给匿名用户授权。

## 六、RBAC日常运维命令（生产高频）

### 6.1 查看资源

```bash
# 查看集群角色
kubectl get clusterrole
# 查看命名空间角色
kubectl get role -n prod
# 查看绑定关系
kubectl get rolebinding -n prod
kubectl get clusterrolebinding
```

### 6.2 权限核查命令（最重要，排查403必备）

```bash
# 查看某个用户拥有的全部权限
kubectl auth can-i --list --as=dev-user -n fat

# 单独校验是否可以删除pod
kubectl auth can-i delete pods -n fat --as=dev-user

# 查看ServiceAccount权限
kubectl auth can-i get deployments -n prod --as=system:serviceaccount:prod:argo-sa
```

### 6.3 清理废弃权限

```bash
kubectl delete rolebinding dev-binding -n fat
kubectl delete clusterrolebinding xxx
```

### 6.4 导出现有RBAC配置，GitOps托管

```bash
kubectl get role,rolebinding -n prod -o yaml > prod-rbac.yaml
kubectl get clusterrole,clusterrolebinding -o yaml > global-rbac.yaml
```

## 七、自定义ClusterRole设计（生产分层权限模型）

### 7.1 划分4类角色，禁止直接乱用cluster‑admin

1. **ops‑admin（运维管理员）**
    - 权限：所有命名空间资源读写，Node/PV查看权限；
    - 通过ClusterRoleBinding绑定运维账号；禁止普通开发人员获取。
2. **ns‑admin（项目负责人）**
    - 仅在自己项目namespace拥有admin权限；使用RoleBinding绑定内置ClusterRole:admin；
3. **app‑developer（普通开发人员）**
    - 仅view只读权限；查看Pod日志、Deployment、Service，禁止删除修改资源；
4. **sa‑limited（程序账号）**
    - 为ArgoCD、Prometheus单独定制最小权限ClusterRole，只开放必需资源；遵循最小权限原则。

### 7.2 禁止行为

1. 开发人员不要分配ClusterRoleBinding全局权限；
2. 不要将用户加入`system:masters`组；一旦加入后期无法收回权限；
3. 禁止给ServiceAccount授予cluster‑admin。

## 八、DEV/FAT/UAT/PROD差异化权限标准

1. DEV环境：
    - 开发人员可以使用cluster‑admin；权限管控宽松；
2. FAT测试环境：
    - 项目负责人拥有对应namespace admin权限；普通开发者仅view权限；
    - 外部组件SA定制最小权限；禁止全局cluster‑admin；
3. UAT预生产环境：
    - 严格区分运维账号和开发账号；开发人员只有view只读权限；
    - 所有RoleBinding、ClusterRole配置交由GitOps管理，禁止kubectl命令临时创建；
4. PROD生产环境（强制约束）
    1. 生产环境只有运维人员可以拿到集群级权限；开发人员只能查看对应namespace资源；
    2. 任何人禁止加入`system:masters`超级管理员组；运维人员分开独立证书；
    3. 所有ServiceAccount只授予完成工作必要权限，拒绝宽泛权限；
    4. RoleBinding/ClusterRoleBinding全部存放在Git仓库，ArgoCD自动同步；不通过kubectl手动创建；
    5. 每月定期审计：清理离职人员用户、废弃ServiceAccount和无用绑定；
    6. apiserver开启审计日志，记录每一条增删改操作。

## 九、故障排查（403‑Forbidden）

1. 先确认访问主体：是User还是ServiceAccount；
2. 使用`kubectl auth can‑i --as=xxx`验证权限；
3. 查看roleRef引用的ClusterRole资源；核对resources和verbs；
4. 区分：
    - 401 Unauthorized：authentication认证失败（证书过期、token失效）；
    - 403 Forbidden：认证成功，但RBAC授权不足。

## 十、最佳实践总结

1. 优先复用K8s内置ClusterRole（view/edit/admin），减少自定义Role编写；
2. 尽量使用`ClusterRole + RoleBinding`模式实现命名空间隔离，少用ClusterRoleBinding；
3. 权限遵循最小必要原则：程序账号、开发账号权限收窄；
4. 权限配置代码化：RBAC YAML全部纳入GitOps版本管理；
5. 定期审计无用ServiceAccount和用户绑定，缩小攻击面；
6. 超级管理员`cluster‑admin`严格管控，生产运维人员一人一套独立证书。

## 十一、关联文档

1. `authentication.md`：认证阶段，确定用户主体；
2. `kubeconfig.md`：X509证书生成与分发；
3. `05‑security‑management`：准入控制器、Pod安全标准PSS；
4. `10‑troubleshooting.md`：401、403报错排障；
5. GitOps文档：ArgoCD同步RBAC配置。
