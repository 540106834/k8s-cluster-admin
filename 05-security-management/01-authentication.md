# 01-authentication.md
## 一、文档基础信息
- 归属目录：`05-security-management/`
- 前置阅读：`00-README.md`、集群初始化CA证书文档
- 集群基准：Kubernetes v1.32.13、自签集群CA、OIDC身份提供商、离线证书签发工具、内网Harbor
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：K8s API认证完整链路、4种认证方式、kubeconfig规范、ServiceAccount机制、OIDC统一登录、证书生命周期、离线证书签发、证书轮换、认证故障排查

## 二、K8s Authentication 底层核心原理
### 2.1 认证定位
Authentication（身份认证）是集群API第一道防线，**仅校验访问者身份合法性**，不控制资源操作权限（权限由RBAC Authorization管控）。
所有请求到达kube-apiserver必须通过认证，匿名访问默认关闭，未通过认证直接401 Unauthorized拒绝。

### 2.2 apiserver 支持四大认证方式（生产启用优先级）
1. **X509客户端证书（最高信任，运维管理员）**
    集群CA签发客户端证书，内置在kubeconfig，离线可用，PROD核心运维凭证。
2. **ServiceAccount Token（Pod内部访问集群API）**
    每个命名空间自动绑定ServiceAccount，挂载JWT令牌至Pod `/var/run/secrets/kubernetes.io/serviceaccount/`，用于控制器、CronJob、自定义Operator调用API。
3. **OIDC 第三方身份认证（统一员工登录）**
    对接企业LDAP/OIDC服务，员工账号统一登录集群，可配置MFA二次验证，替代长期静态证书。
4. **静态Token/基础认证（生产禁用）**
    明文固定令牌，存在泄露风险，仅DEV临时调试使用，UAT/PROD全局关闭。

### 2.3 认证执行流程
1. 客户端携带凭证（证书/Token/OIDC令牌）请求kube-apiserver；
2. apiserver依次启用各认证器校验凭证合法性；
3. 认证通过：提取用户/组标识，转交RBAC授权模块；
4. 认证失败：直接返回401，拒绝所有操作。

## 三、X509 证书认证 & kubeconfig 标准化规范
### 3.1 kubeconfig 三核心组件
1. `cluster`：集群apiserver地址、集群CA公钥；
2. `user`：客户端证书私钥+证书；
3. `context`：绑定集群+用户+命名空间，切换操作环境。

### 3. 生产标准kubeconfig模板片段
```yaml
apiVersion: v1
kind: Config
clusters:
- name: prod-cluster
  cluster:
    server: https://10.10.0.10:6443
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
contexts:
- name: prod-admin
  context:
    cluster: prod-cluster
    user: prod-admin-user
    namespace: prod
users:
- name: prod-admin-user
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo=
current-context: prod-admin
```

### 3.2 kubeconfig 安全管控约束
1. 权限：本地文件 `chmod 600`，禁止其他用户读取；
2. 分发：PROD管理员kubeconfig禁止明文传输，加密压缩分发；
3. 有效期：客户端证书有效期统一90天，到期前7天轮换；
4. 废弃规则：离职运维人员立即吊销证书、回收kubeconfig。

## 四、ServiceAccount 内置Pod认证机制
### 4.1 核心机制
每个Namespace默认存在`default` SA；不指定SA时Pod自动绑定default SA，自动挂载JWT令牌。
控制器、自定义Operator必须使用独立ServiceAccount，绑定最小权限RBAC，禁止使用default SA高权限访问。

### 4. 标准独立ServiceAccount模板
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backup-operator-sa
  namespace: prod
  labels:
    app: backup
    env: prod
# 自动关联Secret存储JWT令牌
secrets:
- name: backup-operator-sa-token-xxxx
```

### 4. Pod 挂载规则
容器自动挂载路径：
`/var/run/secrets/kubernetes.io/serviceaccount/token`
Pod内调用集群API无需手动配置kubeconfig，客户端自动读取内置令牌完成认证。

### 安全约束
1. 禁止给default SA绑定ClusterAdmin全量权限；
2. 闲置ServiceAccount及时删除，回收令牌；
3. 准入控制限制SA仅能绑定最小权限Role。

## 五、OIDC 第三方统一认证（PROD生产强制落地）
### 5.1 落地价值
1. 统一企业员工账号，不用分发独立客户端证书；
2. 支持账号禁用、密码修改、MFA二次校验；
3. 可关联员工部门、岗位分组，RBAC按组授权；
4. 令牌短期有效，降低长期静态证书泄露风险。

### 5.2 kube-apiserver OIDC 启动参数
```
--oidc-issuer-url=https://oidc.example.com
--oidc-client-id=k8s-prod
--oidc-username-claim=sub
--oidc-groups-claim=groups
--oidc-ca-file=/etc/kubernetes/ssl/oidc-ca.crt
```

### 5.3 用户登录流程
1. 运维通过OIDC页面登录，获取短期ID Token；
2. Token写入本地kubeconfig作为认证凭证；
3. apiserver校验OIDC签名，解析用户/组；
4. RBAC匹配对应权限完成授权。

### 分环境规范
- DEV/FAT：可选OIDC，也可使用客户端证书；
- UAT/PROD：强制OIDC作为员工登录唯一方式，仅集群运维主机使用X509证书。

## 六、集群证书生命周期管理规范
### 6.1 证书分类与有效期标准
| 证书类型 | 有效期 | 轮换周期 | 责任人 |
|---------|--------|----------|--------|
| 集群根CA证书 | 10年 | 每8年提前重新签发 | 集群管理员双人 |
| apiserver/etcd/controller-manager 组件证书 | 1年 | 每11个月轮换 | 集群运维 |
| 管理员客户端证书 | 90天 | 每83天提前轮换 | 对应运维人员 |
| OIDC 对接证书 | 1年 | 每年统一轮换 | 安全运维 |

### 6.2 证书过期风险
证书过期后kube-apiserver拒绝所有证书认证请求，集群完全无法运维，必须提前轮换。

### 6.3 kubeadm 证书轮换操作
```bash
# 查看所有证书过期时间
kubeadm certs check-expiration

# 批量续签所有组件证书
kubeadm certs renew all

# 重新生成管理员kubeconfig
kubeadm kubeconfig user --client-name=admin --org=system:masters > admin-prod.kubeconfig
```

## 七、离线集群证书签发规范（无外网集群）
### 7.1 离线前置条件
1. 集群根CA私钥、证书离线加密存储备份；
2. 离线签发工具打包至内网运维服务器，禁止外网下载工具；
3. 所有签发证书模板纳入Git版本管理，记录签发申请人、有效期、用途。

### 7.2 离线签发客户端证书标准流程
1. 申请人提交工单：用户名、所属组、证书有效期（最长90天）；
2. 管理员使用集群离线CA工具生成CSR、私钥、客户端证书；
3. 加密打包kubeconfig交付申请人，留存签发记录；
4. 到期前7天提醒轮换，过期自动吊销。

### 7.3 离线安全红线
根CA私钥禁止存放在集群节点，离线加密介质单独保管，双人保管密钥。

## 八、DEV/FAT/UAT/PROD 差异化认证基线
### DEV本地
1. 允许静态token、长期客户端证书；
2. 无需OIDC统一登录，简化证书轮换规则；
3. default SA可临时赋予高权限，调试完成清理。

### FAT测试
1. 禁用静态明文token；
2. 客户端证书最长90天，到期轮换；
3. 可选OIDC，不强制；
4. 开发账号仅授权fat命名空间操作。

### UAT预生产
1. 员工登录强制OIDC；
2. 所有客户端证书90天自动轮换；
3. default SA严格限制权限，禁止全量权限；
4. 证书变更双人复核，留存签发记录。

### PROD生产（强约束）
1. 永久关闭静态token、基础认证；
2. 员工运维统一OIDC+MFA；核心运维主机使用短期X509证书；
3. 所有客户端证书有效期90天，到期前7天强制轮换；
4. 根CA私钥离线加密存储，禁止集群节点留存；
5. 独立ServiceAccount绑定所有业务Pod，禁用default SA高权限；
6. 证书签发、吊销、轮换操作全部记录审计日志，高危操作双人复核。

## 九、核心运维操作命令
```bash
# 查看集群证书过期时间
kubeadm certs check-expiration

# 续签集群组件全部证书
kubeadm certs renew all

# 查看当前上下文、认证用户
kubectl config current-context
kubectl config view --minify

# 查看Pod内置ServiceAccount令牌挂载
kubectl exec -it ${pod-name} -n ${ns} -- cat /var/run/secrets/kubernetes.io/serviceaccount/token

# 查看ServiceAccount与绑定密钥
kubectl get sa,secrets -n prod
```

## 十、高频认证故障排查
### 1. kubectl 请求返回 401 Unauthorized
1. 客户端证书过期，执行证书续签；
2. kubeconfig CA证书不匹配集群根CA；
3. OIDC令牌过期，重新登录刷新令牌；
4. ServiceAccount令牌被删除，重建SA自动生成token。

### 2. Pod内调用API 401拒绝
1. ServiceAccount对应的token Secret被删除；
2. Pod未挂载SA令牌，缺少serviceAccountName配置；
3. 令牌过期（集群自动轮换，极少出现，重启Pod恢复）。

### 3. OIDC登录失败，无法获取令牌
1. apiserver OIDC参数配置错误；
2. OIDC服务CA证书失效；
3. 员工账号被LDAP/OIDC禁用。

### 4. 集群节点NotReady，kubelet认证失败
kubelet客户端证书过期，执行kubeadm证书续签并重启kubelet。

### 5. 离线签发证书后认证不通过
签发使用的根CA与集群apiserver CA不一致，重新使用集群标准CA签发。

## 十一、安全最佳实践
1. 生产禁用静态Token、基础认证，仅保留X509证书+OIDC+ServiceAccount三种认证方式；
2. 严格控制客户端证书有效期，杜绝长期永久证书；
3. 业务Pod一律使用独立ServiceAccount，最小权限绑定RBAC；
4. 根CA私钥离线加密备份，禁止线上集群节点存放；
5. OIDC开启MFA二次验证，提升员工登录安全；
6. 离职人员立即吊销证书、回收kubeconfig、禁用OIDC账号；
7. 证书轮换、签发操作留存工单与审计日志，可追溯。

## 十二、关联文档
1. 权限授权：`02-authorization.md` 认证用户/组对应RBAC权限绑定
2. 准入控制：`03-admission-control.md` ServiceAccount权限准入校验
3. 审计日志：`06-audit-log.md` 证书签发、OIDC登录、API调用全量审计
4. 集群初始化：集群kubeadm部署文档 CA证书初始化参数
5. 集群升级：`cluster-upgrade-theory-guide.md` 升级后证书兼容续签操作
6. 密钥管理：`04-secret-management.md` ServiceAccount Token Secret管控规范