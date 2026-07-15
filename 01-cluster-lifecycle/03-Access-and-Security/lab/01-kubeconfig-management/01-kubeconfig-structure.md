我直接给你**纯实操、无理论、可直接照着做的实验内容**，不在文档渲染、纯问答展示：

# 01-kubeconfig-structure 实验实操（纯操作版）
## 一、实验目的
仅实操：查看、拆解、手动构造 kubeconfig 文件，熟练掌握 cluster / user / context 结构与证书编解码。

## 二、实验环境
K8s v1.32.13 单 master
master IP：192.168.11.161
APIServer 端口：6443

## 三、前置检查
```bash
kubectl get nodes
```

## 四、实操步骤

### 实操1：查看系统 kubeconfig
```bash
# 查看当前用户 kubeconfig
kubectl config view
cat ~/.kube/config

# 查看管理员 kubeconfig
kubectl config view --kubeconfig=/etc/kubernetes/admin.conf
```

### 实操2：拆解三大核心结构
#### 1）查看集群 cluster（连接信息）
```bash
kubectl config get-clusters
```
关键字段：
- server：https://192.168.11.161:6443
- certificate-authority-data：集群根证书 base64

#### 2）查看用户 user（认证信息）
```bash
kubectl config get-users
```
关键字段：
- client-certificate-data 客户端证书
- client-key-data 客户端私钥

#### 3）查看上下文 context（生效配置）
```bash
kubectl config get-contexts
kubectl config current-context
```
逻辑：**context = 集群 + 用户 + 默认命名空间**

### 实操3：证书 base64 编解码排障（重点）
#### 解码（查看原始证书）
```bash
echo "CA的base64内容" | base64 -d > ca.crt
echo "client证书base64" | base64 -d > client.crt
echo "client私钥base64" | base64 -d > client.key
```

#### 编码（写入kubeconfig专用）
```bash
cat ca.crt | base64 -w 0
cat client.crt | base64 -w 0
cat client.key | base64 -w 0
```

#### Kubernetes生产中更常用的方法:
```bash
kubectl config view --raw
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > client.crt
kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > client.key
```

### 实操4：手动手写最简合法 kubeconfig（必考）
新建 test-config：
```yaml
apiVersion: v1
kind: Config
current-context: my-admin@k8s
clusters:
- cluster:
    server: https://192.168.11.161:6443
    certificate-authority-data: 替换为你的集群CA base64
  name: k8s-cluster
users:
- user:
    client-certificate-data: 替换你的客户端证书base64
    client-key-data: 替换你的客户端私钥base64
  name: my-admin
contexts:
- context:
    cluster: k8s-cluster
    user: my-admin
    namespace: default
  name: my-admin@k8s
```

加载自定义配置验证：
```bash
export KUBECONFIG=./test-config
kubectl config current-context
kubectl get nodes
```

## 五、实验成功标准
1. 能正常查看 cluster / user / context
2. base64 可正常编解码证书
3. 手写 kubeconfig 可正常连接集群

## 六、高频报错排障
1. **URL错误**：server 必须严格为 `https://192.168.11.161:6443`，不能有换行、空格
2. **证书报错**：必须 `base64 -w 0` 无换行编码
3. **认证失败**：CA、客户端证书必须同一集群签发

需要我继续给你下一节 **02-admin-kubeconfig.md 纯实操问答版** 吗？