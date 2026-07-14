# cluster‑deploy‑docs/kubeconfig.md

## 一、文档基础信息

- 文件路径：`cluster‑deploy‑docs/kubeconfig.md`
- 前置文档：`00‑cluster‑init‑overview.md`、`05‑kubeadm‑init.md`
- 集群版本：Kubernetes‑1.32.13，基于x509证书认证、RBAC鉴权；离线内网环境；
- 文档适用：管理员kubeconfig、普通开发用户、服务账号ServiceAccount‑kubeconfig配置、配置分发、权限收缩、配置过期清理、安全加固、故障排查。
- 文档目标：讲解kubeconfig内部字段含义、3类kubeconfig生成方式、上下文切换、权限最小化、配置文件生命周期、生产安全约束。

## 二、kubeconfig整体介绍

### 2.1 作用

kubeconfig是kubectl、客户端工具连接apiserver（6443）的配置文件，提供：

1. apiserver访问地址；
2. 客户端证书或者token凭证；
3. 集群信息、用户名、命名空间、上下文context；

apiserver基于证书完成认证（Authentication），再通过RBAC做授权（Authorization）。
默认加载优先级：

1. `--kubeconfig` 指定文件 >
2. 环境变量 `KUBECONFIG` >
3. 默认路径 `~/.kube/config`。

### 2.2 kubeconfig配置文件4大核心组成部分（yaml固定结构）

1. **clusters（集群信息）**

    - cluster名称、apiserver的https地址、CA根证书（ca‑cert‑data）；客户端通过CA校验apiserver证书合法性，防止中间人攻击。
2. **users（用户凭证）**：客户端身份凭证，分3种形式：
    - ① client‑certificate‑data + client‑key‑data：基于x509证书（管理员主流方式）；
    - ② token：ServiceAccount对应的JWT令牌；
    - ③ username/password（生产不推荐）。
3. **contexts（上下文）**：将集群、用户、默认命名空间三者绑定。

    ```
    context = cluster + user + namespace
    ```

4. **current‑context：当前生效上下文**，kubectl默认使用该上下文操作集群资源。

示例精简结构：

```yaml
apiVersion: v1
kind: Config
clusters:
- name: k8s-prod
  cluster:
    server: https://10.0.10.10:6443
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
users:
- name: admin
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo=
contexts:
- name: admin@prod
  context:
    cluster: k8s-prod
    user: admin
    namespace: prod
current-context: admin@prod
```

## 三、三类kubeconfig来源（生产区分使用）

### 方式1：管理员kubeconfig（kubeadm自动生成）

1. kubeadm‑init之后自动生成 `/etc/kubernetes/admin.conf`，内置cluster‑admin集群管理员权限；
2. 内部使用集群根CA签发的管理员证书，证书有效期默认10年；
3. 运维管理员复制到自己家目录：

```bash
mkdir -p ~/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config
chmod 600 ~/.kube/config
```

> 安全注意：admin.conf拥有cluster‑admin超级权限，严禁下发给开发人员。

### 方式2：自定义用户kubeconfig（给开发、测试人员使用，生产推荐）

整体流程：生成客户端证书私钥 → 使用集群CA签发证书 → 创建kubeconfig文件 → 绑定RBAC权限。

1. 创建csr证书签名请求；
2. 通过集群根CA签发证书（有效期自定义，比如90天）；
3. 使用`kubectl config set‑cluster / set‑credentials / set‑context`生成独立config；
4. 创建Role和RoleBinding仅分配对应命名空间只读或者有限操作权限。

示例生成命令：

```bash
# 设置集群信息
kubectl config set-cluster k8s-prod \
--server=https://10.0.10.10:6443 \
--certificate-authority=/etc/kubernetes/pki/ca.crt \
--embed-certs=true \
--kubeconfig=dev-user.config

# 设置用户凭证
kubectl config set-credentials dev-user \
--client-certificate=./dev-user.crt \
--client-key=./dev-user.key \
--embed-certs=true \
--kubeconfig=dev-user.config

# 绑定上下文并设置默认namespace
kubectl config set-context dev-user@fat \
--cluster=k8s-prod \
--user=dev-user \
--namespace=fat \
--kubeconfig=dev-user.config

# 设置当前上下文
kubectl config use-context dev-user@fat --kubeconfig=dev-user.config
```

之后给该用户创建RBAC，例如只允许fat命名空间查看Pod、Deployment，禁止删除操作。

### 方式3：ServiceAccount模式kubeconfig（程序调用使用，CI/CD组件使用）

适用场景：ArgoCD、Prometheus、外部自动化程序访问k8s集群。

1. 创建ServiceAccount；
2. 获取对应的secret里面的JWT token；
3. 基于token生成kubeconfig；
4. 通过ClusterRoleBinding或者RoleBinding分配权限；

> ServiceAccount的Token默认永久有效；新版本K8s推荐使用短期令牌（TokenRequest）缩短有效期。

## 四、kubeconfig日常管理常用命令

### 4.1 查看配置

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

### 4.2 配置精简导出（分发最小化kubeconfig）

```bash
# --minify只导出当前上下文配置，去除无关集群和用户；--flatten把证书嵌入yaml内，方便分发
kubectl config view --minify --flatten -o yaml > prod-admin.config
```

### 4.3 删除无用上下文、集群配置

```bash
kubectl config unset contexts.xxx
kubectl config unset users.xxx
kubectl config unset clusters.xxx
```

### 4.4 多集群配置在同一个kubeconfig文件

同一个config里面可以存放dev/fat/uat/prod四个集群信息，通过`kubectl config use‑context`切换集群。

## 五、kubeconfig生命周期管理（生产核心）

### 5.1 证书有效期规则

1. kubeadm生成的管理员证书有效期：10年；
2. 自定义用户证书：由签发时设定，生产统一设置90‑180天到期；到期证书无法连接apiserver；
3. ServiceAccount静态token默认永久有效，安全隐患较高。

### 5.2 生命周期全流程

1. 创建：根据人员或程序需求生成kubeconfig，配置最小权限RBAC；
2. 分发：文件权限必须为`600`，只发给对应使用人；禁止随意转发；
3. 使用期间：定期核查权限，回收离职人员config；
4. 证书到期前：重新签发证书更新kubeconfig；
5. 销毁：人员离职、组件下线后删除证书私钥、删除RBAC绑定、废弃kubeconfig文件。

### 5.3 证书过期处理方案

1. x509证书过期：重新基于集群CA签发新证书；更新客户端kubeconfig；
2. ServiceAccount永久Token：废弃旧Secret，使用TokenRequest申请短期令牌（1h）。

## 六、生产环境安全规范（DEV/FAT/UAT/PROD差异化）

### 6.1 通用强制约束

1. config文件权限严格为`600`，禁止全局可读；
2. admin.conf严禁下发给开发人员；生产运维人员分个人证书，不共用管理员config；
3. 开发用户仅分配对应命名空间权限，禁止cluster‑admin集群级权限；
4. 禁止把kubeconfig硬编码放进容器镜像、Git仓库；
5. 定期审计所有用户证书和ServiceAccount：

    ```bash
    # 查看集群内所有sa对应的secret token
    kubectl get secrets -A | grep -i token
    ```

### 6.2 环境划分标准

1. DEV：开发环境可共用管理员config；证书有效期可以设置较长；
2. FAT测试：开发人员使用独立用户config；仅拥有fat命名空间权限；证书有效期最长180天；
3. UAT预生产：严格区分运维账号和开发账号；运维单独签发个人证书；开发只有只读权限；
4. PROD生产（强制红线）
    1. 禁止多人共用admin.conf；每个运维人员使用独立证书；
    2. 所有自定义用户证书有效期统一设置90天，到期轮换；
    3. Service‑Account优先使用短期TokenRequest，禁用永久静态token；
    4. 人员离职之后立刻吊销证书、删除对应的RoleBinding；
    5. kubeconfig传输通过加密通道；禁止通过微信群、普通聊天工具传输；
    6. 定期导出apiserver审计日志，核查用户操作记录。

## 七、常见故障问题排查

### 问题1：kubeconfig证书过期，报错x509: certificate has expired

解决：重新基于集群CA签发新客户端证书，更新kubeconfig。

### 问题2：kubectl执行返回403 Forbidden

排查步骤：

1. 确认当前使用的用户：`kubectl config view`；
2. 查看该用户绑定哪些权限：`kubectl auth can-i --list --as=dev-user -n fat`；
3. 补充对应的Role或者ClusterRoleBinding授权。

### 问题3：apiserver证书域名不匹配

原因：创建kubeconfig时server地址和证书SAN域名不一致；修改kubeconfig中的server地址或者重新签发apiserver证书。

### 问题4：多kubeconfig文件冲突

优先查看环境变量`echo $KUBECONFIG`，确认当前加载哪一份配置文件。

## 八、最佳实践总结

1. 权限分层：管理员证书、普通用户证书、ServiceAccount令牌三者分开使用；
2. 遵循最小权限：开发人员只限定对应namespace；程序账号只分配必要权限；
3. 缩短证书生命周期：生产用户证书90天过期，定时轮换；
4. 定期审计：清理离职人员废弃kubeconfig和无用ServiceAccount；
5. 外部组件优先使用短期TokenRequest，减少永久token带来的安全风险；
6. 运维操作全部通过独立证书执行，审计日志记录对应操作人员。

## 九、关联文档

1. `05‑kubeadm‑init.md`：集群根CA证书生成；
2. `05‑security‑management`：RBAC权限管理、准入控制；
3. `09‑upgrade.md`：集群升级时证书续签；
4. `10‑troubleshooting.md`：403权限报错、证书过期排障。