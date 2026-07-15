# 03‑create‑user‑kubeconfig.md（仅实操命令，精简版）
## 实验目标
1. 使用 openssl 签发自定义客户端证书，创建普通用户 `dev-user`。
2. 基于证书文件生成独立的 kubeconfig。
3. 通过 RBAC 分配指定命名空间权限，限制用户只能操作 `dev` namespace。
4. 验证权限：dev‑user不能查看kube‑system资源。
## 环境说明
- master节点：192.168.11.161
- k8s CA证书目录：/etc/kubernetes/pki/
- CA证书：ca.crt、ca.key

## 步骤1：在master节点生成用户证书
```bash
# 1. 创建工作目录
mkdir -p /opt/user-cert && cd /opt/user-cert

# 2. 生成私钥 dev-user.key
openssl genrsa -out dev-user.key 2048

# 3. 生成证书签发请求，CN为用户名，O为用户组
openssl req -new -key dev-user.key -out dev-user.csr -subj "/CN=dev-user/O=dev-group"

# 4. 使用集群CA签发证书，有效期365天
openssl x509 -req -in dev-user.csr \
-CA /etc/kubernetes/pki/ca.crt \
-CAkey /etc/kubernetes/pki/ca.key \
-CAserial /etc/kubernetes/pki/ca.srl \
-out dev-user.crt \
-days 365
```
验证证书内容：
```bash
openssl x509 -in dev-user.crt -text -noout
# 确认 CN=dev‑user，O=dev‑group
```

## 步骤2：构建普通用户kubeconfig
### 2.1 定义环境变量简化后续命令
```bash
# APIServer地址
APISERVER="https://192.168.11.161:6443"
# 集群名称
CLUSTER_NAME="kubernetes"
USER_NAME="dev-user"
CONTEXT_NAME="${USER_NAME}@${CLUSTER_NAME}"
NAMESPACE="dev"
```

### 2.2 设置集群信息，注入CA‑data
```bash
kubectl config set-cluster ${CLUSTER_NAME} \
--server=${APISERVER} \
--certificate-authority=/etc/kubernetes/pki/ca.crt \
--embed-certs=true \
--kubeconfig=./dev-user-kubeconfig
```

### 2.3 添加用户凭证（嵌入证书和私钥）
```bash
kubectl config set-credentials ${USER_NAME} \
--client-certificate=./dev-user.crt \
--client-key=./dev-user.key \
--embed-certs=true \
--kubeconfig=./dev-user-kubeconfig
```

### 2.4 创建上下文并指定默认命名空间
```bash
kubectl config set-context ${CONTEXT_NAME} \
--cluster=${CLUSTER_NAME} \
--user=${USER_NAME} \
--namespace=${NAMESPACE} \
--kubeconfig=./dev-user-kubeconfig

# 激活当前上下文
kubectl config use-context ${CONTEXT_NAME} --kubeconfig=./dev-user-kubeconfig
```

## 步骤3：集群端创建RBAC权限（重点）
1. 先创建dev命名空间
```bash
kubectl create namespace dev
```
2. 编写role‑rolebinding.yaml
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-role
  namespace: dev
rules:
- apiGroups: ["","apps"]
  resources: ["pods","deployments","services"]
  verbs: ["get","list","create","delete","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-rolebind
  namespace: dev
subjects:
- kind: User
  name: dev-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: dev-role
  apiGroup: rbac.authorization.k8s.io
```
执行：
```bash
kubectl apply -f role-rolebinding.yaml
```

## 步骤4：权限验证测试
### 4.1 测试dev命名空间内资源（允许）
```bash
# 使用dev‑user配置文件执行命令
kubectl get pods -n dev --kubeconfig=./dev-user-kubeconfig
kubectl create deployment nginx --image=nginx -n dev --kubeconfig=./dev-user-kubeconfig
```

### 4.2 测试访问kube‑system（会返回Forbidden，符合预期）
```bash
kubectl get pods -n kube-system --kubeconfig=./dev-user-kubeconfig
```

### 4.3 auth can‑i 权限核查命令
```bash
kubectl auth can-i create pods -n dev --kubeconfig=./dev-user-kubeconfig
kubectl auth can-i delete nodes --kubeconfig=./dev-user-kubeconfig
```

## 步骤5：交付配置给开发用户
```bash
# 将配置下发给普通用户
cp ./dev-user-kubeconfig /home/dev/.kube/config
chown dev:dev /home/dev/.kube/config
chmod 600 /home/dev/.kube/config
# 切换dev用户自行操作
su dev
kubectl get pods -n dev
```

## 实验验收条件
1. openssl成功签发证书，能够看到CN和Group；
2. 生成独立kubeconfig文件；
3. dev‑user只能操作dev命名空间资源；
4. 访问集群级别资源或者kube‑system会被拒绝。

## 生产注意事项 & 排障要点
1. 证书有效期合理规划，到期前更新证书；
2. kubeconfig文件权限必须设置600；
3. 区分User和ServiceAccount：当前是给人使用的用户，后续章节为Pod内部SA账号；
4. 排障思路：
   - forbidden：检查Role、RoleBinding绑定的用户名是否和证书CN完全一致；
   - 连接失败：检查APIServer地址和CA证书是否正确。

下一步我写：04‑kubeconfig‑context.md。