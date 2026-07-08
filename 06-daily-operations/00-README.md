# 06-daily-operations/00-README.md
## 一、文档基础信息
### 目录归属
路径：`06-daily-operations/`
前置依赖：集群全套业务文档（工作负载、网络、存储、安全、存储）、etcd备份文档、故障排查文档
集群基准：Kubernetes v1.32.13、ipvs kube-proxy、CSI动态存储、OIDC认证、GitOps配置管理、内网Harbor
环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
配套关联：`cluster-migration.md`、`cluster-upgrade-theory-guide.md`、各模块troubleshooting故障文档

### 模块核心定位
本目录为**集群日常标准化运维操作手册**，面向运维、开发、测试人员，统一kubectl操作规范、资源标签注解管理、负载发布扩缩容、日志调试、资源监控、YAML资源版本管控、每日巡检清单、高频命令速查。
统一规范四层环境操作流程，区分FAT自由调试、UAT谨慎变更、PROD双人复核高危操作，覆盖集群90%日常运维场景，降低误操作、发布故障、资源混乱风险，形成标准化可落地操作基线。

## 二、子文档功能总览
| 文件名称 | 核心覆盖内容 |
|--------|------------|
| 00-README.md | 日常运维模块总览、操作分层规范、阅读顺序、上下游依赖、环境操作红线 |
| 01-kubectl-usage.md | kubectl 客户端安装、kubeconfig上下文切换、全局别名、权限预校验、离线使用规范、安全使用约束 |
| 02-resource-management.md | Label标签标准化规范、Annotation注解用途、kubectl patch三种更新方式、资源批量筛选、资源分组管理 |
| 03-workload-operations.md | Deployment/StatefulSet/DaemonSet 滚动发布、回滚、扩缩容、重启、暂停恢复、分批发布、生产发布流程 |
| 04-logs-and-debug.md | Pod日志查看、实时日志、历史日志、事件检索、kubectl exec交互调试、临时调试Pod、故障现场留存 |
| 05-resource-monitoring.md | kubectl top 节点/Pod资源利用率、metrics指标查询、资源水位判断、高负载定位、临时资源观测 |
| 06-yaml-management.md | 标准YAML编写规范、资源导出备份、本地与集群资源diff对比、apply/create/patch选用原则、GitOps资源管理 |
| 07-production-checklist.md | 每日/每周/月度集群巡检清单、发布前校验清单、存储/网络/权限/证书/备份巡检项、异常分级处置 |
| 08-operation-cheatsheet.md | 全场景高频kubectl命令速查表，按工作负载/存储/网络/安全分类整理，可直接复制使用 |

## 三、三层日常运维操作防御框架
1. **操作前置校验层**
   kubeconfig上下文校验、权限预校验`kubectl auth can-i`、资源Quota/容量/证书前置检查，提前拦截高危操作；
2. **变更执行层**
   区分Patch/Apply/Create使用场景，生产分批滚动发布，禁止一次性全量重启；
3. **事后观测留痕层**
   实时观测Pod事件、日志、资源指标，变更完成留存YAML备份、审计日志，故障可回滚、可追溯。

## 四、DEV/FAT/UAT/PROD 四层环境运维操作红线规范
### DEV本地
1. 无操作审批流程，可随意删除、重建资源；
2. 无需备份、无需巡检，仅本地调试；
3. 允许长期本地kubeconfig高权限上下文。

### FAT测试
1. 自由创建/更新普通业务资源，无需双人复核；
2. 每日定时自动清理闲置PVC、废弃Pod、临时ConfigMap；
3. 发布前简易校验资源配额，避免存储打满；
4. 可临时清空NetworkPolicy、RBAC调试。

### UAT预生产
1. 变更操作需导出资源YAML备份，留存操作记录；
2. 中间件、存储PVC删除需运维确认；
3. 发布流程对齐生产，禁止一次性批量重启所有副本；
4. 每日执行基础巡检，记录异常指标。

### PROD生产（强制安全约束）
1. **高危操作（删除STS/PVC/NetworkPolicy/RBAC/Secret）必须双人复核+工单**；
2. 所有变更避开业务凌晨低峰窗口执行；
3. 发布前完整执行巡检清单，校验存储容量、PVC配额、证书有效期、备份任务状态；
4. 变更前导出对应命名空间资源YAML备份，关键操作前执行etcd快照；
5. 禁止直接kubectl delete删除有状态业务资源，优先滚动缩容+人工清理PVC；
6. 操作全程观测日志、事件、CPU/内存指标，出现异常立即回滚；
7. 每日自动化巡检告警，每周人工完整巡检，月度复盘资源冗余。

## 五、标准化运维统一约束
1. 所有集群资源统一使用Label标准化标签，用于批量筛选、分组管理；
2. 生产禁止使用`kubectl apply -f`直接覆盖高危资源，优先patch局部更新；
3. 禁止使用`--force --grace-period=0`强制删除业务Pod，避免数据丢失；
4. 业务发布、存储扩容、网络策略变更、权限修改均需留存操作日志；
5. kubeconfig本地文件权限统一`chmod 600`，禁止明文共享；
6. 优先使用GitOps管理YAML资源，减少本地临时手动kubectl操作；
7. 出现业务异常优先使用日志、事件、top指标定位，不直接重启/删除资源。

## 六、推荐阅读&实操顺序
1. 客户端基础：01-kubectl-usage.md（集群操作入口工具规范）
2. 资源标识管理：02-resource-management.md（标签、注解、资源局部更新）
3. 负载发布变更：03-workload-operations.md（发布、回滚、扩缩容核心流程）
4. 故障调试手段：04-logs-and-debug.md（日志、事件、交互调试）
5. 资源观测监控：05-resource-monitoring.md（CPU/内存/存储水位观测）
6. 资源版本管控：06-yaml-management.md（YAML备份、对比、Git管理）
7. 标准化巡检基线：07-production-checklist.md（发布/日常完整校验清单）
8. 快速查阅工具：08-operation-cheatsheet.md（高频命令速查手册）

## 七、上下游文档关联
### 上游前置
1. 集群安全文档：`05-security-management/01-authentication.md` kubeconfig认证、ServiceAccount权限
2. 工作负载管理：`02-workload-management/` Deployment/StatefulSet发布底层机制
3. 网络管理：`03-network-management/` NetworkPolicy、Ingress日常操作规范
4. 存储管理：`04-storage-management/` PV/PVC扩容、备份日常运维操作

### 下游配套
1. `etcd-backup.md` 高危运维变更前置快照备份流程
2. 集群故障排查文档：业务Pod崩溃、发布失败、资源挂载异常定位SOP
3. 集群升级文档：升级前后资源巡检、资源备份操作规范
4. 安全审计：`05-security-management/06-audit-log.md` 所有kubectl操作全量审计留痕

## 八、核心适用业务场景清单
1. 本地kubectl配置、多集群上下文切换、离线集群操作、权限预校验 → 01-kubectl-usage.md
2. 统一资源标签体系、批量筛选资源、局部更新配置不完整重写YAML → 02-resource-management.md
3. 业务版本发布、失败回滚、弹性扩缩容、分批重启负载 → 03-workload-operations.md
4. 业务报错排查、实时日志、历史事件、进入容器调试、临时调试Pod → 04-logs-and-debug.md
5. 节点/容器CPU内存占用观测、高负载定位、存储资源水位判断 → 05-resource-monitoring.md
6. 资源YAML标准化编写、集群资源导出备份、本地与线上配置对比Diff → 06-yaml-management.md
7. 每日自动化巡检、发布前校验项、月度安全&存储完整巡检清单 → 07-production-checklist.md
8. 工作负载、存储、网络、安全高频操作命令快速复制查阅 → 08-operation-cheatsheet.md