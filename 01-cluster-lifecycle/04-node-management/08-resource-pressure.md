# 03-worker-node-management/08-resource-pressure.md
## 节点资源压力与kubelet驱逐机制全规范
## 一、核心概述
kubelet持续监控节点内存、磁盘、PID三类资源水位，当资源占用超过阈值时给节点打上 `MemoryPressure/DiskPressure/PIDPressure=True` 标记；
触发压力后两大行为：1. 停止新镜像拉取；2. 根据QoS优先级驱逐低价值Pod释放资源，防止节点内核OOM宕机。
前置依赖：01-node-basics.md、06-kubelet-runtime.md；关联：05-node-troubleshooting.md、07-scheduling-control.md

## 二、四类压力状态判定标准
1. **MemoryPressure**
节点可用内存低于驱逐阈值，kubelet主动驱逐Pod释放内存，避免系统内核杀死kubelet/containerd。
2. **DiskPressure**
根分区/镜像存储分区磁盘占用超标，暂停拉取镜像、清理闲置镜像、驱逐占用大量磁盘的Pod。
3. **PIDPressure**
系统进程总数接近内核pid_max上限，无法新建容器进程，触发驱逐释放PID资源。
4. **Ready=False（联动压力）**
任意压力标记为True且持续超时，节点Ready状态变为False，调度器不再调度新Pod。

## 三、驱逐配置核心字段（/var/lib/kubelet/config.yaml）
### 3.1 硬驱逐阈值 evictionHard（生产强制配置，触及立刻驱逐）
```yaml
evictionHard:
  memory.available: "100Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
```
- memory.available：节点剩余内存下限
- nodefs：宿主机根分区/var/lib/kubelet分区
- imagefs：containerd镜像存储分区/var/lib/containerd
- nodefs.inodesFree：inode耗尽防护，日志/小文件密集业务必配

### 3.2 软驱逐阈值 evictionSoft（缓冲告警，预留处理窗口）
```yaml
evictionSoft:
  memory.available: "200Mi"
  nodefs.available: "15%"
evictionSoftGracePeriod:
  memory.available: "3m"
  nodefs.available: "5m"
evictionSoftMinGracePeriod: 30s
```
到达软阈值后不会立刻驱逐，等待宽限期；宽限期内资源回落则取消驱逐，用于告警人工介入。

### 3.3 驱逐监控扫描周期
```yaml
evictionMonitoringPeriod: 10s
```
kubelet每10秒采集一次资源指标，对比阈值判断是否触发压力。

### 3.4 镜像垃圾回收GC阈值
```yaml
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
```
镜像分区占用达到85%自动清理闲置镜像，降至80%停止回收，缓解DiskPressure。

## 四、Pod驱逐优先级规则（固定排序，从先到后）
kubelet驱逐Pod遵循固定优先级，同优先级下消耗资源越多越先被驱逐：
1. QoS级别 BestEffort（无request/limit）最先驱逐
2. QoS级别 Burstable（request<limit）次之
3. QoS级别 Guaranteed（request=limit）最后驱逐，极少被驱逐

同QoS内排序规则：
1. 容器实际内存/磁盘占用超过request的Pod优先驱逐
2. 副本数多、无核心业务标识的Pod优先驱逐
3. 运行时长更短的Pod优先驱逐

## 五、三种压力场景排查与处理方案
### 5.1 MemoryPressure 内存压力
#### 现象
节点状态 MemoryPressure=True，Events大量 `Evicted pod` 事件，Pod频繁重建。
#### 排查命令
```bash
# 节点侧查看内存占用
free -h
# 查看Pod内存分配与占用
kubectl describe node $NODE_NAME | grep -A20 "Allocated resources"
# 查看被驱逐Pod记录
kubectl get events --field-selector involvedObject.name=$NODE_NAME | grep Evicted
# 宿主机进程内存占用
htop
```
#### 修复手段
1. 临时：扩容节点内存、缩容低优先级Pod、删除闲置BestEffort测试Pod
2. 中期：给所有业务Pod配置合理memory request，避免无限制占用内存
3. 长期：调高evictionHard内存阈值、拆分高内存业务至高内存节点（07-scheduling-control.md标签隔离）

### 5.2 DiskPressure 磁盘压力（线上最高发故障）
#### 常见根因
1. 容器日志未轮转，/var/log/containers 持续膨胀
2. 大量废弃镜像、停止容器堆积占用/var/lib/containerd
3. 业务Pod大量写入emptyDir本地临时存储
4. 日志组件无滚动策略打满根分区inode
#### 排查命令
```bash
# 全局磁盘使用率
df -h
# 镜像存储占用
du -sh /var/lib/containerd
# 容器日志总大小
du -sh /var/log/containers
# 查看inode消耗
df -i
# 清理运行时垃圾
crictl rm $(crictl ps -a -q)
crictl images prune
# 截断超大日志
truncate -s 0 /var/log/containers/*.log
```
#### 永久优化
1. containerd开启日志轮转（06-kubelet-runtime.md）
2. emptyDir临时存储限制sizeLimit
3. 镜像目录独立SSD分区挂载，与系统盘分离
4. 调高imagefs驱逐阈值，定时自动GC镜像

### 5.3 PIDPressure 进程压力
#### 现象
应用创建大量短连接/线程，系统进程数耗尽，新建容器报错fork failed。
#### 排查与修复
```bash
# 当前进程总量
ps aux | wc -l
# 内核最大进程限制
cat /proc/sys/kernel/pid_max
# 临时调高上限
echo 4194304 > /proc/sys/kernel/pid_max
# 永久配置sysctl.conf
echo "kernel.pid_max=4194304" >> /etc/sysctl.conf
sysctl -p
```
业务侧：给容器设置pids limit，限制单Pod最大进程数。

## 六、驱逐事件完整排错流程
1. 控制平面查看节点压力标记：`kubectl get node $NODE_NAME -o yaml`
2. 检索节点驱逐事件，确认被驱逐Pod名称、命名空间：`kubectl get events --sort-by=.lastTimestamp`
3. 登录节点核查对应资源磁盘/内存/PID占用
4. 区分临时突增（流量峰值）与长期配置缺陷（无request、日志未轮转）
5. 临时清理资源解除Pressure标记
6. 修改kubelet驱逐阈值/业务Pod资源规格完成根治

## 七、生产巡检标准化清单
1. 所有节点无 Memory/Disk/PIDPressure 标记
2. kubelet evictionHard/evictionSoft阈值已按业务规模配置
3. 容器日志轮转生效，无单文件GB级日志
4. 镜像GC高低阈值配置完成，闲置镜像自动清理
5. 业务Pod全部配置CPU/Memory request，杜绝BestEffort无限制占用
6. 高并发业务节点调高pid_max内核参数
7. 监控告警对接节点Pressure状态、Pod Evict事件

## 八、关联文档跳转
- kubelet与containerd配置调优：06-kubelet-runtime.md
- 节点故障整体排查：05-node-troubleshooting.md
- 节点调度隔离、业务资源分区：07-scheduling-control.md
- 节点排空维护操作：03-node-drain.md
- 线上故障应急处理手册：10-runbooks.md