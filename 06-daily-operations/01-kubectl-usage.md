# 01-kubectl-usage.md
## 一、文档基础信息
- 归属目录：`06-daily-operations-management/`
- 前置阅读：`00-README.md`、`05-security-management/01-authentication.md`
- 集群基准：Kubernetes v1.32.13、多集群管理、OIDC认证、离线内网环境、kubeconfig加密分发
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：kubectl 多系统安装、kubeconfig文件规范、多集群上下文切换、常用别名配置、`kubectl auth can-i`权限预校验、离线集群操作方案、安全使用约束、故障排查

## 二、kubectl 基础概述
kubectl 是K8s集群唯一标准客户端工具，所有集群API操作入口；
所有请求遵循认证→授权→准入控制链路，操作行为全部记入apiserver审计日志。
生产环境禁止直接操作控制平面节点kubectl，统一本地客户端远程访问集群API。

## 三、多系统客户端离线安装规范
### 3.1 Linux 离线安装（内网服务器）
1. 内网运维节点提前下载对应集群版本二进制包，避免外网下载；
2. 解压并赋予执行权限：
```bash
mv kubectl /usr/local/bin/
chmod +x /usr/local/bin/kubectl
kubectl version --client
```
### 3.2 Windows/Mac 本地运维主机
1. 内网文件服务器分发kubectl二进制；
2. 配置环境变量PATH，终端可直接调用；
### 版本匹配强制规则
客户端kubectl版本与集群apiserver版本偏差不超过1个minor版本，例如集群v1.32，客户端允许v1.31~v1.33。

## 四、kubeconfig 标准化管控规范
### 4.1 kubeconfig 默认加载优先级
1. `--kubeconfig` 手动指定文件参数；
2. `KUBECONFIG` 环境变量；
3. 默认路径 `~/.kube/config`。

### 4.2 多集群合并kubeconfig（FAT/UAT/PROD共存）
```bash
# 合并多集群配置
KUBECONFIG=prod.kubeconfig:uat.kubeconfig:fat.kubeconfig kubectl config view --flatten > ~/.kube/config
chmod 600 ~/.kube/config
```
### 4.3 文件安全权限（全局强制）
```bash
# 仅所有者可读可写，禁止其他用户访问
chmod 600 ~/.kube/config
```
### 4.4 kubeconfig 分发安全约束
1. PROD管理员kubeconfig加密压缩分发，禁止明文微信/钉钉传输；
2. 员工OIDC登录优先使用短期token kubeconfig，长期证书仅运维主机留存；
3. 人员离职立即回收kubeconfig、吊销客户端证书。

## 五、上下文切换核心操作（多环境快速切换）
```bash
# 查看所有上下文
kubectl config get-contexts

# 切换目标环境
kubectl config use-context prod-admin

# 查看当前生效上下文
kubectl config current-context

# 设置默认命名空间，无需每次加 -n
kubectl config set-context --current --namespace=prod
```
### 环境上下文命名规范
`{环境}-{账号用途}` 示例：prod-admin、uat-develop、fat-dev

## 六、全局bash/zsh别名（运维统一标配）
写入`~/.bashrc`或`~/.zshrc`，简化日常操作：
```bash
# 基础简写
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias ke='kubectl exec -it'
alias kl='kubectl logs -f'
# 环境快速切换
alias k-prod='kubectl config use-context prod-admin'
alias k-uat='kubectl config use-context uat-user'
alias k-fat='kubectl config use-context fat-dev'
# 权限预校验简写
alias k-auth='kubectl auth can-i'
# 批量导出资源
alias k-backup='kubectl get pv,pvc,deploy,sts,svc,ingress,networkpolicy -o yaml > backup-$(date +%Y%m%d).yaml'
```
生效命令：
```bash
source ~/.bashrc
```

## 七、权限预校验工具 kubectl auth can-i（生产操作前置必执行）
### 7.1 基础语法
```bash
# 校验当前账号是否可删除mysql statefulset
kubectl auth can-i delete statefulset mysql -n prod

# 模拟指定OIDC用户校验权限
kubectl auth can-i create pvc -n prod --as=oidc:user:zhangsan@example.com

# 批量查看账号全部权限（输出所有允许操作）
kubectl auth can-i --list
```
### 使用规范
PROD高危删除、存储变更、RBAC修改操作前，必须先执行`auth can-i`校验权限，确认操作范围，避免越权误操作。

## 八、离线集群kubectl使用规范
### 8.1 离线前置条件
1. 集群API内网可访问，无外网依赖；
2. kubeconfig内置内网apiserver地址、内网CA证书；
3. 本地镜像、工具全部内网分发，不依赖外网仓库。
### 8.2 纯离线无外网操作限制
1. 禁止拉取公网镜像，仅使用内网Harbor；
2. 无外网无法自动补全，本地预安装kubectl补全脚本；
3. 证书、kubeconfig离线加密备份，不依赖外网签发工具。
### 8.3 kubectl 自动补全离线部署
```bash
# bash补全
kubectl completion bash > /etc/bash_completion.d/kubectl
source /etc/bash_completion.d/kubectl
```

## 九、kubectl 安全使用强制约束
1. 禁止长期使用`cluster-admin`万能上下文，仅故障应急临时切换，操作完成立即切回普通运维上下文；
2. 不使用`--token`、静态明文token长期登录，优先X509短期证书/OIDC短期令牌；
3. 禁止将kubeconfig存放代码仓库、Git、公共服务器；
4. 执行delete操作增加`--dry-run=client`预校验资源，确认无误再真实删除；
```bash
# 预执行删除，仅输出变更不实际操作
kubectl delete pvc test-pvc -n prod --dry-run=client
```
5. 禁止使用`--force --grace-period=0`强制杀死有状态中间件Pod；
6. 多人共用运维主机时，操作完成切换至低权限上下文，避免多人共用高权限凭证。

## 十、DEV/FAT/UAT/PROD 差异化使用基线
### DEV本地
1. 简化权限，默认admin上下文，无严格权限校验；
2. kubeconfig无加密分发要求，本地自用即可。
### FAT测试
1. 开发上下文仅允许fat命名空间读写；
2. 可自由切换上下文，无需审批；
3. 每日清理临时调试kubeconfig文件。
### UAT预生产
1. 上下文按岗位拆分：测试只读、发布运维读写；
2. 高危删除操作必须先执行auth can-i校验；
3. kubeconfig统一chmod 600权限。
### PROD生产（强制红线）
1. 分岗位独立上下文，无全局长期cluster-admin；
2. 所有高危操作执行前`auth can-i`预校验，配合工单双人复核；
3. kubeconfig加密存储、定期轮换客户端证书；
4. 操作避开业务高峰，删除资源必须dry-run预校验；
5. 禁止共享kubeconfig，离职人员立即回收凭证。

## 十一、高频运维命令汇总
```bash
# 切换上下文
kubectl config use-context prod-admin

# 查看当前账号所有权限
kubectl auth can-i --list -n prod

# dry-run模拟删除资源
kubectl delete sts mysql -n prod --dry-run=client

# 导出当前上下文最小化kubeconfig（分发用）
kubectl config view --minify --flatten > prod-user.kubeconfig

# 查看集群客户端认证信息
kubectl config view
```

## 十二、常见kubectl故障排查
### 1. kubectl get pods 返回 401 Unauthorized
kubeconfig客户端证书过期，重新签发证书更新配置；OIDC令牌过期重新登录刷新。
### 2. 请求返回403 Forbidden
账号缺少对应资源操作权限，使用`kubectl auth can-i`确认缺失动词，调整RBAC。
### 3. context切换失败，提示context不存在
上下文名称拼写错误，使用`kubectl config get-contexts`查看完整列表。
### 4. kubeconfig权限过宽告警
文件权限非600，执行`chmod 600 ~/.kube/config`修复。
### 5. 离线环境kubectl无法连接apiserver
kubeconfig server地址为公网地址，修改为内网API地址；网络策略拦截本地访问6443端口。
### 6. 补全命令无效果
未安装bash/zsh补全脚本，重新导入completion配置。

## 十三、最佳实践
1. 统一配置kubectl别名简化日常操作，降低输入错误；
2. 多环境严格区分上下文，操作前确认当前环境，防止误操作生产；
3. 生产删除、变更操作必用dry-run预校验，auth can-i校验权限；
4. kubeconfig严格600权限，加密分发，杜绝泄露；
5. 业务Pod、中间件操作使用对应岗位最小权限上下文，不滥用admin；
6. 定期清理过期上下文、废弃kubeconfig文件，减少安全暴露面。

## 十四、关联文档
1. 身份认证：`05-security-management/01-authentication.md` kubeconfig证书、OIDC令牌生成规范
2. RBAC授权：`05-security-management/02-authorization.md` 账号权限与auth can-i校验逻辑
3. 日常运维总览：`06-daily-operations/00-README.md` 运维操作分层规范
4. 工作负载操作：`06-daily-operations/03-workload-operations.md` 发布、扩缩容前置权限校验流程
5. 安全审计：`05-security-management/06-audit-log.md` kubectl全量操作审计记录规则