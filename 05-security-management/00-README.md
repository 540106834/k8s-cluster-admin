# 05-security-management/00-README.md

## 一、文档基础信息

### 目录归属

路径：`05-security-management/`  
前置依赖：集群初始化文档、`02-workload-management/`、`03-network-management/06-network-policy.md`、`04-storage-management/`  
集群基准：Kubernetes v1.32.13、Calico v3.30.4、内网Harbor私有镜像仓库、离线CSI存储驱动  
环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产  
配套关联：`etcd-backup.md`、`cluster-upgrade-theory-guide.md`、全集群故障排查文档

### 模块核心定位

本目录为集群**全链路安全管控标准文档**，覆盖身份认证、RBAC授权、准入控制、Secret密钥管理、网络访问隔离、操作审计、集群整体加固七大安全维度。  
遵循最小权限、深度防御、多环境隔离三大安全核心原则，严格区分DEV/FAT/UAT/PROD四层环境安全基线，实现从集群入口、API请求、Pod运行、网络通信、密钥存储、操作留痕全链路防护，规避越权访问、密钥泄露、非法Pod运行、跨环境数据泄露、未授权集群操作等风险。

## 二、子文档功能总览
| 文件名称 | 核心覆盖内容 |
|--------|------------|
| 00-README.md | 安全模块总览、分层安全模型、阅读顺序、环境基线、上下游关联 |
| 01-authentication.md | K8s API身份认证体系、kubeconfig、ServiceAccount、OIDC第三方认证、证书生命周期管理、离线证书签发规范 |
| 02-authorization.md | RBAC完整模型、Role/ClusterRole/RoleBinding/ClusterRoleBinding、Node授权、Webhook授权、分环境权限分级、运维账号权限管控 |
| 03-admission-control.md | 准入控制器链、Pod Security Standards（Privileged/ Baseline/Restricted）、PodSecurityContext、镜像策略、资源准入校验、自定义准入Webhook落地 |
| 04-secret-management.md | Secret三种存储类型、镜像拉取私有仓库密钥、Secret加密存储、禁止明文硬编码、密钥轮换、Secret权限管控、避免日志泄露 |
| 05-network-security.md | NetworkPolicy深度隔离、多环境流量阻断、Pod端口白名单、出站访问控制、Ingress网关访问限制、内网仓库访问策略 |
| 06-audit-log.md | API审计日志配置、审计规则分级、日志持久化存储、审计告警、异常操作识别（删除资源、高权限账号变更、密钥修改） |
| 07-security-best-practices.md | 集群全局加固清单、节点安全、容器运行时加固、镜像安全、数据加密、应急安全处置、定期安全巡检SOP |

## 三、五层集群安全防御模型（本模块统一落地框架）
### 1. 接入层安全（Authentication 认证）
校验访问集群API的身份：管理员证书、ServiceAccount、OIDC账号，拒绝匿名非法访问。
### 2. 权限层安全（Authorization 授权 RBAC）
身份合法后，控制该账号可执行哪些资源操作，严格最小权限，禁止集群全局万能权限。
### 3. 准入层安全（Admission Control）
API请求合法后，拦截违规Pod/资源创建：禁止特权容器、高权限账号、非可信镜像、超规格权限配置。
### 4. 通信层安全（Network Security）
Pod之间、跨Namespace、跨环境流量细粒度隔离，阻断测试环境直连生产中间件。
### 5. 数据&留痕层安全（Secret + Audit）
密钥加密存储、定期轮换；所有集群操作全量审计日志留存，异常操作可追溯、可复盘。

## 四、DEV/FAT/UAT/PROD 四层环境安全基线差异化规范
### DEV本地
1. 仅本地Kind/Minikube自用集群，无外部访问；
2. 简化RBAC，默认全权限，不强制PodSecurity限制；
3. 无需完整审计日志，无严格密钥轮换规范；
4. 无NetworkPolicy强制隔离，仅用于本地调试。

### FAT测试
1. RBAC做基础权限区分，开发仅可操作fat命名空间；
2. 准入控制启用Baseline标准，禁止特权容器；
3. 部署基础NetworkPolicy，阻断FAT主动访问UAT/PROD网段；
4. 简易审计日志，不长期持久存储；
5. Secret无需严格加密轮换，测试密钥可短期复用。

### UAT预生产
1. 安全基线完全对齐生产，仅开放少量测试只读权限；
2. PodSecurity强制Restricted标准，禁止高权限容器；
3. 完整网络隔离策略，仅放行必要跨环境只读访问；
4. 全量审计日志持久化，保留30天；
5. Secret按月轮换，私有镜像仓库严格鉴权。

### PROD生产（强制最高安全标准）
1. **认证**：统一OIDC登录，禁用静态管理员证书长期使用，证书90天轮换；
2. **授权**：严格最小权限RBAC，无全局ClusterAdmin万能账号，操作双人复核；
3. **准入**：全局开启PodSecurity Restricted模式，拦截特权Pod、root运行容器、无限制权限容器；
4. **密钥**：Secret加密存储，核心业务密钥按月轮换，禁止明文配置、禁止日志输出密钥；
5. **网络**：所有Namespace默认拒绝入站流量，白名单放行业务互通，彻底阻断FAT访问生产；
6. **审计**：全量API审计日志持久化存储90天，删除PVC/数据库、修改RBAC、变更Ingress等高危操作实时告警；
7. 定期安全巡检，节点、容器、镜像、权限月度加固复盘。

## 五、标准化安全运维统一约束
1. 所有安全资源（RBAC、Policy、准入配置、Secret）全部纳入Git版本管理，变更留痕；
2. PROD高危操作（删除有状态负载、修改集群权限、更新密钥、网络策略变更）必须双人复核；
3. 禁止使用特权容器、容器以root用户运行，生产统一非安全上下文限制；
4. 内网Harbor镜像开启镜像扫描，禁止漏洞高危镜像部署至UAT/PROD；
5. 密钥禁止硬编码在YAML、代码、配置文件，统一使用Secret管理；
6. 集群升级、安全配置变更前执行etcd快照备份，防止误操作无法回滚；
7. 每日巡检审计日志异常操作，每周巡检RBAC冗余高权限账号、过期证书。

## 六、推荐阅读&实操顺序
1. 身份入口：01-authentication.md（集群访问第一道防线）
2. 权限管控：02-authorization.md（账号资源操作边界）
3. 容器运行防护：03-admission-control.md（拦截违规Pod创建）
4. 密钥数据安全：04-secret-management.md（密钥存储与轮换）
5. 流量隔离防护：05-network-security.md（Pod网络访问控制）
6. 操作追溯留痕：06-audit-log.md（全量审计日志）
7. 全局加固汇总：07-security-best-practices.md（完整安全巡检&加固清单）

## 七、上下游文档关联
### 上游前置
1. 集群初始化文档：CA证书、kubeadm认证配置、审计日志初始化参数
2. 工作负载管理：`02-workload-management/` Pod安全上下文、特权容器风险
3. 网络管理：`03-network-management/06-network-policy.md` 底层网络隔离实现
4. 存储管理：`04-storage-management/` Secret持久化存储权限管控

### 下游配套
1. `etcd-backup.md` 安全配置变更前置快照备份规范
2. `cluster-upgrade-theory-guide.md` 集群升级安全组件兼容（准入、审计、RBAC）
3. 集群故障排查文档：越权访问、密钥失效、网络拦截、准入拒绝故障SOP

## 八、核心适用业务场景清单
1. 集群运维账号权限划分、开发隔离命名空间操作权限 → 02-authorization.md
2. 禁止特权容器、限制容器root运行、拦截违规镜像部署 → 03-admission-control.md
3. 私有镜像仓库拉取密钥、数据库账号密码统一托管 → 04-secret-management.md
4. 测试环境禁止直连生产数据库、Pod细粒度访问控制 → 05-network-security.md
5. 集群删除资源、权限变更、密钥修改操作追溯与告警 → 06-audit-log.md
6. 集群证书过期轮换、OIDC统一登录、ServiceAccount权限管控 → 01-authentication.md
7. 节点、容器、镜像、密钥全维度安全加固月度巡检规范 → 07-security-best-practices.md