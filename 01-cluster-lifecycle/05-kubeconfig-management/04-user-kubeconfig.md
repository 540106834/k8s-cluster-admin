# 04-user-kubeconfig.md

## 一、文档基础信息

- 所属目录：`05-kubeconfig-management/`
- 前置阅读：`01-kubeconfig-overview.md`、`02-kubeconfig-structure.md`、`03-admin-conf.md`
- 集群环境：Kubernetes v1.32.13 单Master，API地址 `https://192.168.11.161:6443`
- 执行节点：仅 Master `k8s-master-01`
- 场景：基于集群根CA签发自定义用户证书，绑定RBAC权限，生成最小权限独立kubeconfig，**禁止直接分发admin.conf**

## 二、整体流程

1. 生成用户私钥与证书签发请求 csr
2. 使用集群CA签署客户端证书
3. 创建RBAC Role/ClusterRole + RoleBinding/ClusterRoleBinding分配权限
4. 组装独立kubeconfig（内置CA、用户证书、私钥base64）
5. 收紧文件权限、导出分发

## 三、统一变量定义（全程复用）

```bash
# 自定义用户名，示例：ops-read（只读运维）
USER_NAME="ops-read"
# 证书存放临时目录
CERT_DIR="/usr/local/src/user-certs/${USER_NAME}"
# kubeconfig输出目录
KUBE_CONF_DIR="/usr/local/src/kubeconfig"
# API地址
API_SERVER="https://192.168.11.161:6443"
# 集群CA路径
CA_CRT="/etc/kubernetes/pki/ca.crt"
CA_KEY="/etc/kubernetes/pki/ca.key"
```

## 四、步骤1：生成用户证书与私钥

```bash
# 创建证书目录
mkdir -p ${CERT_DIR}
cd ${CERT_DIR}

# 1. 生成私钥
openssl genrsa -out ${USER_NAME}.key 2048

# 2. 生成CSR，CN为用户名，O可自定义分组
openssl req -new -key ${USER_NAME}.key -out ${USER_NAME}.csr -subj "/CN=${USER_NAME}/O=ops-group"

# 3. 使用集群CA签署证书，有效期365天
openssl x509 -req -in ${USER_NAME}.csr -CA ${CA_CRT} -CAkey ${CA_KEY} \
-CAcreateserial -out ${USER_NAME}.crt -days 365
```

## 五、步骤2：创建RBAC权限（两种常用模板）

### 模板A：集群全局只读权限（ClusterRole view）

适合运维查看所有资源，无修改/删除权限

```yaml
# /usr/local/src/rbac/${USER_NAME}-cluster-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${USER_NAME}-global-read
subjects:
- kind: User
  name: ${USER_NAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f /usr/local/src/rbac/${USER_NAME}-cluster-read.yaml
```

### 模板B：单命名空间读写权限（仅能操作default）

```yaml
# /usr/local/src/rbac/${USER_NAME}-ns-write.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${USER_NAME}-ns-write
  namespace: default
subjects:
- kind: User
  name: ${USER_NAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: edit
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f /usr/local/src/rbac/${USER_NAME}-ns-write.yaml
```

## 六、步骤3：组装独立用户kubeconfig

```bash
mkdir -p ${KUBE_CONF_DIR}
USER_KUBECONFIG=${KUBE_CONF_DIR}/${USER_NAME}-kubeconfig

# 清空旧配置
> ${USER_KUBECONFIG}

# 1. 设置集群信息，写入CA base64
kubectl config --kubeconfig=${USER_KUBECONFIG} set-cluster k8s-cluster \
--server=${API_SERVER} \
--certificate-authority=${CA_CRT} \
--embed-certs=true

# 2. 设置用户证书私钥，嵌入文件
kubectl config --kubeconfig=${USER_KUBECONFIG} set-credentials ${USER_NAME} \
--client-certificate=${CERT_DIR}/${USER_NAME}.crt \
--client-key=${CERT_DIR}/${USER_NAME}.key \
--embed-certs=true

# 3. 创建上下文，绑定集群+用户，默认命名空间default
kubectl config --kubeconfig=${USER_KUBECONFIG} set-context ${USER_NAME}@k8s-cluster \
--cluster=k8s-cluster \
--user=${USER_NAME} \
--namespace=default

# 4. 设置默认上下文
kubectl config --kubeconfig=${USER_KUBECONFIG} use-context ${USER_NAME}@k8s-cluster

# 收紧权限
chmod 600 ${USER_KUBECONFIG}
```

## 七、验证用户权限

```bash
# 指定配置文件测试
export KUBECONFIG=${KUBE_CONF_DIR}/${USER_NAME}-kubeconfig

# 可读操作（正常）
kubectl get nodes
kubectl get pods -A

# 写操作（只读账号会报错Forbidden）
kubectl create pod test --image=harbor.jinshaoyong.com/k8s/busybox
```

## 八、分发至远程机器（Worker/运维本地）

```bash
# scp内网传输
scp ${KUBE_CONF_DIR}/${USER_NAME}-kubeconfig root@目标IP:/root/

# 目标机器执行
mkdir -p ~/.kube
mv ${USER_NAME}-kubeconfig ~/.kube/config
chmod 600 ~/.kube/config

# 验证
kubectl get pods
```

## 九、批量清理用户（证书+RBAC+kubeconfig）

```bash
# 删除RBAC绑定
kubectl delete clusterrolebinding ${USER_NAME}-global-read
kubectl delete rolebinding -n default ${USER_NAME}-ns-write

# 删除证书文件
rm -rf ${CERT_DIR}

# 删除kubeconfig
rm -f ${KUBE_CONF_DIR}/${USER_NAME}-kubeconfig
```

## 十、安全规范

1. 权限最小化：禁止给普通用户 cluster-admin
2. 证书有效期统一365天，到期轮换（12-kubeconfig-rotation.md）
3. kubeconfig文件权限强制 `600`，禁止公网传输
4. 不允许将用户私钥crt/key明文分发，仅分发嵌入证书的kubeconfig单文件
5. 多人使用分别创建独立用户，不共用一份配置

## 十一、常见故障

1. **操作资源报 Forbidden**
   RBAC绑定未创建、绑定命名空间不匹配、ClusterRole权限不足
2. **x509 certificate signed by unknown authority**
   组装kubeconfig未加 `--embed-certs=true`，CA未嵌入文件
3. **证书过期**
   重新签发证书，替换kubeconfig内证书内容
4. **kubectl提示权限过大**
   `chmod 600 xxx-kubeconfig`

## 十二、文档关联

- 前置：02-kubeconfig-structure 三层结构、03-admin-conf 管理员配置
- 同类对比：05-service-account-kubeconfig（Token认证方式）
- 分发管理：10-kubeconfig-export.md
- 证书更新：12-kubeconfig-rotation.md
- 故障：15-troubleshooting.md
  