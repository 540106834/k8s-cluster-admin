# kubernetes-platform-design/03-image-supply-chain.md
## 文档元信息
- 模块：镜像供应链管理
- 优先级：★★★★★ 安全左移核心链路
- 依赖文档：00-platform-overview.md（分层、左移安全、最小权限原则）、01-cluster-access-management.md（ServiceAccount/RBAC）、02-namespace-resource-governance（租户隔离）
- 关联模块：04-application-delivery、08-secret-management、10-workload-security、14-platform-engineering、15-compliance-audit
- 适用角色：平台SRE、安全工程师、CI/CD运维、镜像仓库管理员、研发效能负责人

## 1. 模块定位与核心目标
### 1.1 定位
归属三层「集群资源管控域-镜像供应链域」，是应用上线前第一道安全关卡，覆盖**代码构建→镜像打包→漏洞扫描→仓库存储→集群拉取**全生命周期。
打通CI流水线、Harbor镜像仓库、集群镜像拉取鉴权、准入拦截，实现供应链风险前置拦截，从源头控制容器运行安全。

### 1.2 核心目标
1. 统一企业镜像仓库，标准化镜像命名、版本、分层规范，杜绝私有零散镜像源
2. 全链路安全卡点：构建扫描、仓库漏洞阻断、集群准入校验三层防护
3. 精细化仓库权限隔离，按团队/环境划分镜像项目，禁止跨团队随意拉取镜像
4. 自动化凭证管理，机器人账号、ImagePullSecret统一托管，无静态明文密钥
5. 镜像生命周期管控：自动清理过期镜像、冻结高危漏洞镜像、制品溯源
6. 与GitOps交付链路打通，仅允许平台仓库镜像流入集群，阻断外部公网镜像

### 1.3 解决业务痛点
- 研发直接使用公网未校验镜像，存在高危漏洞、后门风险
- 镜像无统一仓库，本地打包后上传至集群，版本混乱无法溯源
- 镜像仓库权限粗放，团队可随意覆盖、删除他人业务镜像
- 漏洞扫描后置，上线后才发现高危漏洞，返工成本极高
- 静态ImagePullSecret分散存储在各Namespace，密钥泄露无法统一回收
- 镜像无生命周期管理，大量无用镜像占用存储，无清理机制

## 2. 镜像供应链完整链路
```
代码仓库(Gitea/GitLab) → CI流水线(构建) → 构建阶段镜像扫描 → Harbor私有仓库存储 → 仓库持续漏洞扫描 → 镜像元数据标签留存 → 集群ServiceAccount鉴权拉取镜像 → 准入控制器二次校验镜像风险 → Pod启动
```
三层安全卡点：
1. 构建侧卡点：CI流水线打包完成后强制扫描，高危漏洞直接阻断推送仓库
2. 仓库侧卡点：Harbor定时扫描，高危镜像标记冻结，禁止拉取
3. 集群侧卡点：准入控制器校验镜像来源、漏洞等级、签名，拦截非法镜像

## 3. 镜像仓库架构与分层规范（Harbor）
### 3.1 仓库项目分层模型（和Namespace环境/团队一一对应）
项目命名规则：`{env}-{team}`，与Namespace命名完全对齐
示例：prod-pay、test-user、dev-order
系统保留项目：platform-base（系统基础镜像：alpine、nginx、jre等）

### 3.2 镜像统一命名规范
```
harbor.platform.company.com/{env}-{team}/{app-name}:{git-commit-sha}-{build-timestamp}
```
强制约束：
1. Tag必须绑定Git Commit SHA，禁止v1.0、latest浮动标签；
2. 基础镜像统一从platform-base拉取，禁止直接使用docker.io公共镜像；
3. 镜像必须携带标准Label（构建人、代码分支、构建时间、漏洞扫描结果）。

### 3.3 Harbor权限分级（Robot账号体系）
1. **流水线Robot账号（CI专用）**
   - 权限：对应项目push/pull，仅能推送本团队镜像；
   - 生命周期：绑定业务流水线，闲置90天自动回收；
   - 凭证：短期有效期，自动轮换，存入Vault（08-secret-management）。
2. **集群拉取Robot账号（集群全局）**
   - 只读权限，所有项目pull权限，用于集群节点拉取镜像；
   - 拆分多环境Robot：prod只读机器人、test/dev只读机器人，权限隔离。
3. **研发个人账号（OIDC对接Harbor）**
   - 仅本项目查看、手动推送测试镜像，无删除权限；
   - 生产项目仅允许查看，禁止手动推送，只能由CI流水线构建推送。
4. **平台管理员账号**
   - 全局项目管理、漏洞策略配置、镜像冻结/删除权限。

### 3.4 仓库存储策略
1. 基础镜像（platform-base）永久保留，多层缓存加速节点拉取；
2. dev/test环境镜像保留30天自动清理；
3. staging镜像保留90天；
4. prod业务镜像永久留存，保留历史版本用于回滚；
5. 开启镜像分层复用，减少存储占用与推送耗时。

## 4. 全链路安全扫描体系
### 4.1 CI构建阶段扫描（左移第一道防线）
CI流水线内置Trivy扫描器，打包完成后自动执行：
1. 漏洞分级阻断规则：
   - Critical/High漏洞：直接阻断镜像推送，流水线失败；
   - Medium漏洞：告警记录，允许测试环境推送，禁止生产推送；
   - Low/Info：仅日志留存，不阻断流程。
2. 扫描报告随CI日志归档，留存180天审计。

### 4.2 Harbor仓库持续扫描
1. 新镜像入库立即触发扫描；
2. 每日全量定时扫描所有存量镜像；
3. 漏洞库每日自动更新；
4. 风险处置：
   - Critical/High镜像自动冻结，集群无法拉取；
   - 推送风险告警至安全负责人、业务团队；
   - 支持漏洞白名单审批，仅临时放行测试环境。

### 4.3 集群准入二次校验（Admission Controller）
对接Trivy Operator/OPA Gatekeeper，Pod创建时校验：
1. 镜像来源校验：仅允许harbor.platform.company.com仓库镜像，拦截公网docker.io/第三方镜像；
2. 校验镜像扫描状态：冻结/高危镜像直接拒绝创建Pod；
3. 校验镜像标签规范：无commit-sha tag、缺少标准label直接拦截。

## 5. 集群镜像拉取鉴权体系 ImagePullSecret
### 5.1 统一托管方案（禁止手动创建Secret）
两种标准化实现：
1. **全局集群Pull Secret（推荐多租户）**
   集群kube-system命名空间统一创建集群级ImagePullSecret，通过ServiceAccount自动挂载至所有业务Pod，无需每个Namespace单独创建Secret。
   关联01-cluster-access-management：使用集群只读Robot账号凭证。
2. **独立项目Pull Secret（流水线专用）**
   各业务Namespace内置Secret，存放本团队CI Robot推送凭证，仅流水线Job使用。

### 5.2 凭证生命周期管控
1. Robot账号密码90天自动轮换，Vault同步更新Secret；
2. 废弃Robot账号对应的Secret自动清理；
3. 禁止明文写入YAML，所有拉取凭证由平台自动化注入。

### 5.3 约束规范
1. 禁止在PodSpec内手动填写imagePullSecrets，统一由SA自动挂载；
2. 禁止硬编码镜像仓库地址，使用全局域名变量；
3. 禁止节点配置docker daemon全局私有仓库密钥。

## 6. 镜像签名与可信供应链（生产强制）
### 6.1 签名规范
1. CI流水线构建完成后自动使用Cosign对镜像签名；
2. 签名密钥存储Vault，仅CI服务具备签名权限；
3. 准入控制器校验镜像有效签名，无签名镜像禁止部署至prod命名空间。

### 6.2 物料溯源
Harbor留存SBOM物料清单，记录镜像内所有组件、版本、开源许可证，满足合规审计。

## 7. 镜像生命周期自动化治理
1. **自动清理**：按环境区分过期镜像清理策略，由定时Job执行；
2. **冻结机制**：高危漏洞镜像自动冻结，无法拉取、无法部署；
3. **归档备份**：生产业务下线镜像归档至冷存储，保留1年；
4. **标签管控**：拦截latest、stable浮动标签，强制使用commit哈希固定版本。

## 8. 与多租户体系联动（联动02-namespace-resource-governance）
1. Namespace创建时同步创建对应Harbor项目，自动绑定团队Robot账号；
2. 环境隔离：dev/test镜像仅允许部署至对应环境Namespace，准入控制器拦截跨环境部署；
3. 资源配额联动：Harbor项目配置存储配额，限制单团队镜像存储容量；
4. 观测隔离：按team/env统计镜像存储容量、扫描漏洞数量，分团队告警。

## 9. 安全风险防护清单
1. **公网镜像引入风险**：准入控制器拦截外部镜像，仅允许企业私有仓库；
2. **高危漏洞上线风险**：CI+Harbor+集群三层扫描拦截，高危镜像全链路阻断；
3. **凭证泄露风险**：Robot短期密钥、自动轮换、Vault加密存储，禁止明文Secret；
4. **镜像篡改风险**：生产环境强制Cosign签名校验；
5. **版本混乱风险**：禁用latest标签，强制Git Commit SHA唯一标识；
6. **权限越权风险**：Harbor项目按团队隔离，研发无法操作其他团队镜像。

## 10. 审计与合规（联动15-compliance-audit）
1. Harbor全量日志：镜像推送、删除、拉取、漏洞扫描、Robot账号操作；
2. 集群审计日志记录所有镜像拉取行为、镜像部署资源；
3. 月度供应链安全报告：漏洞统计、违规镜像清单、过期镜像存储占用；
4. 日志、SBOM、扫描报告统一留存180天，满足等保合规要求。

## 11. 落地强制禁忌规范
1. 禁止直接使用docker.io、gcr.io等公网第三方镜像部署业务；
2. 禁止使用latest、stable浮动tag，必须使用Git Commit SHA固定版本；
3. 禁止手动创建、修改ImagePullSecret，统一平台自动化托管；
4. 禁止生产环境跳过镜像扫描、签名校验；
5. 禁止跨团队Harbor项目无审批读写权限；
6. 禁止本地手动打包镜像上传集群，所有镜像必须经过CI流水线构建；
7. 禁止长期未轮换的静态Robot账号凭证。

## 12. 跨模块协作边界
1. 01-cluster-access-management：Harbor对接OIDC统一账号；Robot账号为标准化ServiceAccount；
2. 02-namespace-resource-governance：Harbor项目与Namespace一一对应，环境隔离规则互通；
3. 04-application-delivery：应用Deployment镜像地址强制为本平台Harbor域名，GitOps统一管理镜像版本；
4. 08-secret-management：Harbor Robot凭证、Cosign签名密钥统一存入Vault；
5. 10-workload-security：OPA准入控制器实现镜像来源、漏洞、签名拦截；
6. 14-platform-engineering：自助门户提供镜像项目申请、漏洞查询、存储扩容工单；CI/CD流水线集成扫描推送；
7. 15-compliance-audit：镜像全生命周期操作日志纳入审计巡检。