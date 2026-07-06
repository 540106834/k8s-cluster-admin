# kubeconfig（kubectl config） 全量核心命令手册

**基础概念**：kubectl config 命令集用于管理 Kubernetes 集群认证配置文件 kubeconfig，核心管控三类资源：集群信息、用户凭证、上下文；本质是对 kubeconfig 配置文件实现 CRUD 操作+集群上下文快速切换。  
**默认配置路径**：`~/.kube/config`  
**核心记忆模型**：

1. **clusters**：定义集群 API 地址（连接哪里）
2. **users**：定义用户/认证凭证（你是谁）
3. **contexts**：绑定集群+用户（身份+集群绑定）

按运维场景分为：**查看、切换、编辑/增删、合并、调试/排错** 五大类整理，标注⭐高频常用命令

---

## 一、查看类（日常最高频）

### 1.1 查看当前生效 kubeconfig 配置

```bash
# ⭐ 查看当前合并后生效配置，隐藏敏感原始字段
kubectl config view
```

### 1.2 查看完整原始 kubeconfig（含明文证书/Token）

```bash
# 查看原始完整配置，不脱敏、展示全部合并来源数据
kubectl config view --raw
```

### 1.3 查看当前正在使用的上下文

```bash
# ⭐ 快速确认当前连接哪个集群、哪个用户身份
kubectl config current-context
```

### 1.4 列出全部已配置上下文

```bash
# 展示所有上下文、绑定集群、绑定用户
kubectl config get-contexts
```

**标准输出示例**：

```text
CURRENT   NAME            CLUSTER        AUTHINFO
*         admin-context   k8s-cluster    admin-user
          read-context    k8s-cluster    read-user
```

---

## 二、切换类（集群环境切换核心）

### 2.1 永久切换默认上下文（修改本地配置文件）

```bash
# ⭐ 切换默认集群环境，后续所有kubectl命令默认使用该上下文
kubectl config use-context read-context
```

### 2.2 临时指定上下文（不修改本地配置，会话级生效）

```bash
# 仅当前这条命令使用目标上下文，不改变全局默认配置
kubectl --context=read-context get pods
```

---

## 三、编辑/增删类（集群、用户、上下文配置管理）

用于新增、修改、删除集群接入信息、用户凭证、上下文绑定关系

### 3.1 添加/修改集群接入配置

适配 URL：`https://1.2.3.4:6443` 集群地址，跳过 TLS 证书校验

```bash
kubectl config set-cluster k8s-cluster 
  --server=https://1.2.3.4:6443 
  --insecure-skip-tls-verify=true
```

### 3.2 添加/修改用户 Token 凭证

```bash
# 配置集群只读用户Token凭证
kubectl config set-credentials read-user 
  --token=xxxxx
```

### 3.3 创建/修改上下文（绑定集群+用户）

```bash
# 将k8s-cluster集群 和 read-user用户 绑定为新上下文
kubectl config set-context read-context 
  --cluster=k8s-cluster 
  --user=read-user
```

### 3.4 快捷修改默认上下文

```bash
kubectl config set current-context read-context
```

### 3.5 删除配置资源

```bash
# 删除指定上下文
kubectl config delete-context read-context

# 删除指定用户凭证
kubectl config delete-user read-user

# 删除指定集群配置
kubectl config delete-cluster k8s-cluster
```

---

## 四、合并 kubeconfig（多集群运维必备⭐）

多套k8s集群、多份kubeconfig文件合并，是集群运维高频场景

### 4.1 合并多份配置并扁平化输出

```bash
# 合并默认配置+自定义用户配置，扁平化去重输出新配置文件
KUBECONFIG=~/.kube/config:read-user-kubeconfig kubectl config view --merge --flatten > merged.yaml
```

### 4.2 临时加载多份kubeconfig文件

```bash
# 环境变量声明多配置文件，逗号/冒号分隔，会话级生效
export KUBECONFIG=file1:file2:file3
```

---

## 五、调试与权限排错类（故障排查核心）

### 5.1 查看当前生效的kubeconfig文件路径

```bash
# 排查kubectl到底加载了哪一份配置文件
echo $KUBECONFIG
```

### 5.2 权限校验（最关键排错命令⭐）

```bash
# 校验当前账号是否拥有查询Pod权限
kubectl auth can-i get pods

# 模拟指定服务账号，校验操作权限
kubectl auth can-i get pods --as=system:serviceaccount:kube-system:read-user
```

### 5.3 高级诊断：查看API全量请求链路

```bash
# 高 verbose 日志，输出原始Token、请求地址、API交互报文
kubectl get pods -v=9
```

---

## 六、核心总结&底层逻辑

- **命令本质**：`kubectl config` 所有命令，都是对 kubeconfig 配置文件的增删改查 + 全局上下文切换
- **加载优先级**：环境变量$KUBECONFIG > 默认路径~/.kube/config > 集群内置serviceaccount配置
- **排错优先级**：先查上下文 → 查配置文件路径 → 权限校验 → API请求日志

**后续拓展**：需要我补充 **kubeconfig→kubectl→APIServer 完整调用链路+RBAC认证流程** 图文流程图吗？

