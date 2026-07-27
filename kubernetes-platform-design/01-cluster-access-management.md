# kubernetes-platform-design/01-cluster-access-management.md
## 文档元信息
- 模块：集群访问管理
- 优先级：★★★★★ 核心安全底座模块
- 依赖文档：00-platform-overview.md（顶层分层、最小权限原则）
- 关联模块：02-namespace-resource-governance、15-compliance-audit、14-platform-engineering
- 适用角色：平台架构师、安全负责人、集群运维、IDP开发、权限审计人员

## 1. 模块定位与核心目标
### 1.1 定位
集群访问是所有K8s操作的第一道安全入口，统一管控**身份认证（谁能进集群）** + **权限授权（能做什么）**，贯穿人机、自动化流水线、第三方组件全访问场景，是多租户隔离、合规审计的基础依赖。
归属平台三层「集群资源管控域-访问权限域」，所有上层应用、平台组件的访问权限均由本模块统一收敛。

### 1.2 核心目标
1. 统一身份入口，杜绝多套账号体系；支持员工、机器人、第三方组件三类主体身份
2. 严格遵循最小权限原则，禁止全局无限制权限下发
3. 证书、token自动轮换，消除静态长期密钥安全风险
4. 全访问行为可审计溯源，满足等保、企业合规日志留存要求
5. 支持多集群统一身份互通，一套账号管理全部集群

### 1.3 解决业务痛点
- 研发人员直接使用`cluster-admin`高权限账号，误操作破坏集群
- 流水线、监控组件使用永久静态ServiceAccount Token，泄露后无法快速回收
- 多集群独立证书、独立kubeconfig，运维管理成本极高
- 无统一身份源，人员离职/调岗权限无法自动回收，存在权限残留风险
- 缺少细粒度命名空间权限，业务团队可跨Namespace删除其他业务资源

## 2. 集群访问全链路架构
### 2.1 访问主体分类
1. **人工用户**：研发、测试、运维、管理员（基于企业LDAP/OIDC身份）
2. **机器人账号**：CI/CD流水线、ArgoCD、Harbor拉取镜像、自动化脚本（专用ServiceAccount）
3. **集群内置组件**：kube-controller-manager、metrics-server、CSI驱动、Ingress控制器（内置SA+集群内RBAC）

### 2.2 访问链路分层
```
用户/机器人 → OIDC身份提供商/ServiceAccount → kube-apiserver认证层 → RBAC授权校验 → 集群资源操作 → 审计日志落盘
```
1. 认证层：校验访问者身份合法性（Authentication）
2. 授权层：校验该身份是否具备操作资源权限（Authorization/RBAC）
3. 准入层：全局Admission补充权限拦截（关联10-workload-security）
4. 审计层：记录全部访问、变更行为（关联15-compliance-audit）

## 3. Authentication 身份认证体系（四大认证方式统一管控）
### 3.1 OIDC 单点登录（人工用户主认证方案）
#### 架构选型
企业统一身份源（Keycloak/自建OIDC/企业IAM）对接kube-apiserver OIDC插件，统一员工账号，支持MFA多因素认证。
#### 核心配置规范
1. kube-apiserver 启动参数全局统一配置，所有集群共用一套OIDC Issuer
```yaml
--oidc-issuer-url=https://iam.company.com/realms/platform
--oidc-client-id=k8s-client
--oidc-username-claim=email
--oidc-groups-claim=groups
```
2. 身份分组映射规范：
   - `group:platform-admin`：集群全局管理员
   - `group:team-{业务线}`：业务团队研发人员
   - `group:platform-readonly`：只读审计人员
3. 客户端工具：平台自助门户下发标准化kubeconfig，自动刷新OIDC ID Token，有效期2h，无长期静态凭证。
#### 优势
- 人员离职、调岗自动回收集群访问权限；
- 支持MFA，防止账号泄露单点突破集群；
- 多集群复用同一套身份体系。

### 3.2 ServiceAccount（机器人/组件认证标准方案）
#### 使用约束
1. 禁止使用`default` ServiceAccount，所有业务/自动化组件必须独立命名空间专属SA；
2. 禁用长久静态Secret Token，统一开启**Bound ServiceAccount Token**（K8s 1.24+），短时效自动轮换；
3. 机器人SA命名规范：`sa-{应用/流水线名称}`，统一label标识归属团队、用途。
#### 机器人账号生命周期管理
- CI/CD、ArgoCD、监控组件单独创建SA，绑定最小权限RBAC；
- 平台提供自助机器人账号申请流程（14-platform-engineering），自动回收闲置90天未使用SA。

### 3.3 X509客户端证书（集群运维应急访问）
#### 使用规范
1. 仅用于集群底层运维应急操作，日常禁止研发使用证书访问集群；
2. 证书有效期统一设置90天，平台自动化轮换CA与客户端证书；
3. 根CA证书加密存储于Vault（08-secret-management），不对外分发；
4. 证书绑定固定用户名与分组，无法随意提升权限。

### 3.4 静态Token（废弃方案，全平台禁用）
禁止创建静态Token认证用户，存量逐步迁移至OIDC/SA绑定Token，存在永久密钥泄露不可控风险。

## 4. RBAC 授权体系（细粒度权限管控核心）
### 4.1 RBAC 四层资源模型
1. **Subject 主体**：OIDC用户、OIDC分组、ServiceAccount
2. **Role / ClusterRole 权限规则**：定义可操作资源、动词（get/list/watch/create/update/delete/patch）
3. **RoleBinding / ClusterRoleBinding 绑定关系**：主体与权限规则关联
4. **资源范围**：
   - ClusterRole：集群全局范围（节点、StorageClass、CRD、集群级审计）
   - Role：单一Namespace范围（业务Deployment、Service、ConfigMap等）

### 4.2 平台标准化权限模板（统一预设，禁止自定义杂乱权限）
#### 集群级 ClusterRole（仅管理员可绑定）
1. `platform:cluster-admin`：完整集群管理权限（仅SRE负责人）
2. `platform:cluster-readonly`：集群所有资源只读（审计、安全人员）
3. `platform:node-manager`：节点、NodeGroup运维权限（关联09-compute-resource-management）
4. `platform:storage-admin`：CSI、StorageClass、快照管理权限（关联06-storage-platform）

#### 命名空间级 Role（业务团队默认分配）
1. `platform:app-editor`：命名空间内所有应用资源读写，禁止操作Quota、NetworkPolicy、PV
2. `platform:app-viewer`：命名空间只读权限（测试、实习生）
3. `platform:pipeline-deploy`：流水线专用，仅允许create/patch Deployment/Service/Ingress，禁止删除节点级资源
4. `platform:secret-viewer`：仅读取非核心密钥，核心密钥权限隔离至密钥管理员（08-secret-management）

### 4.3 RBAC 强制约束规范
1. 禁止普通研发绑定任意ClusterRole，仅运维集群管理员可分配集群级权限；
2. 权限最小化：流水线仅授予发布所需动词，不授予delete集群资源权限；
3. 禁止通配符`*`权限，必须精确指定资源类型与操作动词；
4. 所有RoleBinding必须添加label标注归属团队、有效期，超期自动清理。

### 4.4 多租户权限隔离联动规则
与02-namespace-resource-governance联动：
- 业务Namespace创建时自动绑定对应团队OIDC分组`platform:app-editor`；
- 跨Namespace访问默认阻断，如需跨业务资源读取需提交权限审批工单；
- ResourceQuota、LimitRange修改权限仅开放给平台运维，业务研发不可调整。

## 5. Kubeconfig 标准化管理
### 5.1 kubeconfig 统一规范
1. 文件命名：`kubeconfig-{集群名称}-{用户名}.yaml`；
2. 统一字段约束：
   - cluster server地址使用平台统一负载均衡域名，不直接暴露apiserver节点IP；
   - OIDC配置自动开启token刷新，不存储长期token；
   - 证书数据通过OIDC动态下发，不内置长期客户端证书；
3. 禁止人工手写kubeconfig，全部由平台开发者门户自动生成下发。

### 5.2 kubeconfig 生命周期管控
1. 人工用户kubeconfig凭证有效期2小时，过期自动重新登录OIDC；
2. 机器人组件kubeconfig通过SA绑定短时效Token，Pod内自动挂载；
3. 员工离职后，OIDC分组自动移除，原有kubeconfig立即失效。

## 6. 证书生命周期管理（CA & 客户端证书）
### 6.1 证书分层体系
1. 根CA：集群顶级根证书，离线加密存储，每2年轮换一次；
2. 集群CA：apiserver、kubelet通信证书，有效期90天，控制器自动轮换；
3. 用户客户端证书：应急运维证书，90天有效期，平台定时推送轮换提醒；
4. 业务Ingress证书：由cert-manager统一管理（11-addon-management），与本模块隔离。

### 6.2 安全管控规则
1. 根CA私钥不存集群，存储企业Vault密钥管理系统；
2. 证书轮换自动化，无人工操作；
3. 泄露证书支持一键吊销，吊销列表CRL定期同步apiserver。

## 7. 多集群统一访问设计
### 7.1 多集群身份互通方案
所有集群对接同一套OIDC IAM，一套账号访问测试、预发、生产多集群；
kubeconfig内置多集群上下文，一键切换环境，无需切换账号。

### 7.2 集群访问权限隔离
1. 生产集群权限严格收紧，研发仅能查看，发布需流水线机器人账号；
2. 测试集群可下放完整编辑权限；
3. 通过OIDC分组区分环境权限，同一用户在不同集群拥有不同权限集。

## 8. 安全风险管控与防护策略
1. **权限溢出风险**：定期RBAC巡检脚本，扫描绑定cluster-admin的普通用户，自动告警；
2. **长期静态凭证风险**：清理未绑定过期策略的SA静态Token，强制迁移至短时Bound Token；
3. **账号残留风险**：每日同步企业员工组织架构，离职人员自动清除OIDC分组绑定；
4. **证书泄露风险**：证书不落地存储至开发机，OIDC动态下发临时凭证；
5. **横向越权风险**：NetworkPolicy+RBAC双层隔离，防止跨Namespace非法操作。

## 9. 审计联动设计（对接15-compliance-audit）
1. kube-apiserver开启完整审计日志，记录所有认证成功/失败、资源操作行为；
2. 审计日志携带用户身份、OIDC邮箱、分组、操作资源、操作动词；
3. 异常访问告警：连续认证失败、集群删除操作、管理员权限变更触发P2告警；
4. 日志留存180天，满足合规审计追溯要求。

## 10. 平台自动化运维能力
1. 自助权限申请门户：研发提交Namespace权限工单，运维审批后自动生成RoleBinding；
2. 权限定期巡检：每日输出权限风险报告（高权限用户、过期绑定、静态Token）；
3. 凭证自动轮换：OIDC Token、SA Token、客户端证书全流程无人工干预；
4. 批量权限回收：组织架构变更、人员离职一键清理所有集群权限绑定。

## 11. 模块落地禁忌（强制禁止行为）
1. 禁止给研发人员下发`cluster-admin`集群管理员权限；
2. 禁止业务使用default ServiceAccount，禁止创建永久静态Token；
3. 禁止人工修改apiserver认证配置，所有认证参数统一平台管控；
4. 禁止跨Namespace无审批授权，禁止使用`*`通配符权限；
5. 禁止长期有效客户端证书（超过90天），禁止私钥明文存储；
6. 禁止绕过OIDC直接分发集群CA证书给普通研发日常使用。

## 12. 与其他模块协作边界
1. 02-namespace-resource-governance：Namespace创建时自动绑定对应业务分组权限；
2. 08-secret-management：集群CA、根证书加密存储至Vault；
3. 14-platform-engineering：开发者门户提供kubeconfig自助下载、权限申请工单；
4. 15-compliance-audit：输出全量访问审计日志，支撑合规检查；
5. 10-workload-security：准入控制器拦截高权限SA绑定、非法权限配置。