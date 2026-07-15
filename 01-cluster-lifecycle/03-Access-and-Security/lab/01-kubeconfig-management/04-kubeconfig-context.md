# 04‑kubeconfig‑context.md（纯实操）
## 实验目标
1. 在同一个kubeconfig文件中维护 dev / test / prod 三套context。
2. 基于前面创建的 dev‑user，再新建 test‑user；prod沿用kubernetes‑admin。
3. 练习查看、切换上下文、设置默认namespace。
4. 区分：修改context只切换配置，集群本身不会改动。

## 环境前置
master：192.168.11.161
已有内容：
- dev‑user（CN=dev‑user，操作dev命名空间）
- kubernetes‑admin（集群管理员）

## 步骤1：生成test‑user证书与kubeconfig片段
```bash
cd /opt/user-cert
# 创建test‑user证书
openssl genrsa -out test-user.key 2048
openssl req -new -key test-user.key -out test-user.csr -subj "/CN=test-user/O=test-group"
openssl x509 -req -in test-user.csr \
-CA /etc/kubernetes/pki/ca.crt \
-CAkey /etc/kubernetes/pki/ca.key \
-CAserial /etc/kubernetes/pki/ca.srl \
-out test-user.crt -days 365
```
创建test命名空间并绑定RBAC：
```bash
kubectl create ns test
```
```yaml
# test‑role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: test-role
  namespace: test
rules:
- apiGroups: ["","apps"]
  resources: ["pods","deployments"]
  verbs: ["get","list","create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: test-rolebind
  namespace: test
subjects:
- kind: User
  name: test-user
roleRef:
  kind: Role
  name: test-role
  apiGroup: rbac.authorization.k8s.io
```
```bash
kubectl apply -f test-role.yaml
```

## 步骤2：把3个用户配置合并到同一个kubeconfig（重点）
这里复用集群配置，集群只有一套，区分user和context。
```bash
APISERVER="https://192.168.11.161:6443"
KUBECONFIG_MERGE=./multi-env-config

# 1. 添加集群信息
kubectl config set-cluster kubernetes \
--server=${APISERVER} \
--certificate-authority=/etc/kubernetes/pki/ca.crt \
--embed-certs=true \
--kubeconfig=${KUBECONFIG_MERGE}

# 2. 添加3个user：admin、dev‑user、test‑user
# admin用户
kubectl config set-credentials kubernetes-admin \
--client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt \
--client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key \
--embed-certs=true --kubeconfig=${KUBECONFIG_MERGE}

# dev‑user
kubectl config set-credentials dev-user \
--client-certificate=./dev-user.crt \
--client-key=./dev-user.key \
--embed-certs=true --kubeconfig=${KUBECONFIG_MERGE}

# test‑user
kubectl config set-credentials test-user \
--client-certificate=./test-user.crt \
--client-key=./test-user.key \
--embed-certs=true --kubeconfig=${KUBECONFIG_MERGE}

# 3. 创建3套context，各自绑定默认ns
kubectl config set-context dev@kubernetes \
--cluster=kubernetes \
--user=dev-user \
--namespace=dev \
--kubeconfig=${KUBECONFIG_MERGE}

kubectl config set-context test@kubernetes \
--cluster=kubernetes \
--user=test-user \
--namespace=test \
--kubeconfig=${KUBECONFIG_MERGE}

kubectl config set-context prod@kubernetes \
--cluster=kubernetes \
--user=kubernetes-admin \
--namespace=default \
--kubeconfig=${KUBECONFIG_MERGE}
```

## 步骤3：context查看与切换实操
```bash
# 指定配置文件查看上下文列表
export KUBECONFIG=./multi-env-config
kubectl config get-contexts
# 输出三行：dev@kubernetes、test@kubernetes、prod@kubernetes

# 查看当前context
kubectl config current-context

# 切换到dev环境
kubectl config use-context dev@kubernetes
kubectl create deploy nginx-dev --image=nginx

# 切换test环境
kubectl config use-context test@kubernetes
kubectl create deploy nginx-test --image=nginx

# 切换prod管理员环境
kubectl config use-context prod@kubernetes
kubectl get nodes
```

## 步骤4：修改context默认namespace（实操）
```bash
# 不新建上下文，更新现有context里的namespace
kubectl config set-context dev@kubernetes --namespace=dev-new
kubectl config use-context dev@kubernetes
```

## 步骤5：全局环境变量用法（生产常用）
```bash
# 方式1：临时指定配置文件
KUBECONFIG=./multi-env-config kubectl get pods

# 方式2：写入环境变量永久生效
echo "export KUBECONFIG=/opt/user-cert/multi-env-config" >> /root/.bashrc
source /root/.bashrc
```

## 步骤6：清理context和删除上下文命令
```bash
# 删除不用的context
kubectl config delete-context test@kubernetes

# 删除用户
kubectl config unset users.test-user
```

## 实验验收标准
1. multi‑env‑config内部同时包含3个context；
2. 切换dev只能操作dev命名空间；
3. 切换test只能操作test；
4. 切换prod可以查看集群全部资源；
5. 会通过环境变量 KUBECONFIG 指定配置文件。

## 问题排查
1. 切换context之后权限不对：检查RoleBinding中的用户名和证书CN必须完全一致；
2. 多人维护多集群：可以在同一个kubeconfig里添加多个cluster，对应不同apiserver地址；
3. 生产规范：开发人员只下发对应自己的context，不要把admin‑user放进开发机器kubeconfig。

下一步：05‑kubeconfig‑troubleshooting.md。