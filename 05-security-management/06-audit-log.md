# 06-audit-log.md
## 一、文档基础信息
- 归属目录：`05-security-management/`
- 前置阅读：`00-README.md`、`01-authentication.md`、`02-authorization.md`、`04-secret-management.md`
- 集群基准：Kubernetes v1.32.13、持久化审计存储、日志采集组件、告警平台、内网Harbor
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：kube-apiserver审计日志启动参数、审计策略分级规则、日志持久化存储方案、日志采集与脱敏、高危操作识别、审计告警配置、审计日志检索复盘、审计故障排查

## 二、审计日志底层原理
### 2.1 定位
Audit Log（API审计日志）记录所有访问kube-apiserver的完整请求行为，实现**全操作可追溯、安全事件事后复盘、越权/高危操作实时告警**，是集群安全追溯唯一凭证。
覆盖主体：管理员证书、OIDC员工账号、ServiceAccount、kubelet节点请求。

### 2.2 审计四阶段生命周期
1. RequestReceived：apiserver接收请求，最早记录；
2. ResponseStarted：响应头部下发，长连接/流日志用；
3. ResponseCompleted：响应全部返回，绝大多数场景使用；
4. Panic：服务异常崩溃时兜底记录。

### 2.3 四级审计事件粒度（生产分级落地）
| 级别 | 名称 | 记录范围 | 适用场景 |
|------|------|----------|----------|
| Level 0 | None | 不记录任何审计日志 | DEV本地调试，生产禁用 |
| Level 1 | Metadata | 仅记录请求元数据（用户、资源、动作、时间），不记录请求体 | 常规读操作、无敏感数据接口 |
| Level 2 | Request | 记录元数据+请求体，不记录响应体 | 资源创建/更新、RBAC变更、Secret修改（生产默认标准） |
| Level 3 | RequestResponse | 记录完整请求+响应体，含Secret明文 | 仅故障排查临时开启，日常关闭防止密钥泄露 |

## 三、apiserver 审计完整配置落地
### 3.1 启动关键参数
```
--audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
--audit-log-path=/var/log/k8s/audit/audit.log
--audit-log-maxage=90
--audit-log-maxbackup=30
--audit-log-maxsize=100
--audit-log-format=json
```
参数说明：
- audit-log-maxage：日志文件保留90天（PROD强制）；
- audit-log-maxsize：单文件100M自动切割；
- 日志格式统一JSON，便于日志平台解析检索。

### 3.2 分级审计策略模板（PROD标准 audit-policy.yaml）
```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
# 全局默认级别
omitStages: ["RequestReceived"]
rules:
# 1. 只读查询：仅记录元数据，减少日志量
- level: Metadata
  verbs: ["get","list","watch"]
  resources:
  - group: "*"
    resources: ["*"]

# 2. 高危写操作：记录完整请求体
- level: Request
  verbs: ["create","update","patch","delete"]
  resources:
  - group: ""
    resources: ["secrets","persistentvolumes","persistentvolumeclaims"]
  - group: rbac.authorization.k8s.io
    resources: ["clusterroles","clusterrolebindings","roles","rolebindings"]
  - group: networking.k8s.io
    resources: ["networkpolicies","ingresses"]
  - group: storage.k8s.io
    resources: ["storageclasses","volumesnapshots"]

# 3. 集群控制平面高危操作（全量记录）
- level: Request
  verbs: ["create","update","patch","delete"]
  resources:
  - group: ""
    resources: ["nodes","namespaces"]
  namespaces: ["kube-system"]

# 4. 拒绝所有匿名、401/403越权访问全量记录
- level: Request
  verbs: ["*"]
  users: ["system:anonymous"]

# 5. 兜底规则：其余所有操作Metadata级别
- level: Metadata
  verbs: ["*"]
  resources:
  - group: "*"
    resources: ["*"]
```

## 四、审计日志持久化与采集方案
### 4.1 本地文件切割存储（控制平面节点）
apiserver直接输出至节点本地 `/var/log/k8s/audit/audit.log`，自动按大小/天数切割，保留90天。
### 4.2 日志采集组件（DaemonSet）
使用Filebeat采集节点审计日志，统一推送至内部ELK/日志存储平台：
1. 日志脱敏：自动过滤Secret内明文密钥、数据库密码；
2. 索引按环境区分：fat/uat/prod独立索引；
3. 日志存储周期：PROD日志留存90天，FAT留存7天自动清理。
### 4.3 离线集群存储规范
无外网日志平台：节点本地日志加密打包，定期同步至内网存储PVC归档。

## 五、高危异常操作识别清单（告警触发规则）
### 5.1 高危删除操作（高优先级告警）
1. 删除Namespace、PV/PVC、StatefulSet、MySQL/Redis中间件；
2. 删除所有NetworkPolicy、RBAC权限绑定、准入Webhook；
3. 删除kube-system系统组件资源。

### 5.2 权限变更类告警
1. 新增/修改/删除ClusterRoleBinding、绑定cluster-admin权限；
2. 给ServiceAccount绑定高权限ClusterRole；
3. OIDC用户分组权限变更、新增全局写权限账号。

### 5.3 密钥/凭证变更告警
1. 创建/更新/删除任意Secret、TLS证书Secret；
2. 修改镜像拉取Harbor密钥、数据库账号密码密钥。

### 5.4 违规容器操作告警
1. 创建特权容器、开启hostNetwork/hostPID被准入拦截；
2. 批量创建大量Pod、批量删除业务负载。

### 5.5 越权访问告警
1. 大量403 Forbidden权限拒绝请求（暴力尝试越权）；
2. FAT命名空间账号尝试访问PROD资源。

## 六、审计告警配置规范
1. 告警渠道：企业内部消息、短信分级告警；
2. 分级策略：
   - 一级高危（删除生产PVC/Secret/ClusterRole）：即时短信+消息告警；
   - 二级风险（普通RBAC变更、Ingress修改）：消息平台告警；
   - 三级普通操作（常规发布更新）：仅日志留存，不告警；
3. 告警附带字段：操作人、操作时间、资源名称、命名空间、操作动作、返回状态码。

## 七、DEV/FAT/UAT/PROD 审计差异化基线
### DEV本地
关闭完整审计，仅极简日志输出，不持久化存储，无告警。
### FAT测试
1. 审计策略简化，高危操作仅Metadata级别；
2. 日志留存7天自动清理；
3. 无短信告警，仅日志平台留存。
### UAT预生产
1. 审计规则完全对齐生产分级标准；
2. 日志留存90天；
3. 二级风险消息告警，一级高危短信告警。
### PROD生产（强制约束）
1. 严格启用分级审计策略，高危写操作Request级别；
2. 日志本地切割+ELK持久化双存储，留存90天；
3. 所有一级高危操作实时短信告警；
4. 禁止关闭审计日志，集群升级必须保留审计配置；
5. 每月审计日志复盘，梳理异常越权访问记录；
6. 审计日志禁止随意删除，删除操作双人复核。

## 八、审计日志运维操作
```bash
# 查看apiserver审计日志本地路径
ls /var/log/k8s/audit/

# 实时跟踪审计日志（控制平面节点执行）
tail -f /var/log/k8s/audit/audit.log | jq .

# ELK检索示例：查询删除PVC操作
action:delete AND resource:persistentvolumeclaims AND namespace:prod

# 检索OIDC用户张三所有操作
user:"oidc:user:zhangsan@example.com"

# 检索403越权访问记录
responseStatus.code:403
```

## 九、审计日志常见故障排查
### 1. apiserver无法生成审计日志
audit-policy.yaml格式错误、日志目录权限不足、磁盘满无法写入日志。
### 2. 日志采集平台无审计数据
Filebeat DaemonSet异常、节点目录挂载缺失、日志过滤规则误拦截所有日志。
### 3. 审计日志泄露Secret明文
临时开启Level3 RequestResponse，切回Level2 Request，开启日志脱敏过滤。
### 4. 高危删除操作未触发告警
ELK告警规则未配置对应资源动词（delete）、索引环境标签匹配错误。
### 5. 审计日志只记录少量操作，大量行为缺失
审计策略rule顺序错误，兜底规则覆盖高危资源规则，调整策略顺序。
### 6. 磁盘空间持续打满，审计日志无法自动切割
audit-log-maxsize/maxage参数未配置，重新下发apiserver启动参数并重启控制平面。

## 十、生产安全最佳实践
1. 生产统一使用Level2 Request级别记录高危变更，避免Level3泄露密钥；
2. 审计日志双备份：本地节点切割+集中日志平台持久化；
3. 配置分级告警，高危删除、权限、密钥变更实时通知运维；
4. 开启日志脱敏，过滤Secret密钥明文，防止日志泄露；
5. 每月定期复盘审计日志，清理异常越权账号；
6. 集群升级、apiserver配置变更前备份审计策略文件；
7. 审计日志保留周期严格90天，满足安全合规追溯要求。

## 十一、关联文档
1. 认证授权：`01-authentication.md`/`02-authorization.md` 账号、RBAC变更审计记录
2. 密钥管理：`04-secret-management.md` Secret变更高危审计告警规则
3. 准入控制：`03-admission-control.md` 违规Pod创建拦截操作审计日志
4. 网络安全：`05-network-security.md` NetworkPolicy增删改全量审计
5. 安全加固：`07-security-best-practices.md` 月度审计日志复盘巡检清单
6. 集群部署：kubeadm apiserver审计初始化参数配置文档