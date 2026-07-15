# 04‑serviceaccount‑security.md（纯实操版）
## 实验目标
1. 理解 `automountServiceAccountToken` 作用；
2. 关闭Pod自动挂载SA‑Token，缩减攻击面；
3. 区分全局default‑sa和业务自定义SA的安全配置；
4. 生产最佳实践：不需要访问k8s‑API的Pod禁止挂载token。
## 实验环境
k8s‑v1.32.13，master‑01：192.168.11.161，namespace:dev

## 前置说明
1. 两个层级可以控制是否挂载token：
   - 1）ServiceAccount层面：`automountServiceAccountToken`
   - 2）Pod spec层面：`automountServiceAccountToken`（优先级高于SA配置）
2. 默认值：`automountServiceAccountToken: true`，Pod自动挂载短期token；
3. 安全风险：一旦容器被入侵，黑客拿到token调用apiserver，如果SA权限很高，集群就会被横向渗透。

## 步骤1：实操1：在Pod级别关闭token挂载（推荐优先配置）
### 1.1 部署关闭token的pod
no-token-pod.yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-token-pod
  namespace: dev
spec:
  serviceAccountName: app-sa
  automountServiceAccountToken: false   # pod级别关闭挂载
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["sleep","36000"]
```
```bash
kubectl create sa app-sa -n dev
kubectl apply -f no-token-pod.yaml
kubectl exec -it no-token-pod -n dev -- sh
```
### 1.2 进入容器验证挂载目录消失
```bash
ls /var/run/secrets/kubernetes.io/serviceaccount
# 目录不存在，没有token、ca.crt文件
# 此时容器内无法访问apiserver
```

## 步骤2：实操2：在ServiceAccount层面全局关闭自动挂载
修改SA配置，后续所有引用该SA的Pod默认都不挂载token。
```bash
kubectl edit sa app-sa -n dev
# 添加字段：
automountServiceAccountToken: false
```
新建pod，不单独设置spec的automountServiceAccountToken：
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-sa-pod
  namespace: dev
spec:
  serviceAccountName: app-sa
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["sleep","36000"]
```
```bash
kubectl apply -f test-sa-pod.yaml
kubectl exec -it test-sa-pod -n dev -- sh
ls /var/run/secrets/kubernetes.io/serviceaccount
# 同样没有token文件
```
优先级总结：
`Pod.spec.automountServiceAccountToken > SA.automountServiceAccountToken`。

## 步骤3：场景实操：只有个别Pod需要开启token（生产用法）
SA全局关闭挂载，特定Pod单独开启token：
1. 修改SA保持关闭：`automountServiceAccountToken: false`
2. 在需要调用apiserver的pod里手动开启：
```yaml
spec:
  serviceAccountName: app-sa
  automountServiceAccountToken: true
```
> 好处：大部分业务Pod拿不到token，只有特定程序拿到凭证，缩小攻击面。

## 步骤4：加固默认namespace下的default ServiceAccount（生产必做）
所有命名空间默认自带default SA，很多业务不指定SA就默认使用它。
### 4‑1 给全局default‑sa关闭自动挂载
```bash
kubectl edit sa default -n dev
# 添加
automountServiceAccountToken: false
```
### 4‑2 集群批量把所有namespace的default‑sa关闭挂载（shell脚本）
```bash
# 批量给全部ns的default‑sa关闭automountServiceAccountToken
for ns in $(kubectl get ns -o jsonpath="{.items[*].metadata.name}")
do
kubectl patch sa default -n ${ns} -p '{"automountServiceAccountToken":false}'
done
```
> 注意：kube‑system命名空间里面组件必须使用token，kube‑system的default‑sa不要修改。

## 步骤5：配合RBAC再收紧安全（面试高频要点）
1. 业务程序需要调用apiserver：
   - 独立创建专属SA；
   - 分配最小权限；
   - 其余Pod关闭token挂载；
2. 业务程序完全不需要访问k8s‑API：
   - 强制 `automountServiceAccountToken: false`；
   - 绝不使用default‑sa；
3. 禁止给default‑sa绑定任何ClusterRoleBinding、RoleBinding。

## 步骤6：PSP废弃后新版本安全替代方案（v1.32环境）
现在弃用PSP，依靠PSA（Pod‑Security‑Admission）：
- restricted安全模式下：强制不允许自动挂载token或者限制SA权限。
后面07‑pod‑security‑standard.md实验会实操。

## 清理实验资源
```bash
kubectl delete pod no-token-pod test-sa-pod -n dev
kubectl delete sa app-sa -n dev
# 恢复dev命名空间default‑sa默认值
kubectl patch sa default -n dev -p '{"automountServiceAccountToken":null}'
```

## 实验验收标准
1. 能够在Pod级别和SA级别关闭token挂载；
2. 理解pod字段优先级高于SA字段；
3. 批量修改default‑sa关闭token；
4. 掌握生产环境对SA的安全加固原则。

### 本章节03‑serviceaccount‑management全部实验结束
接下来开启04‑secret‑management模块：01‑secret‑basic.md。