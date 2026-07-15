# 04‑dev‑user‑permission.md（纯实操）
## 实验目标
1. 模拟真实生产场景：研发账号 dev‑user，仅允许操作 dev 命名空间；
2. 复用集群内置 ClusterRole(edit)，借助 RoleBinding 做命名空间隔离；
3. 验证：dev‑ns内可正常管理业务资源，kube‑system、default、集群级资源全部禁止访问；
4. 落实生产最小权限原则。

## 环境信息
- master‑01：192.168.11.161
- 已有用户：dev‑user（CN=dev‑user，Group：dev‑group）
- 命名空间：dev
- 内置集群角色：edit、view

## 步骤1：清理之前旧RBAC配置，避免权限混乱
```bash
# 删除历史ClusterRoleBinding、RoleBinding
kubectl delete clusterrolebinding dev-user-global-view group-node-pv-bind
kubectl delete rolebinding dev-user-bind dev-group-bind dev-use-cluster-edit -n dev
kubectl delete role dev-app-role -n dev
```

## 步骤2：采用生产推荐方案：RoleBinding引用内置ClusterRole
生产不建议自己编写Role规则，优先复用K8s内置角色减少出错概率。
dev-user-rbac.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev
  name: dev-user-edit-binding
subjects:
- kind: User
  name: dev-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
```
执行配置：
```bash
kubectl apply -f dev-user-rbac.yaml
kubectl get rolebinding -n dev
kubectl describe rolebinding dev-user-edit-binding -n dev
```
权限说明：
- ClusterRole为edit本身拥有完整命名空间内资源操作权限；
- 通过RoleBinding绑定之后，权限仅限定在dev命名空间内生效，不会扩散到其他ns。

## 步骤3：分场景验证权限（核心实操）
### 场景3‑1：dev命名空间内执行增删改查（允许）
```bash
# 创建deploy
kubectl create deploy web --image=nginx -n dev --kubeconfig=./dev-user-kubeconfig
kubectl get deploy,pods,svc -n dev --kubeconfig=./dev-user-kubeconfig
# 扩容副本
kubectl scale deploy web --replicas=2 -n dev --kubeconfig=./dev-user-kubeconfig
# 删除pod
kubectl delete pod -n dev -l app=web --kubeconfig=./dev-user-kubeconfig
```

### 场景3‑2：访问default命名空间（预期Forbidden）
```bash
kubectl get pods -n default --kubeconfig=./dev-user-kubeconfig
kubectl auth can-i list pods -n default --kubeconfig=./dev-user-kubeconfig
```

### 场景3‑3：访问kube‑system命名空间（拒绝）
```bash
kubectl get pods -n kube-system --kubeconfig=./dev-user-kubeconfig
kubectl auth can-i list pods -n kube-system --kubeconfig=./dev-user-kubeconfig
```

### 场景3‑4：尝试查看集群级资源nodes、pv（集群级资源edit角色本身不包含，拒绝）
```bash
kubectl get nodes --kubeconfig=./dev-user-kubeconfig
kubectl get pv --kubeconfig=./dev-user-kubeconfig
kubectl auth can-i list nodes --kubeconfig=./dev-user-kubeconfig
```

## 步骤4：扩展方案：基于用户组授权（生产最佳实践）
后续新增开发人员，只要openssl证书中O字段填写dev‑group，自动继承权限，不用新建RoleBinding。
dev-group-rbac.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev
  name: dev-group-edit-binding
subjects:
- kind: Group
  name: dev-group
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
```
```bash
kubectl apply -f dev-group-rbac.yaml
```

## 步骤5：精细化收紧权限（可选，生产严格环境）
如果不希望开发删除资源，放弃edit角色，自定义Role只给get、list、create。
custom-dev-role.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev
  name: dev-strict-role
rules:
- apiGroups: ["","apps"]
  resources: ["pods","deployments","services","configmaps"]
  verbs: ["get","list","create","watch"]
```
```bash
kubectl apply -f custom-dev-role.yaml
# 修改RoleBinding引用自定义Role
kubectl edit rolebinding dev-user-edit-binding -n dev
```

## 步骤6：把kubeconfig交付给开发人员
```bash
cp /opt/user-cert/dev-user-kubeconfig /home/dev/.kube/config
chown dev:dev /home/dev/.kube/config
chmod 600 /home/dev/.kube/config
# 切换dev用户验证
su dev
kubectl get pods -n dev
```

## 步骤7：清理实验资源
```bash
kubectl delete -f dev-user-rbac.yaml
kubectl delete -f dev-group-rbac.yaml
kubectl delete -f custom-dev-role.yaml
kubectl delete deploy web -n dev
```

## 生产规范总结（面试重点）
1. 开发账号绝对不要分配cluster‑admin；
2. 开发人员只分配指定Namespace内edit或者view；
3. 优先基于Group授权，便于人员批量管理；
4. 尽量复用内置ClusterRole，减少手动编写Role出错；
5. kubeconfig文件权限必须600，防止泄露。

## 实验验收条件
1. dev‑user在dev命名空间可以正常管理业务资源；
2. default、kube‑system、nodes、pv全部访问被拒绝；
3. 完成基于用户组授权；
4. 能够区分内置edit和自定义Role的使用场景。

下一步：05‑rbac‑audit.md。