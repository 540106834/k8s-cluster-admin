# 03‑pod‑api‑access.md（纯实操）
## 实验目标
1. 理解Pod内部访问 kubernetes‑apiserver 的访问链路；
2. 实操在容器内利用挂载的serviceaccount‑token调用APIServer；
3. 明白环境变量 `KUBERNETES_SERVICE_HOST`、`KUBERNETES_SERVICE_PORT` 的作用；
4. 验证SA绑定的RBAC权限对Pod生效。

## 环境说明
- k8s‑v1.32.13，master：192.168.11.161
- namespace：dev
- ServiceAccount：app‑sa，已经绑定view权限。

## 步骤1：前置部署资源
```bash
# 创建sa
kubectl create sa app-sa -n dev

# 绑定view权限
cat > sa-rb.yaml <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-sa-view-bind
  namespace: dev
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
EOF
kubectl apply -f sa-rb.yaml

# 创建pod指定serviceAccountName
cat > apicurl-pod.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: apicurl-pod
  namespace: dev
spec:
  serviceAccountName: app-sa
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["sleep", "86400"]
EOF
kubectl apply -f apicurl-pod.yaml
kubectl get pod apicurl-pod -n dev
```

## 步骤2：进入Pod查看内置环境变量和挂载文件
```bash
kubectl exec -it apicurl-pod -n dev -- sh

# 查看apiserver连接地址环境变量
env | grep KUBERNETES_SERVICE
# KUBERNETES_SERVICE_HOST=10.96.0.1
# KUBERNETES_SERVICE_PORT=443

# 查看自动挂载的凭证目录
ls /var/run/secrets/kubernetes.io/serviceaccount
# ca.crt  namespace  token
```
关键点：
1. `kubernetes.default.svc` 解析到 Cluster‑IP：10.96.0.1；
2. token为bound‑token，有效期默认1小时，apiserver自动刷新；
3. ca.crt用于校验apiserver证书。

## 步骤3：容器内部执行curl调用APIServer（核心实操）
Pod内执行：
```bash
# 变量赋值
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACRT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
APISERVER="https://kubernetes.default.svc:443"

# 获取dev命名空间下pod列表（view权限允许）
curl --cacert ${CACRT} -H "Authorization: Bearer ${TOKEN}" \
${APISERVER}/api/v1/namespaces/dev/pods
```
返回json数据代表访问成功。

### 测试没有权限的操作（预期返回403‑Forbidden）
```bash
# 尝试删除pod，view角色不允许删除资源
curl -X DELETE --cacert ${CACRT} -H "Authorization: Bearer ${TOKEN}" \
${APISERVER}/api/v1/namespaces/dev/pods/apicurl-pod
```

## 步骤4：测试使用default默认ServiceAccount（对比实验）
1. 新建Pod不指定serviceAccountName，自动使用当前ns的default SA：
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: default-sa-pod
  namespace: dev
spec:
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["sleep","86400"]
```
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: default-sa-pod
  namespace: dev
spec:
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["sleep","86400"]
EOF

kubectl exec -it default-sa-pod -n dev -- sh
```
```bash
# default‑sa默认没有任何RBAC权限，访问pod会返回403
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACRT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
APISERVER="https://kubernetes.default.svc:443"
curl --cacert ${CACRT} -H "Authorization: Bearer ${TOKEN}" ${APISERVER}/api/v1/namespaces/dev/pods
```
> 结论：默认default‑sa未绑定RBAC，业务Pod不要使用default账号。

## 步骤5：在master节点验证SA身份（外部验证）
```bash
# SA固定身份格式 system:serviceaccount:命名空间:sa名称
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:app-sa
kubectl auth can-i delete pods -n dev --as=system:serviceaccount:dev:app-sa
```

## 步骤6：梳理完整访问流程（面试要点）
1. Pod启动时，如果`automountServiceAccountToken: true`，自动挂载短期token；
2. 容器读取 `/var/run/secrets/kubernetes.io/serviceaccount` 下面token与CA；
3. 请求发送到 `kubernetes.default.svc:443`；
4. apiserver解析token识别身份：`system:serviceaccount:dev:app‑sa`；
5. RBAC判定该账号是否允许对应操作；
6. 准入控制器再次校验，最后返回结果。

## 清理资源
```bash
kubectl delete pod apicurl-pod default-sa-pod -n dev
kubectl delete rolebinding app-sa-view-bind -n dev
kubectl delete sa app-sa -n dev
rm -f sa-rb.yaml apicurl-pod.yaml
```

## 实验验收条件
1. 进入Pod可以看到serviceaccount挂载文件；
2. 在容器内部curl apiserver获取pod列表；
3. 验证view角色不能执行删除操作；
4. 理解default‑sa默认无权限。

下一步：04‑serviceaccount‑security.md。