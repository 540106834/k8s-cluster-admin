# 06‑rbac‑troubleshooting.md（纯实操）
## 实验目标
1. 建立固定的 forbidden 排障步骤；
2. 人为复现权限不足报错；
3. 逐层定位：证书身份 → RBAC绑定 → Role规则；
4. 修复问题；提炼生产排查命令。
## 环境信息
master‑01：192.168.11.161，用户 dev‑user。

## 前置准备
清空之前配置，只保留最简环境
```bash
kubectl delete rolebinding dev-user-edit-binding -n dev
```
此时 dev‑user 在 dev 命名空间没有任何权限，用来复现 forbidden。

## 标准排障步骤（固定顺序，生产严格遵守）
步骤顺序：
1. 提取客户端证书识别出来的用户名和用户组；
2. 使用 `kubectl auth can‑i --as` 确认apiserver判定结果；
3. 检索 RoleBinding / ClusterRoleBinding，确认是否绑定；
4. 核查 Role / ClusterRole 的 apiGroups、resources、verbs；
5. 确认资源所在namespace是否匹配。

---

## 步骤1：复现故障
```bash
kubectl get pods -n dev --kubeconfig=/opt/user-cert/dev-user-kubeconfig
# 报错：Error from server (Forbidden): pods is forbidden: User "dev‑user" cannot list resource "pods" in API group "" in the namespace "dev"
```

## 步骤2：第1步排查：解析证书确认 apiserver 识别到的用户是谁
```bash
cd /opt/user-cert
openssl x509 -in dev-user.crt -text -noout | grep Subject
# 输出：Subject: CN = dev-user, O = dev-group
# apiserver认证阶段拿到 User=dev‑user，Group=dev‑group
# 这里高频坑点：RoleBinding的name和CN字符必须完全一致，空格、大小写错误都会失效。
```

## 步骤3：第2步：在master管理员节点用`--as`模拟用户，排除kubeconfig文件问题
> 这一步用来区分问题：到底是集群授权没配置，还是kubeconfig文件异常。
```bash
kubectl auth can-i list pods -n dev --as=dev-user
# 返回 no，确定集群侧就没有分配权限，问题出在RBAC配置。

# 如果这里返回 yes，但用kubeconfig执行返回no：代表kubeconfig里证书不对。
```

## 步骤4：第3步：全局检索是否存在绑定关系
### 4.1 查找namespace内RoleBinding
```bash
USER="dev-user"
# 查询dev命名空间
kubectl get rolebinding -n dev -o json | jq -r --arg u "${USER}" '.items[]|select(.subjects[].name==$u)|.metadata.name'
# 当前为空，证明没有RoleBinding绑定dev‑user
```

### 4.2 查询集群级别 ClusterRoleBinding
```bash
kubectl get clusterrolebinding -o json | jq -r --arg u "${USER}" '.items[]|select(.subjects[].name==$u)|.metadata.name'
# 同样为空
```
结论：没有创建对应的RoleBinding，这就是forbidden根本原因。

## 步骤5：第4步：创建正确RBAC配置，修复故障
rbac-fix.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev
  name: dev-user-edit-binding
subjects:
- kind: User
  name: dev-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
```
```bash
kubectl apply -f rbac-fix.yaml
```
验证：
```bash
kubectl auth can-i list pods -n dev --as=dev-user
# 返回 yes
kubectl get pods -n dev --kubeconfig=/opt/user-cert/dev-user-kubeconfig
```

---

## 步骤6：模拟生产中4种高频错误场景（重点）
### 场景1：RoleBinding写在default命名空间，Role在dev（配置位置错误）
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: default   # 错误位置
  name: dev-user-edit-binding
subjects:
- kind: User
  name: dev-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
```
```bash
kubectl apply -f rbac-fix.yaml
kubectl get pods -n dev --kubeconfig=/opt/user-cert/dev-user-kubeconfig
# forbidden。RoleBinding在default，对dev命名空间无效。
```
排查：`kubectl describe rolebinding dev-user-edit-binding -n default`，查看命名空间。

### 场景2：Role里apiGroups或者verbs写错
错误示例：apiGroups写成app（正确是apps）
```yaml
rules:
- apiGroups: ["app"]
  resources: ["deployments"]
  verbs: ["get","list"]
```
```bash
kubectl auth can-i list deployments -n dev --as=dev-user
# 返回no
```
解决：核对官方apiGroup名称。

### 场景3：绑定Group时证书O字段和yaml里name不一致
证书O=dev-group‑1，但yaml写dev-group，权限失效。
```bash
openssl x509 -in dev-user.crt -text -noout | grep O
# 核对group名称和subjects.name严格一致。
```

### 场景4：把ClusterRoleBinding误以为可以限定namespace
ClusterRoleBinding一旦创建就是全局生效，不能限定ns；如果只想某个ns生效，只能用RoleBinding引用ClusterRole。

## 步骤7：生产一键排查脚本（直接复制执行）
```bash
# 整体核查命令，面试和工作高频使用
USER="dev-user"
echo "=====RoleBinding检索===="
for ns in $(kubectl get namespaces -o jsonpath="{.items[*].metadata.name}")
do
kubectl get rolebinding -n ${ns} -o json | jq -r --arg user "${USER}" \
'.items[] | select(.subjects!=null and .subjects[].name == $user)|"NS:"+.metadata.namespace+" RB:"+.metadata.name+" Role:"+.roleRef.name'
done

echo -e "\n=====ClusterRoleBinding检索===="
kubectl get clusterrolebinding -o json | jq -r --arg user "${USER}" \
'.items[]|select(.subjects!=null and .subjects[].name==$user)|"CRB:"+.metadata.name+" ClusterRole:"+.roleRef.name'
```

## 步骤8：整理最终精简版排查口诀（面试背诵）
1. 解析证书确认User/Group；
2. `kubectl auth can‑i --as` 判断集群侧权限；
3. 脚本检索RoleBinding、ClusterRoleBinding；
4. 确认RBAC所在namespace；
5. 核对Role中的 apiGroups、resources、verbs。

## 清理实验资源
```bash
kubectl delete rolebinding dev-user-edit-binding -n dev
```

## 实验验收标准
1. 复现forbidden报错；
2. 严格按照排障步骤定位问题；
3. 修复权限；
4. 熟练运行一键审计脚本。

到此02‑rbac‑management全部实操完成，接下来开启 `03‑serviceaccount‑management`。