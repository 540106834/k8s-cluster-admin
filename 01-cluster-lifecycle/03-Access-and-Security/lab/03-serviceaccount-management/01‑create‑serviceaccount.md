# 01‑create‑serviceaccount.md（纯实操）
## 实验目标
1. 创建ServiceAccount(SA)，区分SA和前面的User用户；
2. 查看SA自动生成secret；
3. 理解身份格式 `system:serviceaccount:<命名空间>:<sa名称>`；
4. 为后续给SA绑定RBAC权限做铺垫。
## 环境
master‑01：192.168.11.161，namespace：dev。
> 概念区分：
> User：给运维人员、开发人员使用，依靠openssl证书；
> ServiceAccount：给Pod内部进程调用apiserver使用，由k8s自动维护Token。

## 步骤1：创建ServiceAccount
```bash
# 在dev命名空间创建app‑sa
kubectl create sa app-sa -n dev

# 查看sa资源
kubectl get sa -n dev
# 输出字段：NAME, SECRETS
# k8s 1.24之后默认不会自动生成Secret对象，改用BoundServiceAccountTokenVolume机制
```

```bash
# 查看详细信息
kubectl describe sa app-sa -n dev
```
重点观察：
- Automount service account token：默认true，pod挂载sa‑token；
- 对应的身份名称：`system:serviceaccount:dev:app-sa`。

## 步骤2：手动查看ServiceAccount对应的内置用户组
所有SA默认归属组：`system:serviceaccounts` 和 `system:serviceaccounts:<namespace>`。
```bash
# 查看身份格式，后面RBAC绑定subject必须写这个全称
SA_USER="system:serviceaccount:dev:app-sa"
echo ${SA_USER}
```

## 步骤3：手动创建Secret兼容旧版本（可选实操）
k8s‑1.24及以后不再自动创建secret资源；如果需要提取静态token，手动创建secret：
sa‑secret.yaml
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-sa-secret
  namespace: dev
  annotations:
    kubernetes.io/service-account.name: app-sa
type: kubernetes.io/service-account-token
```
```bash
kubectl apply -f sa-secret.yaml
# 获取token内容
kubectl get secret app-sa-secret -n dev -o jsonpath={.data.token} | base64 -d
```

## 步骤4：临时给SA绑定权限（简单测试，下一节细讲）
sa‑rolebind.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-sa-bind
  namespace: dev
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
```
```bash
kubectl apply -f sa-rolebind.yaml
```

## 步骤5：校验SA权限，使用 --as 模拟SA账号访问集群（重点命令）
```bash
# 模拟app‑sa查看pod
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:app-sa

# 尝试删除pod，view角色不允许删除，返回no
kubectl auth can-i delete pods -n dev --as=system:serviceaccount:dev:app-sa
```

## 步骤6：查看集群默认default‑sa（必看）
每个namespace默认自带一个名字为default的ServiceAccount。
```bash
kubectl get sa default -n dev
kubectl describe sa default -n dev
```
> 默认情况：创建Pod不指定serviceAccountName时，自动挂载当前ns下default这个SA。

## 步骤7：清理本次实验资源
```bash
kubectl delete sa app-sa -n dev
kubectl delete secret app-sa-secret -n dev
kubectl delete rolebinding app-sa-bind -n dev
```

## 生产要点&面试总结
1. User和ServiceAccount完全分开：
   - User：人访问集群，CN定义用户名；
   - ServiceAccount：Pod里程序访问apiserver，身份固定格式 `system:serviceaccount:ns:sa‑name`。
2. 1.24+版本取消自动secret，pod通过临时挂载方式获取短期token；
3. 禁止业务pod使用default的ServiceAccount，生产环境每个应用单独创建SA。

## 实验验收标准
1. 成功创建ServiceAccount；
2. 记住SA对应的完整用户名；
3. 使用`--as`参数校验SA权限；
4. 了解default‑sa的作用。

下一步执行：02‑serviceaccount‑token.md。