# 05‑rbac‑audit.md（纯实操）
## 实验目标
1. 熟练使用 `kubectl auth can‑i` 做权限核验；
2. 针对 User、ServiceAccount、Group 进行权限检查；
3. 查看哪些RBAC对象绑定了指定用户，完成权限审计；
4. 学会排查：用户到底被哪些RoleBinding、ClusterRoleBinding授权。
## 实验环境
master‑01：192.168.11.161，用户 dev‑user，dev‑group。
前置：部署dev‑user‑edit‑binding，dev‑user在dev命名空间拥有edit权限。

## 步骤1：基础用法：auth can‑i 命令
### 1.1 基础语法
```bash
# 格式
kubectl auth can-i <verb> <resource> -n <ns> --kubeconfig=xxx

# 查看当前使用的用户自己能做什么
kubectl auth can-i create pods -n dev
```
yes代表允许，no代表禁止。

### 1.2 针对dev‑user单独校验
```bash
# dev命名空间创建pod（允许）
kubectl auth can-i create pods -n dev --kubeconfig=/opt/user-cert/dev-user-kubeconfig

# kube‑system命名空间创建pod（禁止）
kubectl auth can-i create pods -n kube-system --kubeconfig=/opt/user-cert/dev-user-kubeconfig

# 查看集群node资源（禁止）
kubectl auth can-i list nodes --kubeconfig=/opt/user-cert/dev-user-kubeconfig

# 查看deploy资源
kubectl auth can-i list deployments -n dev --kubeconfig=/opt/user-cert/dev-user-kubeconfig
```

## 步骤2：不加载kubeconfig，直接指定用户名审计（重点）
`--as` 参数，模拟指定用户身份进行权限判断，不需要该用户的kubeconfig。
```bash
# 以dev‑user身份校验权限，在master管理员环境执行
kubectl auth can-i create pods -n dev --as=dev-user
kubectl auth can-i delete pods -n kube-system --as=dev-user

# 模拟用户组 dev‑group
kubectl auth can-i create services -n dev --as-group=dev-group

# 模拟超级管理员system:masters组
kubectl auth can-i delete nodes --as-group=system:masters
```

## 步骤3：查看该用户拥有的全部权限（高级审计）
### 3.1 查看用户在某个命名空间下能执行哪些操作
```bash
# kubectl auth can‑i list 列出全部权限，只支持管理员执行
kubectl auth can-i list --as=dev-user -n dev
```

### 3.2 全局查看集群级别权限
```bash
kubectl auth can-i list --as=dev-user --namespace=""
```

## 步骤4：审计：查找绑定该用户的RoleBinding、ClusterRoleBinding（生产排障高频）
### 4.1 查找命名空间内绑定dev‑user的RoleBinding
```bash
# 遍历dev命名空间下所有rolebinding，筛选subject匹配dev‑user
kubectl get rolebinding -n dev -o yaml | grep -B5 -A5 dev-user
# 详细查看
kubectl describe rolebinding dev-user-edit-binding -n dev
```

### 4.2 全局查找ClusterRoleBinding绑定dev‑user
```bash
kubectl get clusterrolebinding -o yaml | grep -B8 -A8 dev-user
```

### 4.3 Shell一键脚本，全局审计某个用户的所有绑定关系（生产直接复制）
```bash
USER_NAME="dev-user"
echo "=====查找RoleBinding====="
for ns in $(kubectl get ns -o jsonpath="{.items[*].metadata.name}")
do
  kubectl get rolebinding -n ${ns} -o json | jq -r \
  --arg user "${USER_NAME}" '.items[] | select(.subjects!=null and .subjects[].name==$user) | "Namespace:" + .metadata.namespace + " Name:" + .metadata.name + " Role:" + .roleRef.name'
done

echo -e "\n=====查找ClusterRoleBinding====="
kubectl get clusterrolebinding -o json | jq -r \
--arg user "${USER_NAME}" '.items[] | select(.subjects!=null and .subjects[].name==$user) | "ClusterRoleBinding:" + .metadata.name + " ClusterRole:" + .roleRef.name'
```
> 安装jq：`apt install jq -y`

执行结果可以清晰看到：
1. 哪些命名空间下给该用户分配了权限；
2. 引用的Role或ClusterRole是谁。

## 步骤5：审计ServiceAccount权限（提前预习后面章节）
```bash
# 模拟sa账号app‑sa的权限
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:app-sa
```
格式：`system:serviceaccount:<namespace>:<sa-name>`

## 步骤6：查看RBAC规则详情，反查ClusterRole里面允许动作
```bash
# 查看edit角色内部规则
kubectl describe clusterrole edit
```

## 步骤7：生产环境审计场景（面试要点）
1. 离职人员排查：检查是否还存在绑定该用户的RoleBinding、ClusterRoleBinding；
2. 权限过大排查：发现开发用户绑定cluster‑admin；
3. 权限缺失：先用 `auth can‑i` 确认是否有权限，再查找绑定对象。

## 步骤8：清理环境
```bash
# 无资源需要删除，只是查询操作
```

## 排障固定排查顺序（实操总结）
1. `kubectl auth can‑i` 判断到底有没有权限；
2. `--as` 模拟用户确认集群侧判定结果，排除kubeconfig证书问题；
3. 脚本检索RoleBinding和ClusterRoleBinding；
4. 查看Role或ClusterRole里的rules确认资源和动词配置。

## 实验验收标准
1. 会使用 `auth can‑i` 判断权限；
2. 会使用 `--as`、`--as-group` 模拟身份校验；
3. 可以通过脚本找出该用户所有授权绑定；
4. 理解ServiceAccount的身份格式。

接下来：06‑rbac‑troubleshooting.md。