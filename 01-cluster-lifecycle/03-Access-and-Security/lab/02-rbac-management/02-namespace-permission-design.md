# 02‑namespace‑permission‑design.md（纯实操）
## 实验目标
1. 掌握命名空间级别 RBAC 对象 Role 与 RoleBinding；
2. 理解 Role 仅作用于所属 namespace，不能跨命名空间；
3. 给 dev‑user 在 dev 命名空间分配精细化权限；
4. 练习查看、修改、删除 Role/RoleBinding。

## 实验环境
- k8s‑master‑01：192.168.11.161
- 已有：dev‑user(CN=dev‑user)，namespace：dev

## 前置说明
1. Role：命名空间级别资源，限定在单个 namespace 内生效；
2. RoleBinding：把 User / Group / ServiceAccount 和 Role 进行绑定，同样限定在当前 namespace；
3. Role、RoleBinding 只对当前 namespace 生效，跨 ns 无效。

## 步骤1：编写Role清单，定义权限范围
role‑dev.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev
  name: dev-app-role
rules:
- apiGroups:
  - ""
  resources:
  - pods
  - services
  verbs: ["get", "list", "create", "delete"]
- apiGroups:
  - apps
  resources:
  - deployments
  verbs: ["get", "list"]
```
字段解释（只记实操重点）
- apiGroups：资源所属API组；空字符串代表核心资源组；apps对应deployments；
- resources：要管控的资源；
- verbs：动作：get/list/watch/create/update/delete/patch。

部署资源：
```bash
kubectl apply -f role-dev.yaml
# 查看Role资源
kubectl get role -n dev
kubectl describe role dev-app-role -n dev
```

## 步骤2：创建RoleBinding绑定用户和Role
rolebinding‑dev.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev
  name: dev-user-bind
subjects:
- kind: User
  name: dev-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dev-app-role
```
执行部署：
```bash
kubectl apply -f rolebinding-dev.yaml
kubectl get rolebinding -n dev
kubectl describe rolebinding dev-user-bind -n dev
```
重点查看：
- subjects：绑定的主体；
- roleRef：引用本命名空间内的Role，RoleBinding不能引用其他namespace的Role。

## 步骤3：权限验证（必做实操）
### 3.1 在dev命名空间执行允许的操作
```bash
# 创建pod
kubectl run test-pod --image=nginx -n dev --kubeconfig=./dev-user-kubeconfig
kubectl get pods -n dev --kubeconfig=./dev-user-kubeconfig

# 查看deployment（规则里只允许get list）
kubectl get deploy -n dev --kubeconfig=./dev-user-kubeconfig

# 尝试创建deployments，规则没有开放create，预期报错forbidden
kubectl create deployment test-dep --image=nginx -n dev --kubeconfig=./dev-user-kubeconfig
```

### 3.2 验证Role不能跨命名空间（核心考点）
```bash
kubectl get pods -n default --kubeconfig=./dev-user-kubeconfig
# 结果：forbidden。dev‑user在default没有绑定Role，权限不足
```

### 3.3 使用auth can‑i命令核查权限
```bash
# dev命名空间可以创建pod
kubectl auth can-i create pods -n dev --kubeconfig=./dev-user-kubeconfig
# default命名空间不允许
kubectl auth can-i create pods -n default --kubeconfig=./dev-user-kubeconfig
```

## 步骤4：修改Role权限，动态更新权限
### 方式1：直接edit在线修改
```bash
kubectl edit role dev-app-role -n dev
# 在verbs里添加 update
# verbs: ["get", "list", "create", "delete","update"]
```
### 方式2：修改yaml文件重新apply
```bash
vim role-dev.yaml
kubectl apply -f role-dev.yaml
```
再次验证：
```bash
kubectl patch pod test-pod -n dev -p '{"metadata":{"labels":{"env":"dev"}}}' --kubeconfig=./dev-user-kubeconfig
```

## 步骤5：绑定Group（用户组）代替单独绑定User（生产推荐）
rolebinding-group.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev
  name: dev-group-bind
subjects:
- kind: Group
  name: dev-group
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dev-app-role
```
```bash
kubectl apply -f rolebinding-group.yaml
```
> 生产规范：优先绑定Group，后续新增用户只要证书O字段加入该group，自动继承权限，不用新增RoleBinding。

## 步骤6：清理资源
```bash
kubectl delete -f role-dev.yaml
kubectl delete -f rolebinding-dev.yaml
kubectl delete -f rolebinding-group.yaml
```

## 排障实操要点（高频踩坑）
1. forbidden问题排查顺序：
   - 解码证书确认用户名或组名称；
   - 确认RoleBinding所在namespace；
   - 核对Role内apiGroups、resources、verbs是否匹配；
2. 错误案例：把RoleBinding创建在default命名空间，Role在dev，权限一定不生效；
3. RoleBinding只能引用同一个namespace下面的Role，无法跨namespace引用。

## 实验验收条件
1. 成功创建Role和RoleBinding；
2. dev‑user在dev命名空间权限符合规则；
3. 访问其他命名空间被拒绝；
4. 能够通过修改yaml动态调整权限；
5. 可以基于Group完成授权。

接下来编写 `03‑cluster-permission-design.md`。