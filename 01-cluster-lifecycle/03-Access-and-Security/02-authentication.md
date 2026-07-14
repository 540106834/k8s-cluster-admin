# cluster‑deploy‑docs/authentication.md
## 一、文档基础信息
- 文件路径：`cluster‑deploy‑docs/authentication.md`
- 前置文档：`00‑cluster‑init‑overview.md`、`kubeconfig.md`，后续衔接rbac‑authorization.md
- 集群版本：Kubernetes‑1.32.13，apiserver支持多种认证插件，顺序串行执行；仅认证通过后才进入RBAC授权阶段。
- 文档范围：讲解K8s apiserver身份认证（Authentication）三种主流方式：**X509客户端证书、ServiceAccount Token、静态Token，同时区分弃用方案；梳理底层原理、适用场景、优缺点、配置方式、安全风险以及生产落地规范**。
> 整体流程：认证（你是谁）→ 授权（你能干什么‑RBAC）→ 准入控制（Admission‑Webhook）。  
> Admission Webhook 是 Kubernetes API 请求的“中间审核/修改层”。它允许企业在资源进入集群之前自动注入配置、执行策略检查，实现 Kubernetes 平台治理自动化。

## 二、apiserver认证整体运行机制
1. kube‑apiserver启动参数 `--authentication‑mode` 指定启用的认证插件；插件串行依次尝试认证，只要任意一个认证成功就判定身份有效。
   生产启用：`x509,ServiceAccount`，废弃：Static‑Token、Basic‑Auth。
2. 识别出用户标识：
   - 普通用户：用户名格式为 `kubernetes‑admin、dev‑user`；
   - ServiceAccount用户：格式为 `system:serviceaccount:<namespace>:<sa‑name>`；
   - 系统内置组件用户：`system:nodes、system:scheduler、system:controller‑manager`。
3. 认证通过之后将用户名、用户组交给RBAC授权模块做权限判定。
4. 配套证书体系：
    - `/etc/kubernetes/pki/ca.crt`：集群根CA，签发apiserver证书、kubelet证书、自定义用户证书；所有X509客户端证书都由该CA签发才会被apiserver信任。

### apiserver内置用户组（重要）
1. `system:masters`：超级管理员组，拥有cluster‑admin权限；只要用户归属该组，不受RBAC限制；
2. `system:nodes`：kubelet内置用户组；Node‑Controller相关权限；
3. `system:serviceaccounts`：所有ServiceAccount归属这个用户组。

## 三、方式1：X509 Certificate 证书认证（运维人员首选）
### 3.1 原理
1. 客户端（kubectl）在https握手阶段提交客户端证书（client.crt + client.key）；
2. apiserver使用集群根CA(ca.crt)校验证书签名是否合法；
3. 从证书的CN字段读取用户名，O字段读取归属组；
    - `CN:admin` 用户名；
    - `O:system:masters` 用户组；
4. 证书过期、CA不匹配、签名篡改直接返回401 Unauthorized。

### 3.2 两种证书来源
1. kubeadm自动生成证书：
    - admin.conf中的管理员证书：`CN=kubernetes‑admin,O=system:masters`，默认有效期10年；
    - kube‑scheduler、kube‑controller‑manager、kubelet证书，同样由集群CA签发。
2. 运维自行签发自定义用户证书（给开发人员）：
    1. 生成私钥与CSR证书请求文件；
    2. 使用集群根CA签发证书，自定义有效期（生产设置90天）；
    3. 将crt、key嵌入kubeconfig；
    4. 再通过RBAC分配对应namespace权限，禁止加入`system:masters`组。

### 3.3 优缺点
- 优点：
  1. 安全性高，私钥不在集群内部保存；只有拿到私钥才可以访问集群；
  2. 证书有效期可控，可以定时轮换证书；
  3. 支持划分用户组，方便批量授权；
- 缺点：
  1. 证书分发比较繁琐；
  2. 证书到期之后客户端直接401，必须重新签发。

### 适用场景
- 运维人员通过kubectl操作集群，生产环境推荐的认证方式。

## 四、方式2：ServiceAccount（SA）Token认证（程序访问集群首选）
### 4.1 底层原理
1. 创建ServiceAccount资源，K8s自动生成对应的Secret；Secret内部保存JWT格式token；
2. JWT分为两版：
   - 旧版：静态持久Token，永久有效，存储在Secret中；安全缺陷明显；
   - 新版：TokenRequest短期令牌（kubernetes1.21+推荐），默认有效期1小时，apiserver动态颁发，不持久化保存。
3. Pod内部自动挂载token：`/var/run/secrets/kubernetes.io/serviceaccount/token`；容器内部程序读取token访问apiserver；
4. apiserver验证JWT签名（使用apiserver私钥签名）解析出SA用户名：`system:serviceaccount:namespace:sa‑name`；
5. 再由RBAC授予对应权限。

### 4.2 使用场景
1. Pod内部程序访问k8s API；
2. 外部组件：Prometheus、ArgoCD、GitOps工具、自动化脚本访问集群；
3. CI流水线调用kubernetes api。

### 4.3 优缺点
- 优点：
    1. Pod内部无需手动配置kubeconfig，自动注入token；
    2. TokenRequest模式可以设置短期有效期，降低泄露风险；
    3. 通过RBAC精细控制程序权限；
- 缺点：
    - 传统Secret‑Token永久有效，如果token泄露攻击者长期可用。

### 4.4 生产最佳实践
1. 集群内部Pod：直接使用自动挂载Token；
2. 外部程序：优先使用 `TokenRequest`，创建短期token，禁止使用静态secret‑token；
3. 遵循最小权限原则，只分配程序必需权限，不要授予cluster‑admin；
4. 不用的ServiceAccount及时删除。

示例：手动基于SA生成短期kubeconfig配置文件，供外部程序使用。

## 五、方式3：静态Token & Basic‑Auth（废弃，生产禁用）
### 5.1 Static‑Token（静态token文件认证）
1. apiserver启动时指定`--token‑auth‑file=xxx.csv`；文件格式：`token,user,groups`；
2. 客户端请求在HTTP Header携带 `Authorization: Bearer <token>`；apiserver匹配文件识别用户。
缺点：
1. Token永久生效；token一旦泄露无法撤销，只能重启apiserver；
2. 修改用户必须修改文件并且重启apiserver；生产环境强烈禁用。

### 5.2 Basic‑Auth（用户名密码认证）
apiserver加载密码文件，客户端使用账号密码认证，同样重启apiserver才会生效，官方废弃，禁止开启。

> 总结：生产环境只启用 `x509 + ServiceAccount`，关闭Static‑Token、Basic‑Auth。

## 六、kubelet专用认证机制
1. kubelet访问apiserver：kubelet证书，由集群CA签发；
2. apiserver访问kubelet（10250端口）：开启kubelet‑webhook鉴权；apiserver通过Node鉴权模式访问kubelet。
3. Node鉴权：apiserver访问kubelet时，apiserver使用自己的证书，apiserver把请求用户名标记为 `system:nodes:<node‑name>`，kubelet再校验权限。

## 七、DEV/FAT/UAT/PROD环境差异化标准
1. DEV环境：
    - 可以共用admin证书；临时静态token可以短期使用；证书有效期可以设置较长；
2. FAT测试环境：
    - 运维人员使用独立x509证书；开发人员证书有效期最长180天；SA尽量使用短期TokenRequest；
3. UAT预生产环境：
    - 严格禁用静态token；所有开发人员禁止加入`system:masters`组；
    - 外部组件全部使用短期TokenRequest；
4. PROD生产环境强制约束：
    1. 关闭Static‑Token、Basic‑Auth；仅启用x509和ServiceAccount；
    2. 运维人员每人独立x509证书，有效期固定90天，到期轮换；禁止共用admin.conf；
    3. 所有ServiceAccount优先启用TokenRequest模式，禁用永久Secret‑Token；
    4. 任何人禁止分配`system:masters`超级管理员组；
    5. 定期扫描集群无用ServiceAccount和废弃token；apiserver开启审计日志记录所有访问行为；
    6. 证书文件、token禁止提交Git仓库、镜像内部。

## 八、高频问题排查
### 问题1：kubectl执行报错401 Unauthorized
排查步骤：
1. x509场景：证书过期、CA证书不匹配、私钥错误；重新签发证书；
2. SA‑Token场景：token损坏或者过期（短期token到期），重新生成token；

### 问题2：Pod内部访问apiserver报403 Forbidden
401是认证失败，403是认证成功但是RBAC权限不足；给对应的ServiceAccount绑定RoleBinding。

### 问题3：apiserver日志频繁出现匿名用户访问
匿名用户：未携带证书或者token，apiserver识别为`system:anonymous`；生产环境禁止给匿名用户授权。

## 九、三种认证选型总结
| 认证方式 | 使用者 | 凭证 | 有效期 | 生产是否推荐 |
|----------|--------|------|--------|--------------|
| X509证书 | 运维人员 | crt/key文件 | 自定义（90天‑10年） | ✔ 推荐 |
| ServiceAccount Token | 程序、Pod、自动化组件 | JWT令牌 | Token‑Request短期1h；旧版永久 | ✔ 优先Token‑Request |
| Static‑Token/Basic‑Auth | 历史遗留 | 固定字符串 | 永久有效 | ❌ 禁用 |

## 十、关联文档
1. `kubeconfig.md`：证书配置进kubeconfig实操；
2. `rbac‑authorization.md`：认证之后RBAC授权配置；
3. `05‑kubeadm‑init.md`：集群CA证书生成；
4. `10‑troubleshooting.md`：401、403故障排查。