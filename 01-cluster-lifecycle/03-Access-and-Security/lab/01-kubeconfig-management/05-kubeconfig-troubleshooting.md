# 05‑kubeconfig‑troubleshooting.md（纯实操版，只执行命令）
## 实验目标
1. 复现 3 类高频故障：证书过期、连接拒绝、权限禁止；
2. 定位根因；
3. 给出对应修复操作；
4. 形成固定排查顺序：连通性 → 证书有效性 → RBAC权限。
实验环境：master‑01：192.168.11.161

## 前置准备
沿用前面的文件：
`/opt/user‑cert/dev‑user‑kubeconfig`、`/etc/kubernetes/admin.conf`

---

## 场景1：certificate‑expired 证书过期问题
### 1.1 故障复现（模拟过期，这里用查看证书有效期方式实操）
```bash
# 1.解码客户端证书
cd /opt/user-cert
openssl x509 -in dev-user.crt -text -noout | grep -A5 Validity
```
- 看到 Not After 日期到期，执行kubectl会报错：`x509: certificate has expired or is not yet valid`。

### 1.2 排障步骤（固定流程）
1）确认是哪一类证书过期
- 管理员证书：master节点使用 `kubeadm certs check-expiration`
```bash
kubeadm certs check-expiration
```
- 自定义用户证书（openssl签发）：重新生成证书。

### 1.3 修复实操
#### 情况A：kubeadm管理的集群内部证书（apiserver、admin‑conf）
```bash
# 全部证书续期
kubeadm certs renew all
# 覆盖admin.conf
cp /etc/kubernetes/admin.conf ~/.kube/config
```
#### 情况B：openssl自建普通用户证书 dev‑user
```bash
cd /opt/user-cert
# 重新签发证书
openssl x509 -req -in dev-user.csr \
-CA /etc/kubernetes/pki/ca.crt \
-CAkey /etc/kubernetes/pki/ca.key \
-CAserial /etc/kubernetes/pki/ca.srl \
-out dev-user.crt -days 3650
# 更新kubeconfig里证书内容
kubectl config set-credentials dev-user \
--client-certificate=./dev-user.crt \
--client-key=./dev-user.key \
--embed-certs=true \
--kubeconfig=./dev-user-kubeconfig
```
### 验证修复结果
```bash
kubectl get pods -n dev --kubeconfig=./dev-user-kubeconfig
```

### 根因总结
1. openssl签发时days设置太短；
2. kubeadm默认证书1年有效期，到期前30天规划续期。

---

## 场景2：connection‑refused APIServer连接被拒绝
### 2.1 手动制造故障（修改kubeconfig里server地址）
```bash
# 复制一份配置做错误测试
cp dev-user-kubeconfig bad-config
# 修改server地址故意写错（比如改成192.168.11.160）
vi bad-config
# server: https://192.168.11.160:6443
kubectl get nodes --kubeconfig=./bad-config
# 报错：dial tcp 192.168.11.160:6443: connect: connection refused
```

### 2.2 排障检查步骤（按顺序执行）
#### 步骤1：网络层测试（在运行kubectl的机器执行）
```bash
# 测试6443端口通不通
nc -zv 192.168.11.161 6443
# 不通的原因：防火墙、安全组、apiserver停止、IP写错
```
#### 步骤2：确认apiserver组件状态（master节点）
```bash
crictl ps | grep kube-apiserver
# 容器异常就重启静态pod
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp
sleep 3
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```
#### 步骤3：核对kubeconfig内server字段
```bash
kubectl config view --kubeconfig=./bad-config -o jsonpath='{.clusters[0].cluster.server}'
# 正确值只能是 https://192.168.11.161:6443
```

### 2.3 修复配置
```bash
kubectl config set-cluster kubernetes \
--server=https://192.168.11.161:6443 \
--certificate-authority=/etc/kubernetes/pki/ca.crt \
--embed-certs=true \
--kubeconfig=./bad-config
# 验证
kubectl get pods -n dev --kubeconfig=./bad-config
```

### 常见原因清单
1. server的IP或者端口填写错误；
2. master节点防火墙放行6443端口不足；
3. kube‑apiserver容器崩溃；
4. worker节点执行kubectl但是无法访问master的6443。

---

## 场景3：forbidden！用户权限不足（最高频）
### 3.1 故障复现
dev‑user本来仅允许dev命名空间，执行查看kube‑system资源：
```bash
kubectl get pods -n kube-system --kubeconfig=./dev-user-kubeconfig
# 报错：Forbidden! User "dev‑user" cannot list pods in the namespace "kube‑system"
```

### 3.2 标准化排查步骤（生产固定套路）
#### 第一步：提取当前客户端证书里的用户名
```bash
# 解码证书查看CN
openssl x509 -in dev-user.crt -text -noout | grep CN
# 得到用户名 dev‑user，这个名称必须和RBAC subjects.name完全一致
```

#### 第二步：使用kubectl auth can‑i精准判定权限
```bash
# 判断在kube‑system能不能获取pod
kubectl auth can-i list pods -n kube-system --kubeconfig=./dev-user-kubeconfig
# 返回no，确认权限缺失
# 查看该用户绑定了哪些RoleBinding
kubectl get rolebindings -n dev
kubectl describe rolebinding dev-rolebind -n dev
```
重点核对3项：
1. subjects.name 和证书CN一模一样；
2. RoleBinding所在namespace和Role一致；
3. Role的rules里verbs、apiGroups、resources匹配操作资源。

### 3.3 两种修复方案
方案‑1：修改Role放开权限（测试用）
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-role
  namespace: dev
rules:
- apiGroups: ["","apps"]
  resources: ["pods","deployments","services"]
  verbs: ["*"]
```
```bash
kubectl apply -f role-rolebinding.yaml
```
方案‑2：如需集群级权限使用ClusterRole + ClusterRoleBinding
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dev-cluster-bind
subjects:
- kind: User
  name: dev-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
```
```bash
kubectl apply -f cluster-rolebind.yaml
```

### 3.4 forbidden高频踩坑点（面试重点）
1. RoleBinding的用户名拼写和证书CN不一致（空格、大小写问题）；
2. Role是namespace级别，不能跨命名空间生效；
3. 区分：RoleBinding（命名空间级别）、ClusterRoleBinding（集群级别）；
4. 证书里的O字段（组）如果配置了，可以针对用户组授权。

---

## 统一排障顺序（记这个顺序）
1. connection‑refused：先网络连通性 → apiserver状态 → kubeconfig的server配置；
2. certificate‑expired：解码证书看有效期 → 判断是kubeadm证书还是openssl证书 → 续期；
3. forbidden：提取证书CN → auth can‑i校验 → 检查RoleBinding和Role定义。

## 实验验收
1. 能够复现三种报错；
2. 每条故障可以对应命令定位；
3. 完成修复，命令执行正常；
4. 区分：证书问题、网络问题、RBAC权限问题。

到此 `01‑kubeconfig‑management` 目录所有实操完成。接下来开启02‑rbac‑management模块？