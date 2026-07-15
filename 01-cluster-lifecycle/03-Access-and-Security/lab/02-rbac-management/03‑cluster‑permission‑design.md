# 03‑cluster‑permission‑design.md（纯实操版本）
## 实验目标
1. 掌握集群级别资源：`ClusterRole`、`ClusterRoleBinding`；
2. 对比区分 Role‑RoleBinding（ns级别）与 ClusterRole‑ClusterRoleBinding（集群级别）；
3. 使用内置集群角色，自定义集群角色；
4. 实现两种场景：全局权限、指定namespace权限。

## 环境前提
- master节点：192.168.11.161
- 用户：dev‑user、dev‑group
- 内置集群角色重点：`cluster‑admin`、`view`、`edit`、`system:node`

## 核心概念（精简）
1. ClusterRole：集群级资源，不属于任何namespace；
   - 可以管控集群范围资源(nodes、pv、namespaces、clusterroles)；
   - 也可以给所有命名空间内的资源配置权限。
2. ClusterRoleBinding：集群级绑定资源，全局生效，把User/Group/SA绑定ClusterRole。
3. 对比：
   - Role/RoleBinding：仅当前namespace；
   - ClusterRoleBinding：权限作用整个集群；
   - ClusterRole也可以被RoleBinding引用，仅限定在某一个namespace生效。

## 步骤1：查看K8s内置ClusterRole（重点）
```bash
# 查看集群角色
kubectl get clusterrole
# 查看cluster-admin详情
kubectl describe clusterrole cluster-admin
# 查看view角色
kubectl describe clusterrole view
```
内置角色说明：
1. `cluster‑admin`：超级管理员，拥有集群全部权限；`system:masters`组通过ClusterRoleBinding绑定该角色；
2. `edit`：命名空间内资源增删改查，不能查看集群级资源；
3. `view`：只有查看权限，不能修改资源。

查看集群绑定：
```bash
kubectl describe clusterrolebinding kubernetes-admin
# subjects：kubernetes‑admin；roleRef：cluster‑admin
```

## 步骤2：场景1：ClusterRoleBinding全局绑定（整个集群生效）
### 2‑1 编写yaml，让dev‑user拥有集群view权限，所有命名空间都可以查看资源
cluster-global-bind.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dev-user-global-view
subjects:
- kind: User
  name: dev-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
```
```bash
kubectl apply -f cluster-global-bind.yaml
kubectl get clusterrolebinding
```

### 2‑2 权限验证
```bash
# 查看kube‑system命名空间pod，现在可以查看（之前forbidden）
kubectl get pods -n kube-system --kubeconfig=./dev-user-kubeconfig

# 尝试删除pod，view角色没有删除权限，预期forbidden
kubectl delete pod -n kube-system $(kubectl get pods -n kube-system|head -1|awk '{print $1}') --kubeconfig=./dev-user-kubeconfig

# 权限核验
kubectl auth can-i list pods -n kube-system --kubeconfig=./dev-user-kubeconfig
kubectl auth can-i delete pods -n kube-system --kubeconfig=./dev-user-kubeconfig
```

## 步骤3：场景2：自定义ClusterRole
创建集群角色：允许查看node和pv资源
custom-clusterrole.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-pv-view
rules:
- apiGroups: [""]
  resources: ["nodes","persistentvolumes"]
  verbs: ["get","list","watch"]
```
```bash
kubectl apply -f custom-clusterrole.yaml
kubectl describe clusterrole node-pv-view
```
绑定给dev‑group用户组：
clusterrolebind-group.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: group-node-pv-bind
subjects:
- kind: Group
  name: dev-group
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-pv-view
```
```bash
kubectl apply -f clusterrolebind-group.yaml
```
验证：
```bash
kubectl get nodes --kubeconfig=./dev-user-kubeconfig
kubectl get pv --kubeconfig=./dev-user-kubeconfig
kubectl get namespaces --kubeconfig=./dev-user-kubeconfig
```

## 步骤4：场景3：ClusterRole被RoleBinding引用（面试高频）
ClusterRole本身是集群角色，通过RoleBinding绑定后，权限只限制在指定namespace。
示例：把内置edit集群角色仅给到dev命名空间。
rolebind-use-clusterrole.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev
  name: dev-use-cluster-edit
subjects:
- kind: User
  name: dev-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
```
```bash
kubectl apply -f rolebind-use-clusterrole.yaml
```
测试：
```bash
# dev命名空间可以创建pod
kubectl run test-nginx --image=nginx -n dev --kubeconfig=./dev-user-kubeconfig
# default命名空间仍然没有权限
kubectl run test-nginx --image=nginx -n default --kubeconfig=./dev-user-kubeconfig
```
> 总结：
> - ClusterRoleBinding：全局生效；
> - RoleBinding引用ClusterRole：仅当前namespace生效。

## 步骤5：清理实验资源
```bash
kubectl delete -f cluster-global-bind.yaml
kubectl delete -f custom-clusterrole.yaml
kubectl delete -f clusterrolebind-group.yaml
kubectl delete -f rolebind-use-clusterrole.yaml
```

## 排障要点（实操踩坑）
1. ClusterRole资源执行`kubectl get clusterrole -n dev`会报错，ClusterRole不存在namespace；
2. ClusterRoleBinding不能限定namespace，一旦绑定就是全局；
3. 若只想把ClusterRole权限限定某个ns，只能借助RoleBinding引用ClusterRole；
4. 生产注意：`cluster‑admin`只允许极少数运维人员使用，严禁给开发人员分配。

## 实验验收标准
1. 可以查看内置ClusterRole；
2. 通过ClusterRoleBinding实现全局权限；
3. 可以自定义ClusterRole；
4. 掌握RoleBinding引用ClusterRole实现命名空间级别授权；
5. 分清四者生效范围：Role、RoleBinding、ClusterRole、ClusterRoleBinding。

下一步编写：04‑dev‑user‑permission.md。