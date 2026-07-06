# 02-kubeconfig-structure.md

## 一、文档基础信息

- 所属目录：`05-kubeconfig-management/`
- 前置阅读：`01-kubeconfig-overview.md`
- 集群环境：Kubernetes v1.32.13 单Master，API地址 `https://192.168.11.161:6443`
- 核心目标：拆解kubeconfig三层标准YAML结构，逐条解释字段含义，结合集群实际配置示例

## 二、kubeconfig 顶层三级核心结构

完整文件固定三大顶层数组，**彼此独立，通过 context 关联绑定**：

1. `clusters[]`：集群信息（API地址、CA根证书）
2. `users[]`：用户身份凭证（客户端证书/私钥/Token）
3. `contexts[]`：关联「集群+用户+默认命名空间」的访问上下文

顶层额外配置：

- `current-context`：默认生效上下文名称
- `apiVersion` / `kind`：固定标识，不可修改

## 三、完整标准示例（本集群 admin.conf 模板）

```yaml
apiVersion: v1
kind: Config
# 当前默认使用的上下文
current-context: kubernetes-admin@kubernetes

# 1. 集群列表：存放所有接入的K8s集群信息
clusters:
- name: kubernetes
  cluster:
    # API Server HTTPS地址
    server: https://192.168.11.161:6443
    # 集群CA根证书，校验apiserver合法性（二选一）
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUR...
    # 本地文件路径写法（不推荐分发，优先data base64）
    # certificate-authority: /etc/kubernetes/pki/ca.crt

# 2. 用户列表：存放所有访问身份凭证
users:
- name: kubernetes-admin
  user:
    # 客户端证书+私钥（证书认证模式）
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUR...
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb3dJQkFq...
    # Token认证模式（ServiceAccount专用，与证书互斥）
    # token: eyJhbGciOiJSUzI1NiIsImtpZCI6Ii14N2xxxxxxxxxxxx

# 3. 上下文列表：绑定集群、用户、默认命名空间
contexts:
- name: kubernetes-admin@kubernetes
  context:
    # 关联上方 clusters.name
    cluster: kubernetes
    # 关联上方 users.name
    user: kubernetes-admin
    # 可选：默认操作命名空间，不填为 default
    namespace: default
```

## 四、分模块字段详解

### 4.1 顶层固定字段

```yaml
apiVersion: v1
kind: Config
current-context: xxx
```

- `apiVersion`：kubeconfig资源固定为 `v1`，不可修改
- `kind`：固定 `Config`，标识文件类型为kubeconfig
- `current-context`：指定默认使用的上下文名称，kubectl不加`--context`时自动使用

### 4.2 clusters 集群配置段

```yaml
clusters:
- name: 集群别名
  cluster:
    server: https://API_IP:6443
    certificate-authority-data: base64编码CA证书
    # insecure-skip-tls-verify: true 跳过证书校验（内网测试临时用，生产禁用）
```

- `name`：集群自定义名称，上下文通过该名称关联
- `server`：控制平面API Server HTTPS地址，本集群固定 `https://192.168.11.161:6443`
- `certificate-authority-data`：CA证书base64字符串，分发kubeconfig首选，无需附带证书文件
- `certificate-authority`：CA证书本地文件路径，仅本地机器使用，分发失效
- `insecure-skip-tls-verify`：跳过服务端证书校验，**生产环境禁止开启**

### 4.3 users 用户凭证段

两种认证模式互斥，不能同时填写证书与token

#### 模式1：客户端证书认证（管理员/自定义用户）

```yaml
users:
- name: 用户别名
  user:
    client-certificate-data: base64客户端证书
    client-key-data: base64私钥
```

- `client-certificate-data`：用户证书base64编码
- `client-key-data`：用户私钥base64编码
- 配套文件写法：`client-certificate` / `client-key` 本地文件路径

#### 模式2：Token认证（ServiceAccount专用）

```yaml
users:
- name: sa-user
  user:
    token: 加密字符串token
```

- token由K8s自动签发，无证书，适合程序自动化调用

### 4.4 contexts 上下文关联段

```yaml
contexts:
- name: 上下文别名（规范：用户@集群）
  context:
    cluster: 对应clusters.name
    user: 对应users.name
    namespace: 可选默认命名空间
```

- `name`：上下文名称，推荐规范 `用户名@集群名`，便于区分多集群
- `cluster`：绑定上方集群的name字段，建立关联
- `user`：绑定上方用户的name字段，建立关联
- `namespace`：执行kubectl命令默认命名空间，省略则默认`default`

## 五、两种存储格式对比

1. **-data 字段（推荐分发）**
   `certificate-authority-data` / `client-certificate-data` / `client-key-data`
   证书内容base64嵌入文件，**单文件即可分发**，无需额外拷贝证书文件，标准运维分发方案。
2. 本地文件路径（仅单机本地）
   `certificate-authority` / `client-certificate` / `client-key`
   填写服务器本地证书绝对路径，换机器后路径失效，不适合导出分发。

## 六、结构关联逻辑（核心理解点）

1. `clusters` 存集群地址与可信根证书
2. `users` 存所有人的访问凭证
3. `context` 是桥梁：把「哪个集群」+「哪个用户」绑定在一起
4. `current-context` 定义kubectl默认使用哪一组绑定关系

示例逻辑：
`current-context: kubernetes-admin@kubernetes`
→ 找到contexts中同名上下文
→ context内 `cluster: kubernetes` 匹配clusters集群地址
→ context内 `user: kubernetes-admin` 匹配管理员证书凭证

## 七、查看本机kubeconfig结构命令

```bash
# 完整打印配置（base64证书不会解码）
kubectl config view

# 解码证书内容查看明文
kubectl config view --raw
```

## 八、与其他文档关联

1. 前置：`01-kubeconfig-overview.md` 基础概念
2. 实操落地：`03-admin-conf.md` 解析集群自带admin.conf真实结构
3. 后续：04/05 分别生成证书用户、SA Token用户kubeconfig
4. 操作命令：`14-kubectl-config-cheatsheet.md` 通过命令增删改三层结构