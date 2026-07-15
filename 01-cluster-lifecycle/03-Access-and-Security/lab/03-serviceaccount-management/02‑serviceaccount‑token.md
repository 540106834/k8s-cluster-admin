# 02‑serviceaccount‑token.md（纯实操）
## 实验目标
1. 理解 K8s‑1.24+ BoundServiceAccountTokenVolume 机制，区分传统长久token和pod绑定的短期Token。
2. 分别查看静态长久Token和Pod内自动挂载的临时Token。
3. 理解Token有效期、自动轮换。
4. 提取token，手动curl apiserver做认证测试。

## 环境信息
- k8s v1.32.13，master‑01：192.168.11.161
- namespace: dev

## 前置知识点
1. k8s 1.24之前：创建SA自动生成永久Secret‑Token，长期有效，泄露风险高；
2. k8s‑1.24之后默认开启 BoundServiceAccountTokenVolume：
   - Pod启动时自动挂载短期token；
   - 默认有效期1h，apiserver自动后台轮换；
   - 不在etcd生成Secret资源。

## 步骤1：重建实验SA
```bash
kubectl create sa app-sa -n dev
kubectl get sa -n dev
```

## 步骤2：方式1：手动创建长久静态Token（兼容旧版方式，生产尽量少用）
sa‑static‑token.yaml
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-sa-static-token
  namespace: dev
  annotations:
    kubernetes.io/service-account.name: app-sa
type: kubernetes.io/service-account-token
```
```bash
kubectl apply -f sa-static-token.yaml

# 获取token
TOKEN=$(kubectl get secret app-sa-static-token -n dev -o jsonpath={.data.token} | base64 -d)
echo $TOKEN

# 获取CA证书
CA_CRT=$(kubectl get secret app-sa-static-token -n dev -o jsonpath={.data['ca.crt']} | base64 -d)
echo "$CA_CRT" > ca.crt
```

### 使用静态token访问apiserver
```bash
APISERVER="https://192.168.11.161:6443"
curl --cacert ca.crt -H "Authorization: Bearer ${TOKEN}" ${APISERVER}/api/v1/namespaces/dev/pods
```

## 步骤3：方式2：创建Pod，查看容器内部自动挂载的短期Token（1.24+主流模式）
pod-sa.yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sa-test-pod
  namespace: dev
spec:
  serviceAccountName: app-sa
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["sleep","36000"]
```
```bash
kubectl apply -f pod-sa.yaml
kubectl get pod -n dev
```

### 进入容器查看挂载目录
```bash
kubectl exec -it sa-test-pod -n dev -- sh
# pod内部默认挂载目录
ls /var/run/secrets/kubernetes.io/serviceaccount/
# 里面3个文件：token、ca.crt、namespace
```
- token：临时凭证，默认有效期1小时，kube‑apiserver自动更新；
- 容器内文件会被apiserver动态刷新，无需重启Pod。

### 在Pod内部调用apiserver
```bash
# 容器内部执行
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CACRT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
APISERVER=https://kubernetes.default.svc:443
curl --cacert ${CACRT} -H "Authorization: Bearer ${TOKEN}" ${APISERVER}/api/v1/namespaces/dev/pods
```

## 步骤4：配置Token自定义有效期（实操）
修改kube‑apiserver启动参数，控制bound‑token最大时长，仅master节点操作。
```bash
# 查看apiserver启动参数
cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -i service-account-max
```
- 默认值：`--service-account-token-max=3600`（1小时）
- 如需调整，修改静态Pod清单，修改后apiserver自动重启。
> 生产建议保持默认1h，缩短token有效期降低泄露风险。

## 步骤5：权限验证，给SA分配view权限
rolebind-sa.yaml
```yaml
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
```
```bash
kubectl apply -f rolebind-sa.yaml

# 在master节点模拟sa账号权限
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:app-sa
kubectl auth can-i delete pods -n dev --as=system:serviceaccount:dev:app-sa
```

## 步骤6：生产区分两个Token方案（面试重点）
1. 手动创建secret‑token（长久token）
   - 优点：可以把token拿到集群外部使用；
   - 缺点：永久有效，一旦泄露风险极高；仅用于外部程序访问集群。
2. Bound‑ServiceAccount‑Token（pod内部自动挂载短期token）
   - 优点：短期有效，apiserver自动轮换，安全；
   - 缺点：只能在Pod内部使用。

## 清理实验资源
```bash
kubectl delete pod sa-test-pod -n dev
kubectl delete secret app-sa-static-token -n dev
kubectl delete rolebinding app-sa-view-bind -n dev
kubectl delete sa app-sa -n dev
rm -f ca.crt
```

## 实验验收标准
1. 能够区分长久Token和bound‑token；
2. 进入Pod查看挂载目录；
3. 拿到token后curl apiserver；
4. 掌握SA完整身份名称：`system:serviceaccount:dev:app‑sa`。

下一节：03‑pod‑api‑access.md。