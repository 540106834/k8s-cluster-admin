# 06-context-management.md

## 一、文档基础信息

- 所属目录：`05-kubeconfig-management/`
- 前置阅读：01-kubeconfig-overview.md、02-kubeconfig-structure.md
- 集群环境：K8s v1.32.13 单Master，API地址 `https://192.168.11.161:6443`
- 核心作用：管理 kubeconfig 中 `context` 上下文，实现集群/用户/命名空间快速切换；包含创建、查看、切换、重命名、删除、设置默认上下文全套操作

## 二、Context 核心回顾

Context = 绑定一组三元关系：`集群(cluster) + 用户(user) + 默认命名空间(namespace)`
执行kubectl时不指定`--context`，自动使用 `current-context` 定义的默认上下文。

## 三、前置通用查看命令（基础校验）

```bash
# 查看全部上下文列表
kubectl config get-contexts

# 查看当前正在使用的默认上下文
kubectl config current-context

# 完整打印kubeconfig配置
kubectl config view
```

## 四、创建全新上下文

### 4.1 语法说明

```bash
kubectl config set-context 上下文名称 \
  --cluster=集群名称 \
  --user=用户名 \
  --namespace=默认命名空间
```

### 4.2 实操示例（管理员上下文）

```bash
# 基于现有 cluster:kubernetes、user:kubernetes-admin 创建上下文
kubectl config set-context admin@k8s \
--cluster=kubernetes \
--user=kubernetes-admin \
--namespace=default
```

### 4.3 普通只读用户上下文（04-user-kubeconfig 生成的ops-read用户）

```bash
kubectl config set-context ops-read@k8s \
--cluster=kubernetes \
--user=ops-read \
--namespace=default
```

## 五、切换当前生效上下文

```bash
# 切换至管理员上下文
kubectl config use-context admin@k8s

# 切换至只读运维上下文
kubectl config use-context ops-read@k8s

# 校验切换结果
kubectl config current-context
kubectl get nodes
```

## 六、修改已有上下文参数

### 6.1 修改上下文默认命名空间

```bash
# 给 ops-read@k8s 上下文修改默认命名空间为 monitor
kubectl config set-context ops-read@k8s --namespace=monitor
```

### 6.2 替换上下文绑定的集群/用户

```bash
# 仅修改绑定用户
kubectl config set-context admin@k8s --user=kubernetes-admin
# 仅修改绑定集群
kubectl config set-context admin@k8s --cluster=kubernetes
```

## 七、重命名上下文

```bash
# 语法：kubectl config rename-context 旧名称 新名称
kubectl config rename-context admin@k8s master-admin@k8s

# 查看改名后列表
kubectl config get-contexts
```

## 八、删除无用上下文

```bash
# 删除指定上下文
kubectl config delete-context ops-read@k8s

# 批量清空所有上下文（谨慎操作）
kubectl config view -o jsonpath='{.contexts[*].name}' | xargs -n1 kubectl config delete-context
```

## 九、设置永久默认上下文

两种方式等效：

1. 切换命令自动写入current-context（推荐）：`kubectl config use-context admin@k8s`
2. 直接修改顶层current-context字段：`kubectl config set current-context admin@k8s`

## 十、多上下文快速使用技巧

### 1. 临时单次切换上下文（不修改默认配置）

```bash
# 仅本次命令使用只读上下文，不改变全局默认
kubectl get pods --context=ops-read@k8s -A
```

### 2. 临时指定命名空间（不修改上下文配置）

```bash
kubectl get pods --namespace=monitor --context=ops-read@k8s
```

## 十一、完整操作示例流程

```bash
# 1. 查看现有上下文
kubectl config get-contexts

# 2. 创建只读用户上下文
kubectl config set-context ops-read@k8s --cluster=kubernetes --user=ops-read --namespace=default

# 3. 切换至只读上下文
kubectl config use-context ops-read@k8s

# 4. 修改默认命名空间
kubectl config set-context ops-read@k8s --namespace=monitor

# 5. 重命名上下文
kubectl config rename-context ops-read@k8s monitor-read@k8s

# 6. 设为默认上下文
kubectl config use-context monitor-read@k8s

# 7. 临时用管理员上下文执行删除操作
kubectl delete pod test --context=admin@k8s -n default
```

## 十二、常见故障排查

1. `error: context "xxx" does not exist`
   上下文名称输入错误，执行 `kubectl config get-contexts` 核对名称。
2. 切换上下文后无权限访问资源
   该context绑定的User RBAC权限不足，参考04-user-kubeconfig.md补充权限绑定。
3. 切换上下文后仍访问旧集群
   确认执行 `kubectl config use-context` 无报错，或使用 `--context` 临时指定。
4. 上下文绑定集群不存在
   先通过 `kubectl config set-cluster` 创建集群配置，再创建上下文。

## 十三、文档关联

- 前置：02-kubeconfig-structure.md 三层结构context字段解析
- 配套：07-cluster-management.md 集群配置管理、08-user-management.md 用户凭证管理
- 速查：14-kubectl-config-cheatsheet.md 全套config命令汇总
- 故障：15-troubleshooting.md
