# 01‑rbac‑basic.md（纯实操版，只保留操作命令，精简叙述）
## 实验目标
1. 实操梳理 Kubernetes 认证(Authentication) → 鉴权(Authorization)执行流程。
2. 区分3种主体：普通User、Group、ServiceAccount。
3. 查看集群内置用户、内置用户组，理解系统预置权限绑定关系。
## 实验环境
- k8s v1.32.13，master‑01：192.168.11.161
- 前置：前面创建 dev‑user（CN=dev‑user,O=dev‑group）

## 1 梳理认证鉴权整体流程（结合实操验证）
整体执行顺序：
1. 客户端携带证书 / token 请求 apiserver；
2. **Authentication（认证）：apiserver校验凭证是否合法，提取用户名、用户组；**
3. **Authorization（RBAC鉴权）：判断该主体是否允许执行对应操作；**
4. 准入控制(Admission‑Controller)最后校验。

### 实操1‑1：查看证书解析出User和Group（对应认证阶段）
```bash
cd /opt/user-cert
openssl x509 -in dev-user.crt -text -noout | grep -E 'Subject:'
# 输出：CN = dev‑user, O = dev‑group
# CN对应User名称，O对应Group名称

# 查看管理员证书信息
openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -text -noout | grep Subject
# CN = kubernetes‑admin, O = system:masters
# system:masters 是集群内置超级用户组
```
> 核心：证书里的CN就是User，O列表就是Group，认证成功后把这两个信息交给RBAC鉴权模块。

### 实操1‑2：验证鉴权结果，用`kubectl auth can‑i`查看RBAC判定结果
```bash
# dev‑user 在dev命名空间创建pod
kubectl auth can-i create pods -n dev --kubeconfig=./dev-user-kubeconfig
# 返回 yes

# dev‑user 在kube‑system查看pod
kubectl auth can-i list pods -n kube-system --kubeconfig=./dev-user-kubeconfig
# 返回 no
```

## 2 区分三类主体实操
### 2.1 User（人工用户，openssl签发证书创建，对应运维、开发人员）
1. 创建方式：openssl签发客户端证书指定CN；
2. 集群不会在etcd存储User列表，K8s本身不保存用户，完全依靠证书CN识别用户；
3. 查看集群内置绑定示例：
```bash
kubectl describe clusterrolebinding kubernetes-admin
# subjects里：name: kubernetes‑admin
# 绑定 cluster‑admin集群角色
```

### 2.2 Group（用户组，批量授权优先使用组，不单独给用户授权）
#### 实操2‑2‑1：查看system:masters内置组权限
```bash
kubectl get clusterrolebinding kubernetes-admin -o yaml
# 只要证书中O=system:masters，自动拥有cluster‑admin权限
```
#### 实操2‑2‑2：演示基于用户组授权（新建group‑rbac.yaml）
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: group-dev-role
  namespace: dev
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get","list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: group-dev-bind
  namespace: dev
subjects:
- kind: Group
  name: dev-group
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: group-dev-role
```
```bash
kubectl apply -f group-rbac.yaml
# dev‑user属于dev‑group组，现在可以查看deployments
kubectl get deploy -n dev --kubeconfig=./dev-user-kubeconfig
```
> 生产最佳实践：优先给Group授权，后续新增人员只要加入对应组即可，不用新建RoleBinding。

### 2.3 ServiceAccount（SA，Pod内部进程使用的账号，后续03‑serviceaccount‑management重点实操）
User给人使用；ServiceAccount给Pod内程序调用k8s‑apiserver使用。
#### 实操2‑3‑1：创建ServiceAccount
```bash
kubectl create sa app-sa -n dev
# 查看sa资源
kubectl get sa -n dev
kubectl describe sa app-sa -n dev
```
#### 实操2‑3‑2：给ServiceAccount绑定权限
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sa-rolebind
  namespace: dev
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dev-role
```
```bash
kubectl apply -f sa-rolebind.yaml
```

## 3 查看集群内置的系统用户和系统组（面试高频）
```bash
# 查看所有ClusterRoleBinding，筛选系统内置账号
kubectl get clusterrolebinding | grep system:
```
内置关键账号：
1. `system:kubelet`：kubelet进程使用；
2. `system:nodes`：所有node节点；
3. `system:masters`：超级管理员组；
4. `system:authenticated`：所有认证通过的用户。

## 4 总结区分（实操结论）
1. User：人访问集群，依靠openssl证书CN；
2. Group：用户组，批量授权，证书O字段定义；
3. ServiceAccount：Pod内部程序访问apiserver使用，由K8s管理token。

## 排障要点
1. 认证失败：检查证书是否过期，CA是否集群根证书；
2. 鉴权失败：auth can‑i判断，确认是匹配User还是Group；
3. 不要混淆：ServiceAccount和普通User完全独立，不能混用。

## 实验验收标准
1. 能够从证书提取User和Group；
2. 完成基于Group授权；
3. 创建ServiceAccount；
4. 理解：认证提取身份，RBAC完成鉴权。

接下来写 `02-namespace-permission-design.md`？