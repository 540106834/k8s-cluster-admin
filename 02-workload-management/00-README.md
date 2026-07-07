# 02-workload-management/00-README.md

## 一、文档基础信息

### 目录归属

路径：`02-workload-management/`
前置依赖：`03-cluster-planning.md`、01系统初始化、containerd/Calico集群就绪
集群基准：Kubernetes v1.32.13 单Master+2 Worker，Ubuntu22.04，Harbor内网镜像仓库
配套关联：`05-kubeconfig-management/`、`etcd-backup.md`、`10-troubleshooting.md`

### 本模块核心定位

工作负载（Workload）是K8s承载业务应用的核心资源集合，本目录完整覆盖**命名空间隔离、Pod基础、各类控制器、资源管控、发布变更、扩缩容、故障排查**全生命周期标准化运维操作，分为无状态、有状态、节点守护、定时批处理四大类业务模型，统一落地声明式运维规范。

## 二、目录分档功能总览

| 文件名称 | 核心覆盖内容 |
| -------- | ------------ |
| 01-namespace-management.md | Namespace隔离逻辑、创建/删除/配额、多环境隔离、资源回收、命名空间安全规范 |
| 02-pod-lifecycle.md | Pod完整生命周期、状态流转、探针（liveness/readiness/startup）、容器启停机制、退出码分析 |
| 03-deployment-management.md | Deployment无状态应用、副本管理、滚动更新策略、多版本管理、基础声明式yaml模板 |
| 04-stateful-workloads.md | StatefulSet有状态应用、稳定网络标识、有序启停、PVC一对一绑定、中间件（MySQL/Redis）部署规范 |
| 05-daemon-workloads.md | DaemonSet节点全局负载、日志采集/监控/网络代理类组件、节点亲和调度、污点容忍 |
| 06-batch-workloads.md | Job一次性批任务、CronJob定时调度、并发控制、任务失败重试、定时表达式规范 |
| 07-resource-management.md | LimitRange容器默认资源限制、ResourceQuota命名空间资源配额、防止节点资源耗尽 |
| 08-workload-scaling.md | 手动scale扩缩容、HPA CPU/内存/自定义指标自动伸缩、缩容保护、扩缩容事件观测 |
| 09-rollout-and-rollback.md | 镜像更新、配置热更新、发布暂停/恢复、版本回滚、重启负载、发布策略调优 |
| 10-workload-troubleshooting.md | Pod无法启动、镜像拉取失败、探针失败、OOM、调度失败、发布卡死、资源超限全套排错 |

## 三、核心理论分层认知

### 3.1 底层最小单元：Pod

Pod是调度最小原子，控制器均围绕Pod做编排管理；一个Pod内可包含一个或多个业务容器+sidecar容器。

### 3.2 四大控制器工作负载分类

1. **无状态 Workload（Deployment）**
   无固定网络标识、无绑定持久化存储，副本完全对等，适合Web、API服务。
2. **有状态 Workload（StatefulSet）**
   有序序号、固定域名、独立PVC，数据库、缓存、消息队列等中间件专用。
3. **节点守护 Workload（DaemonSet）**
   每个匹配节点仅运行1副本，日志、监控、网络插件、安全代理。
4. **批处理定时 Workload（Job/CronJob）**
   一次性执行任务、周期定时任务，数据同步、备份、定时清理脚本。

### 3.3 全生命周期运维链路

环境隔离(Namespace) → 定义资源规格(ResourceQuota/LimitRange) → 选择对应控制器部署 → 配置健康探针保障可用性 → 手动/自动扩缩容承载流量 → 版本滚动发布/回滚迭代 → 故障定位排查

## 四、标准化操作规范（本目录统一约束）

1. 所有业务资源统一使用 `kubectl apply -f` 声明式管理，禁止kubectl create/run临时创建；
2. 资源文件按命名空间分目录存放，规范路径：`/usr/local/src/post-install/workload/${ns}/`；
3. 强制配置 `resources.requests` + `resources.limits`，全局开启LimitRange兜底；
4. 生产发布使用滚动更新策略，禁止Recreate停机更新；
5. 所有业务必须配置就绪探针+存活探针，杜绝不健康Pod接入流量；
6. 命名空间按环境划分：dev/test/prod，通过ResourceQuota隔离资源，避免环境互相抢占；
7. 操作变更留存yaml版本，发布前导出资源备份，重大变更前执行etcd快照备份。

## 五、推荐阅读&实操顺序

1. 基础隔离：01-namespace-management.md（部署业务前置必做）
2. 底层原理：02-pod-lifecycle.md（理解Pod运行基础）
3. 业务部署主体：03-deployment（无状态）→04-stateful（中间件）→05-daemon（节点组件）→06-batch（定时任务）
4. 资源防护：07-resource-management.md（集群保护）
5. 弹性运维：08-workload-scaling.md（扩缩容）
6. 版本迭代：09-rollout-and-rollback.md（发布回滚）
7. 异常兜底：10-workload-troubleshooting.md

## 六、上下游文档关联

### 上游前置

1. `03-cluster-planning.md`：集群资源、网段、存储前置规划
2. `02-containerd.md`：容器运行时镜像、资源底层限制
3. `06-cni-calico.md`：Pod网络连通性基础

### 下游配套

1. `05-kubeconfig-management/`：多用户、多命名空间权限管控
2. `etcd-backup.md`：负载变更前数据备份规范
3. `10-troubleshooting.md`：集群级通用故障排查
4. `cluster-migration.md`：业务负载跨集群迁移导出导入规范

## 七、适用业务场景清单

1. Web/API微服务 → Deployment
2. MySQL、Redis、MongoDB等持久化中间件 → StatefulSet
3. Filebeat、Prometheus NodeExporter、网络代理 → DaemonSet
4. 数据同步、定时报表、数据库备份、日志清理 → CronJob/Job
5. 多环境研发隔离、资源限额管控 → Namespace+ResourceQuota+LimitRange
6. 流量波动自动扩容、低谷缩容节省成本 → HPA自动伸缩
7. 版本迭代、灰度发布、故障快速回滚 → Rollout管理