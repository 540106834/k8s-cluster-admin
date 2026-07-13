# 03‑worker‑node‑management/08‑resource‑pressure.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/08‑resource‑pressure.md`
- 前置文档：
  `00‑overview.md`、`01‑node‑basics.md`、`06‑kubelet‑runtime.md`、`02‑workload‑management` QoS相关文档
- 集群基准：Kubernetes‑1.32.13，Lease机制、containerd‑2.1.5，kubelet eviction驱逐逻辑、QoS三级划分、evictionHard/evictionSoft阈值，Ubuntu‑22.04，离线环境。
- 适用环境：DEV / FAT / UAT / PROD
- 文档内容：三种压力类型、驱逐阈值配置、QoS等级、驱逐打分机制、驱逐执行流程、节点Pressure状态带来的影响、常见误区、生产阈值配置、故障排查。

## 二、整体概述
### 2.1 三种资源压力类型（kubelet判定）
kubelet持续监控节点资源，满足阈值之后将对应Pressure条件置为`true`：
1. `MemoryPressure`：内存不足；
2. `DiskPressure`：磁盘空间或者inode耗尽；
3. `PIDPressure`：系统进程数量超出上限。

只要任意一个Pressure为true：
1. 节点Condition状态更新上报给apiserver；
2. 开启驱逐逻辑，kubelet按照优先级驱逐Pod；
3. 节点打上对应的NoExecute内置污点；
4. scheduler不会在该节点新建Pod。

> 只有三个Pressure全部为false，节点Ready状态才稳定为True。

### 2.2 两套驱逐阈值（定义在 `/var/lib/kubelet/config.yaml`）
1. `evictionSoft`（软驱逐）：到达阈值后等待 `evictionSoftGracePeriod`（默认4min）再执行驱逐；
2. `evictionHard`（硬驱逐）：到达阈值立刻执行驱逐，无宽限期，生产核心配置。

```yaml
evictionHard:
  memory.available: 100Mi          # 可用内存低于100Mi触发内存驱逐
  nodefs.available: 10%            # 系统盘剩余空间低于10%
  nodefs.inodesFree: 5%            # inode剩余低于5%
  imagefs.available: 15%           # containerd镜像磁盘剩余低于15%
  imagefs.inodesFree: 5%

evictionSoft:
  memory.available: 200Mi
  nodefs.available: 15%
evictionSoftGracePeriod:
  memory.available: 4m
  nodefs.available: 4m
```
- nodefs：宿主机根分区；imagefs：存放镜像和可写层的分区。
- kubelet‑GC镜像清理阈值（独立配置）：
    `imageGCHighThresholdPercent:85`，磁盘使用率超过85%优先清理镜像；镜像GC执行完仍然达不到阈值，才会驱逐Pod。

## 三、Pod QoS 优先级（驱逐顺序核心依据）
kubelet根据Pod的`resources.requests`和`resources.limits`划分3个等级，驱逐优先级由高到低：
`Best‑Effort（尽力服务） > Burstable（突发） > Guaranteed（最高保障）`

### 3.1 Guaranteed（最高优先级，最后才会被驱逐）
条件：CPU和内存的`requests = limits`，两个字段必须全部配置并且相等。
```yaml
resources:
  limits:
    cpu: 1000m
    memory: 1Gi
  requests:
    cpu: 1000m
    memory: 1Gi
```
- 生产数据库、中间件尽量配置为Guaranteed；
- 只有节点资源极度耗尽时才会被驱逐。

### 3.2 Burstable（中间优先级）
只要requests和limits不一致，或者只配置requests没有limits就属于Burstable；
大部分业务微服务默认都是Burstable。

### 3.3 Best‑Effort（优先级最低，最先被驱逐）
完全不配置requests和limits；节点资源紧张时第一批被驱逐。
> PROD环境禁止业务Pod使用Best‑Effort，所有Pod必须配置requests和limits。

## 四、kubelet驱逐打分机制（eviction‑priority）
当多个Pod同为Burstable或者Best‑Effort时，kubelet计算驱逐分数：
`驱逐得分 = Pod实际消耗内存 - Pod请求内存(request.memory)`
1. 实际占用超出request越多，分数越高，越优先被驱逐；
2. 相同超出值，内存占用绝对值更大优先驱逐；
3. Guaranteed类型Pod只有节点剩余内存极低时才会被驱逐。

### 驱逐整体执行步骤
1. 资源达到evictionHard阈值；
2. kubelet筛选所有Pod，按照QoS等级 + 驱逐得分排序；
3. 向apiserver发送删除Pod请求；
4. apiserver通知ReplicaSet在其他节点重建Pod；
5. 删除Pod之后释放内存、磁盘；
6. 资源回落低于阈值后，Pressure=false，节点恢复正常。

> 注意：kubelet驱逐Pod是**节点本地行为**，Node‑Controller宕机驱逐（Lease超时）是控制平面行为，二者机制完全分开。

## 五、Pressure开启之后节点带来的影响
1. Disk‑Pressure = true
    - kubelet执行镜像GC清理无用镜像；
    - GC之后磁盘仍然不足，则开始驱逐Pod；
    - scheduler不再调度新Pod到此节点；
2. Memory‑Pressure = true
    - 停止调度新Pod；按照QoS驱逐Pod释放内存；
    - 内核也会触发OOM‑kill杀掉进程，内核OOM优先级独立于kubelet驱逐逻辑；
3. PID‑Pressure = true
    - 节点进程总数达到allocatable pid上限；拒绝新建容器进程；驱逐占用大量进程的Pod。

### 重要误区区分
1. kubelet驱逐Pod只会删除Pod对象，PVC不会被删除；
2. 驱逐旧Pod之后由ReplicaSet在别的节点重建Pod；
3. kubelet驱逐Pod ≠ 内核OOM kill进程：
    - kubelet驱逐：上层控制器重建Pod；事件会记录 `Evicted`；
    - 内核OOM：操作系统直接杀死容器进程，Pod状态CrashLoopBackOff。

## 六、生产环境配置建议（PROD标准）
### 6.1 驱逐阈值不建议修改默认evictionHard值
```
memory.available:100Mi
nodefs.available:10%
nodefs.inodesFree:5%
```
只修改上层Prometheus告警阈值提前预警：
- 磁盘使用率＞80%、inode＞80%开启Warning告警；
- 内存可用低于200Mi提前告警，在触发驱逐前扩容或者清理；
不要调低evictionHard阈值（比如改成5%），阈值过低会导致kubelet频繁驱逐Pod。

### 6.2 QoS落地建议
1. StatefulSet中间件（MySQL、Redis、Kafka）设置为Guaranteed；
2. 普通微服务配置合理requests和limits，属于Burstable；
3. 定时任务Job可设置Burstable；
4. 禁止业务Pod为Best‑Effort。

### 6.3 内核层面配套优化
1. 开启内存预留，给系统进程预留内存；
2. 调高`fs.inotify.max_user_instances`防止inode耗尽；
3. 容器日志开启轮转，`containerLogMaxSize:50Mi`，避免容器日志打满磁盘。

## 七、资源压力问题排查命令
### 7.1 查看节点压力状态（master节点执行）
```bash
kubectl describe node node‑10‑0‑10‑21 | grep -E "MemoryPressure|DiskPressure|PIDPressure|Ready"

# 查看被驱逐Pod事件
kubectl get events -n prod | grep Evicted
```

### 7.2 登录节点查看资源情况
```bash
# 磁盘与inode
df -h
df -i

# 查看kubelet驱逐日志
journalctl -u kubelet | grep -i evict

# 查看系统进程数量
ps -e | wc -l

# 查看内核OOM记录
dmesg -T | grep -i "Out‑of‑Memory"

# 查看kubelet驱逐配置
cat /var/lib/kubelet/config.yaml | grep evictionHard -A 5
```

## 八、问题处理步骤
### 场景1：Disk‑Pressure
1. 优先查看inode是否耗尽：`df -i`；
2. kubelet自动GC清理镜像；查看 `crictl images`；
3. GC后磁盘依然紧张：清理`/var/log/containers`容器日志，清理core文件；
4. 长期方案：扩容磁盘或者把日志挂载到PVC。

### 场景2：Memory‑Pressure，大量Pod被驱逐
1. 查看events确认哪些Pod被驱逐；
2. 查看Pod内存实际占用，判断是否内存泄漏；
3. 调高Pod内存limits或者扩容节点内存；
4. 调整业务代码修复内存泄漏问题。

### 场景3：PID‑Pressure
1. 找到进程数异常的Pod；
2. kubelet配置 `podPidLimit`限制单个Pod最大进程数；
3. 升级服务器内核。

## 九、DEV / FAT / UAT / PROD差异化标准
1. DEV：允许Best‑Effort Pod；驱逐阈值不用严格管控；
2. FAT：业务尽量配置requests和limits；禁止长期出现Pressure；
3. UAT：QoS体系对齐生产；evictionHard使用默认值；出现Pressure及时处理；
4. PROD强制约束：
    1. 所有业务Pod禁止Best‑Effort；中间件配置Guaranteed；
    2. evictionHard保持默认值，修改驱逐阈值必须工单审批；
    3. Prometheus配置USE模型告警，磁盘80%、内存可用低于200Mi提前告警；
    4. 出现Memory‑Pressure/Disk‑Pressure视为一级故障，及时处理；
    5. 定期核查容器日志轮转是否生效，防止日志堆积触发磁盘压力。

## 十、生产最佳实践
1. 依靠Prometheus提前告警，不要等到kubelet开始驱逐Pod才处理问题；
2. 合理划分QoS等级，重要中间件配置Guaranteed；
3. 区分kubelet驱逐和内核OOM，定位根因；
4. 容器日志开启轮转，避免日志耗尽inode；
5. 监控node‑exporter指标：内存可用、磁盘使用率、inode使用率、进程数量；
6. 定期复盘被驱逐Pod，优化limits参数。

## 十一、关联文档
1. `06‑kubelet‑runtime.md`：kubelet配置、镜像GC；
2. `05‑node‑troubleshooting.md`：节点Not‑Ready排障；
3. `04‑node‑lifecycle.md`：节点内置NoExecute污点；
4. `02‑workload‑management`：requests、limits配置；
5. `07‑monitoring‑and‑troubleshooting`：node‑exporter指标配置。