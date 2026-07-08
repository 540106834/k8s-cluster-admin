# 05-resource-monitoring.md
## 一、文档基础信息
- 归属目录：`06-daily-operations/`
- 前置阅读：`00-README.md`、`01-kubectl-usage.md`、`02-workload-management/07-resource-management.md`
- 集群基准：Kubernetes v1.32.13、metrics-server 正常部署、节点/Pod资源指标采集、内网监控平台、ResourceQuota配额管控
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心覆盖：kubectl top 使用规范、节点/容器CPU内存利用率查询、metrics-server底层机制、资源水位判定标准、高负载Pod定位、临时实时观测、资源过载故障排查、监控巡检规范

## 二、资源监控底层原理
### 2.1 metrics-server 组件作用
集群内置指标采集组件，作为kubectl top数据源，定时从各节点containerd采集容器CPU、内存、磁盘、网络指标，提供API供kubectl/监控平台调用。
1. 必备部署：kube-system下metrics-server Deployment；
2. 采集周期：默认15s；
3. 依赖准入、RBAC权限，无metrics-server时`kubectl top`直接报错。

### 2.2 资源四元观测维度
1. CPU：request/limit、当前使用率、节点总分配水位；
2. 内存：RSS实际占用、缓存、OOM风险判定；
3. 存储：PVC/PV磁盘使用率、节点磁盘inode/容量水位；
4. 节点负载：节点总allocatable资源、多业务抢占IO/CPU。

### 2.3 资源水位风险分级标准（全环境统一）
| 水位等级 | CPU使用率 | 内存使用率 | 处置策略 |
|--------|-----------|------------|----------|
| 安全正常 | ≤70% | ≤70% | 无需处理 |
| 预警水位 | 70%~85% | 70%~85% | 业务低峰扩容副本/升级资源规格 |
| 危险阻塞 | >85% | >85% | 立即扩容、拆分负载，防止OOM/节点卡死 |

## 三、kubectl top 标准操作命令
### 3.1 查看全集群节点资源占用
```bash
kubectl top nodes
```
输出字段：节点名称、CPU核数占用、内存占用、总分配上限。

### 3.2 查看命名空间下所有Pod资源
```bash
# 查看Pod整体资源
kubectl top pods -n prod

# 按内存从高到低排序，快速定位高负载Pod
kubectl top pods -n prod --sort-by=memory

# 按CPU排序
kubectl top pods -n prod --sort-by=cpu
```

### 3.3 查看Pod内每个容器细分资源
```bash
kubectl top pod mysql-0 -n prod --containers
```

### 3.4 实时持续观测资源波动（发布/备份时段专用）
```bash
# 每2秒刷新一次
watch -n 2 kubectl top pods -n prod
```

## 四、指标解读与水位判断
### 4.1 CPU判定逻辑
1. 实际占用 > limit上限 → Pod被限流，业务卡顿；
2. 节点总CPU分配 > 85% → 新增Pod调度失败，现有业务争抢CPU；
3. 批量备份、快照任务并发会瞬间拉高CPU，必须低峰执行。

### 4.2 内存判定逻辑（OOM核心依据）
1. 实际内存接近limit → 极易触发OOM killed；
2. 内存持续缓慢上涨代表内存泄漏，需重启Pod并修复代码；
3. 节点内存打满会触发内核回收，业务读写阻塞。

### 4.3 存储资源水位（配套df/human）
```bash
# 进入容器查看挂载磁盘使用率
kubectl exec -it mysql-0 -n prod -- df -h
```
PVC磁盘使用率>80%进入预警，>90%高危，立即扩容PVC或清理过期备份。

## 五、高负载故障定位标准流程
1. 使用`kubectl top nodes`定位负载过高节点；
2. `kubectl top pods -n ${ns} --sort-by=memory/cpu`找到占用最高Pod；
3. 进入容器查看进程占用、磁盘io：
```bash
# 容器内查看进程资源
kubectl exec -it mysql-0 -n prod -- top
# 查看磁盘io负载
kubectl exec -it mysql-0 -n prod -- iostat -x 1
```
4. 核对Pod resources limits，确认是否配置资源上限；
5. 区分瞬时峰值（发布/备份）与长期持续高负载：
   - 瞬时峰值：调整任务至低峰执行；
   - 长期高负载：上调PVC容量、扩容Pod资源规格、HPA扩容副本。

## 六、DEV/FAT/UAT/PROD 监控差异化基线
### DEV本地
无强制指标告警，仅临时top查看，无水位管控。
### FAT测试
1. 预警水位85%，无需严格处置；
2. 可自由扩容资源，测试完成自动清理负载释放资源。
### UAT预生产
1. 水位阈值对齐生产，超过80%预警；
2. 预生产数据备份错开高峰，防止IO打满存储。
### PROD生产（强制约束）
1. CPU/内存70%预警、85%高危告警，短信通知运维；
2. 核心中间件长期负载不得超过70%，提前扩容；
3. 存储磁盘80%预警、90%阻断写入，必须在线扩容PVC；
4. 批量发布、快照备份、数据迁移操作统一凌晨低峰，避免资源抢占；
5. 每日自动化监控巡检，持续高负载负载输出周报推动优化。

## 七、临时资源观测运维场景
1. 业务发布滚动更新：watch kubectl top 观测Pod扩容后资源波动；
2. 定时备份CronJob执行期间：观测存储节点io、内存占用；
3. 故障恢复、快照克隆：监控存储池水位，防止磁盘打满；
4. HPA弹性扩容验证：观测副本数量随负载自动伸缩。

## 八、高频监控故障排查
### 1. kubectl top 返回 error: metrics not available yet
metrics-server DS/Deployment未就绪、镜像拉取失败、网络策略拦截apiserver访问metrics服务；
```bash
# 检查metrics组件状态
kubectl get ds,deploy -n kube-system -l app=metrics-server
kubectl logs -n kube-system deploy/metrics-server
```

### 2. top指标延迟、刷新缓慢
metrics-server副本资源不足，上调CPU/memory requests。

### 3. Pod内存持续上涨，无自动回落
应用内存泄漏，滚动重启Pod临时缓解，业务侧修复代码释放内存。

### 4. 节点CPU瞬间拉满至100%
并发备份、快照、批量Pod重启抢占IO/CPU，拆分任务错开业务高峰。

### 5. PVC磁盘使用率95%，业务写入报错
存储容量不足，执行PVC在线扩容操作，清理过期备份文件。

### 6. 新Pod无法调度，提示Insufficient cpu/memory
节点总allocatable资源耗尽，缩容闲置负载或新增节点。

## 九、生产资源监控最佳实践
1. 集群统一部署metrics-server，保障kubectl top指标稳定采集；
2. 严格遵循70%预警、85%高危水位阈值，提前扩容避免业务阻塞；
3. 发布、备份、快照、数据迁移全部安排业务低峰，降低资源抢占；
4. 所有容器强制配置CPU/memory limits，LimitRange准入拦截无限制Pod；
5. 开启资源水位自动化告警，高负载及时介入；
6. 每月梳理长期高负载业务，优化资源规格、拆分存储节点；
7. 存储磁盘单独监控，避免磁盘满导致中间件崩溃丢失数据。

## 十、运维速查命令
```bash
# 查看所有节点资源占用
kubectl top nodes

# 按内存排序Pod
kubectl top pods -n prod --sort-by=memory

# 持续观测资源波动
watch -n 2 kubectl top pods -n prod

# 查看容器细分资源
kubectl top pod mysql-0 -n prod --containers

# 查看metrics-server运行状态
kubectl get deploy -n kube-system -l app=metrics-server
kubectl logs -n kube-system deploy/metrics-server
```

## 十一、关联文档
1. 客户端基础：`01-kubectl-usage.md` top命令权限预校验
2. 资源准入：`05-security-management/03-admission-control.md` LimitRange强制资源limits配置
3. 负载发布：`03-workload-operations.md` 发布期间资源观测规范
4. 存储运维：`04-volume-operations.md` PVC扩容解决磁盘满高负载问题
5. 存储故障：`04-storage-management/06-storage-troubleshooting.md` 存储池磁盘满、IO阻塞故障SOP
6. 日常巡检：`07-production-checklist.md` 资源水位每日自动化巡检项