# 05-service-account-kubeconfig.md

## 一、文档基础信息

- 所属目录：`05-kubeconfig-management/`
- 前置阅读：01-kubeconfig-overview.md、02-kubeconfig-structure.md
- 集群环境：K8s v1.32.13 单Master，API地址 `https://192.168.11.161:6443`
- 执行节点：仅 k8s-master-01
- 适用场景：后台脚本、监控组件、CI/CD、外部程序无人工账号访问集群；无需客户端证书，仅使用ServiceAccount静态Token认证

## 二、核心原理

1. ServiceAccount（SA）是集群内置的内置身份，隶属于某个命名空间；
2. 创建SA后集群自动生成绑定Secret，内部存放加密JWT Token（JSON Web Token）；
3. kubeconfig 使用 `token` 字段完成认证，无需证书；
4. 配合RBAC绑定权限，实现程序最小权限访问集群API。

## 三、全局变量统一定义

```bash
# 自定义SA名称
SA_NAME="app-metrics-sa"
# 绑定命名空间
SA_NS="monitor"
# 输出kubeconfig存放目录
KUBE_CONF_DIR="/usr/local/src/kubeconfig"
# 集群API地址
API_SERVER="https://192.168.11.161:6443"
# 集群CA证书路径
CA_CRT="/etc/kubernetes/pki/ca.crt"
```

## 四、步骤1：创建命名空间与ServiceAccount

```bash
# 创建命名空间
kubectl create ns ${SA_NS}

# 创建ServiceAccount
kubectl create sa ${SA_NAME} -n ${SA_NS}
```

## 五、步骤2：绑定RBAC权限（两种常用模板）

### 模板1：命名空间内只读权限（view）

```yaml
# /usr/local/src/rbac/sa-ns-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${SA_NAME}-ns-read
  namespace: ${SA_NS}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${SA_NS}
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f /usr/local/src/rbac/sa-ns-read.yaml
```

### 模板2：集群全局只读权限（全集群查看资源）

```yaml
# /usr/local/src/rbac/sa-cluster-view.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SA_NAME}-global-view
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${SA_NS}
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f /usr/local/src/rbac/sa-cluster-view.yaml
```

## 六、步骤3：提取SA内置Token & 组装独立kubeconfig

### 6.1 自动获取SA绑定的Secret名称

```bash
# 获取SA关联secret名称
SA_SECRET=$(kubectl get sa ${SA_NAME} -n ${SA_NS} -o jsonpath="{.secrets[0].name}")

# 解码Token明文
SA_TOKEN=$(kubectl get secret ${SA_SECRET} -n ${SA_NS} -o jsonpath="{.data.token}" | base64 --decode)

# 读取集群CA base64
CA_BASE64=$(cat ${CA_CRT} | base64 -w 0)
```

### 6.2 生成SA专用kubeconfig文件

```bash
mkdir -p ${KUBE_CONF_DIR}
SA_KUBECONFIG=${KUBE_CONF_DIR}/${SA_NAME}-sa-kubeconfig

# 写入完整kubeconfig（Token认证模式，无客户端证书）
cat > ${SA_KUBECONFIG} <<EOF
apiVersion: v1
kind: Config
current-context: ${SA_NAME}@k8s-cluster
clusters:
- name: k8s-cluster
  cluster:
    server: ${API_SERVER}
    certificate-authority-data: ${CA_BASE64}
users:
- name: ${SA_NAME}
  user:
    token: ${SA_TOKEN}
contexts:
- name: ${SA_NAME}@k8s-cluster
  context:
    cluster: k8s-cluster
    user: ${SA_NAME}
    namespace: ${SA_NS}
EOF

# 收紧文件权限
chmod 600 ${SA_KUBECONFIG}
```

## 七、验证SA kubeconfig可用性

```bash
# 指定配置文件测试访问集群
export KUBECONFIG=${KUBE_CONF_DIR}/${SA_NAME}-sa-kubeconfig

# 可读操作正常
kubectl get pods -n ${SA_NS}
kubectl get nodes

# 写操作会返回Forbidden（只读权限示例）
kubectl create deploy test --image=harbor.jinshaoyong.com/k8s/busybox -n ${SA_NS}
```

## 八、Pod内自动挂载SA（无需手动kubeconfig）

集群默认自动挂载当前命名空间SA到容器内路径：

```bash
/var/run/secrets/kubernetes.io/serviceaccount/
├── ca.crt
├── namespace
└── token
```

程序可直接读取内置Token调用API，无需手动生成kubeconfig。

## 九、SA资源清理（停用程序时回收权限）

```bash
# 删除RBAC绑定
kubectl delete clusterrolebinding ${SA_NAME}-global-view
kubectl delete rolebinding -n ${SA_NS} ${SA_NAME}-ns-read

# 删除SA
kubectl delete sa ${SA_NAME} -n ${SA_NS}

# 删除本地kubeconfig文件
rm -f ${KUBE_CONF_DIR}/${SA_NAME}-sa-kubeconfig
```

## 十、安全最佳实践

1. 遵循最小权限原则，仅绑定程序所需资源读写权限，禁止绑定`cluster-admin`；
2. SA Token长期有效，若泄露需立刻删除SA重建刷新Token；
3. 对外分发SA kubeconfig仅内网传输，禁止公网明文存放；
4. 文件权限强制`600`，避免其他用户读取Token；
5. 不同业务程序使用独立ServiceAccount，不共用一套Token。

## 十一、常见故障排查

1. **Forbidden: User "system:serviceaccount:xxx:xxx" cannot list nodes**
   RBAC绑定缺失/权限不足，补充对应ClusterRoleBinding/RoleBinding。
2. **x509 certificate signed by unknown authority**
   kubeconfig内`certificate-authority-data`缺失或CA base64编码错误。
3. **Token鉴权失败**
   SA已被删除、Secret被删除，重建ServiceAccount重新提取Token。
4. **kubectl提示 config file permissions are too open**
   执行 `chmod 600 xxx-sa-kubeconfig` 修复权限。

## 十二、文档关联

- 前置：02-kubeconfig-structure.md 两种认证结构对比（证书/Token）
- 对比参考：04-user-kubeconfig.md 自定义证书用户（长期证书）
- 分发导出：10-kubeconfig-export.md
- 证书轮换：12-kubeconfig-rotation.md（SA Token无需手动轮换，重建SA即可刷新）
- 故障汇总：15-troubleshooting.md