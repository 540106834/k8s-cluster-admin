# 01‑cluster‑lifecycle/04‑node‑management/troubleshooting.md
## 一、文档基础信息
- 文件路径：`01‑cluster‑lifecycle/04‑node‑management/troubleshooting.md`
- 前置文档：`node‑lifecycle.md`、`maintenance.md`、`scheduling.md`
- 集群版本：Kubernetes‑1.32.13、containerd‑2.1.5、Lease心跳、Calico‑3.30.4、CSI‑node、Ubuntu‑22.04。
- 文档定位：统一排障方法论，梳理高频故障：Node Not‑Ready、资源压力、kubelet异常、containerd故障、PLEG延迟过高、drain排空失败、节点宕机；给出排查步骤、原因判定、临时恢复、根治方案、事后复盘；区分P1紧急故障和P2普通故障。
- 故障分级：
  - P1：Node Not‑Ready、inode耗尽、内存压力导致大量Pod驱逐、containerd卡死（7×24小时响应）；
  - P2：PLEG偏高、drain卡住、偶尔驱逐Pod、内核少量警告（工作时段处理）。
- 通用排查顺序（严格遵守）：
  1. Master端远程查看Node Conditions、Lease、Events；
  2. 登录故障节点依次排查：kubelet → containerd → 磁盘/inode → 内核dmesg → CNI → CSI；
  3. 问题恢复；核查监控指标；
  4. 根因分析，优化告警。

## 二、场景1：Node状态 Not‑Ready（最高频P1故障）
### 2.1 master端排查
```bash
# 查看4种压力条件
kubectl describe node node‑10‑0‑10‑21 | grep -E "Ready|MemoryPressure|DiskPressure|PIDPressure"
# 查看Lease续约状态
kubectl get lease node‑10‑0‑10‑21 -n kube-system -o yaml
# 查看集群事件
kubectl get events -n kube-system | grep -i warning
```
判断要点：
1. `lastRenewTime`距离当前超过20s → kubelet停止上报心跳，问题在节点侧；
2. DiskPressure/MemoryPressure/PIDPressure为true → kubelet主动置节点NotReady；

### 2.2 登录节点逐层排查
#### 步骤1：检查kubelet运行状态与日志
```bash
systemctl status kubelet
journalctl -u kubelet -o short -f
```
常见报错：
1. kubelet无法连接apiserver：
   - 防火墙阻断6443、10250端口；
   - chronyd时间偏差＞150ms，Lease续约失败；
   - apiserver证书过期；
2. `/var/lib/kubelet/config.yaml`权限不是600；
3. PLEG relist interval＞1000ms，磁盘IO压力过大；
4. Admission‑Webhook超时导致kubelet请求阻塞。

#### 步骤2：检查containerd状态
```bash
systemctl status containerd
journalctl -u containerd
crictl info
```
高频问题：
1. containerd卡死，`crictl info`超时；
2. cgroup‑driver配置为`cgroupfs`，和kubelet的systemd不匹配，节点直接NotReady；
3. harbor镜像解析失败、inotify资源不足报错。

#### 步骤3：操作系统层面检查
```bash
df -h
df -i
dmesg -T
chronyc tracking
ufw status verbose
```
- inode耗尽、磁盘占满触发DiskPressure；
- `dmesg`出现`Out‑of‑Memory: Killed process`：内核OOM杀死kubelet或者containerd；
- 防火墙规则改动拦截集群内部通信。

#### 步骤4：检查DaemonSet组件
```bash
kubectl get pods --field-selector spec.nodeName=node‑10‑0‑10‑21 -n kube-system
```
calico‑node CrashLoopBackOff、IP冲突，网络未就绪，节点NotReady；csi‑node异常不会影响节点Ready，但PVC无法挂载。

### 2.3 恢复方案
1. inode耗尽：清理无用镜像`crictl rmi $(crictl images | grep "<none>" | awk '{print $3}')`、清理`/var/log/containers`过期日志；
2. 时间不同步：修复chronyd服务；
3. containerd异常：`systemctl restart containerd`；
4. kubelet配置问题：修正文件权限600后重启kubelet；
> 重启kubelet不会杀掉正在运行的Pod，只会停止上报状态。

### 2.4 根治方案
1. 开启kubelet日志轮转 `containerLogMaxSize:50Mi，containerLogMaxFiles:5`；
2. 调高inotify内核参数；
3. containerd固定使用2.1.5稳定版本；
4. Prometheus配置告警：磁盘使用率＞80%、inode＞80%提前预警。

## 三、场景2：Disk‑Pressure磁盘、inode耗尽（P1故障）
### 3.1 排查命令
```bash
df -h
df -i
du -sh /var/log/containers
journalctl -u kubelet | grep garbage
```
产生原因：
1. inode耗尽：容器产生大量小日志文件；
2. 磁盘空间占满：core‑dump文件、过期备份、容器日志堆积、废弃镜像过多。

### 3.2 临时处理
1. 清理悬空镜像；
2. 清理容器日志和core文件；
3. 临时扩容磁盘分区。

### 3.3 根治方案
1. kubelet开启日志轮转；
2. 定时清理废弃镜像脚本；
3. 日志数据迁移至PVC，宿主机不存放业务日志。

## 四、场景3：Memory‑Pressure内存压力，Pod被kubelet驱逐（P1故障）
### 4.1 排查命令
```bash
# 查看被驱逐事件
kubectl get events -A | grep Evicted
# 节点查看内存占用
top
crictl stats
# 区分kubelet驱逐和内核OOM‑kill
dmesg -T | grep -i "Out‑of‑Memory"
```
驱逐逻辑：
- kubelet驱逐：按照QoS优先级 `Best‑Effort > Burstable > Guaranteed`；事件显示Evicted；
- 内核OOM：操作系统直接杀死容器进程，Pod进入CrashLoopBackOff。

### 4.2 临时恢复
1. 缩减非核心业务副本；
2. 临时调高Pod内存limits；
3. 扩容节点内存。

### 4.3 根治方案
1. 禁止使用Best‑Effort；中间件配置为Guaranteed；普通微服务配置合理requests/limits；
2. 业务代码修复内存泄漏；
3. Prometheus监控Pod实际内存使用率，超过limits‑80%提前告警。

## 五、场景4：PLEG‑Relist间隔过高（P2隐患，后期极易引发NotReady）
### 5.1 现象
kubelet日志持续输出：`PLEG relist interval >1000ms`，正常值＜500ms。
### 5.2 根因
1. 磁盘iowait过高（SSD性能不足）；
2. 单节点Pod数量过多；
3. fs.inotify参数配置偏低；
4. containerd版本bug。

### 5.3 处理方案
1. 清理磁盘，降低iowait；
2. 将部分Pod调度到其他节点；
3. 修改sysctl：
```bash
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
```
4. 升级containerd‑2.1.5版本。
### 5.4 监控配置：PLEG＞800ms触发告警。

## 六、场景5：containerd异常，crictl info超时（P1故障）
### 6.1 排查步骤
```bash
systemctl status containerd
journalctl -u containerd
ls /run/containerd/containerd.sock
```
问题清单：
1. containerd进程卡死；
2. config.toml里面cgroup‑driver配置错误；
3. harbor DNS解析失败；
4. inotify耗尽。
### 6.2 恢复：`systemctl restart containerd`。
### 6.3 根治：锁定containerd版本、提前配置内核参数。

## 七、场景6：执行kubectl drain排空失败（P2故障）
### 6.1 排查命令
```bash
kubectl drain node‑xxx --ignore-daemonsets --delete-emptydir-data --dry-run=client
kubectl get events -n prod
```
失败原因：
1. PDB约束，驱逐之后副本小于minAvailable；
2. 存在裸Pod（无控制器管理）；
3. 缺少`--delete‑emptydir‑data`参数；
4. 新Pod在其它节点启动失败（镜像拉取失败、PVC挂载失败、准入策略拒绝）。
### 6.2 解决方案
1. PDB问题：优先扩容副本；FAT/UAT可临时修改maxUnavailable；PROD走工单审批；
2. 裸Pod：确认业务下线后手动删除Pod，生产禁止使用`--force`；
3. 新Pod启动失败：修复镜像、PVC问题之后继续排空。
### 6.3 最佳实践：生产分批排空节点。

## 八、场景7：节点宕机（硬件故障、内核panic，P1故障）
### 7.1 排查
```bash
kubectl get lease node‑10‑0‑10‑21 -n kube-system -o yaml
```
- Lease超时5分钟后Node‑Controller才会在其它节点重建Pod；
- 登录服务器控制台查看硬件日志、`/var/log/kern.log`查看内核panic堆栈。

### 7.2 两种处理方案
1. 服务器可以重启：启动服务器；kubelet重新续约Lease，原有旧Pod会被控制器清理；之后执行`uncordon`；
2. 硬件彻底损坏：确认Pod已经重建完成，执行`kubectl delete node node‑xxx`，清理CSI‑node残留配置、Prometheus配置。

### 7.3 根治：定期做节点宕机演练，验证Pod跨节点重建。

## 九、场景8：cordon之后Pod依旧调度上来（P2）
1. 原因：Pod YAML写死`spec.nodeName`，绕过调度器，污点规则失效；
2. 解决：删除`spec.nodeName`交由scheduler调度。

## 十、节点运维常用排查命令（整理成可执行清单）
### 1）master端远程执行
```bash
# 查看节点压力条件
kubectl describe node node‑10‑0‑10‑21
# 查看Lease续约时间
kubectl get lease node‑10‑0‑10‑21 -n kube-system -o yaml
# 查看节点所有Pod
kubectl get pods --field-selector spec.nodeName=node‑10‑0‑10‑21 -A
# 查看集群警告事件
kubectl get events -A | grep -E "Evict|Failed|Warning"
# 查看节点污点
kubectl describe node node‑10‑0‑10‑21 | grep -A 10 Taints
```

### 2）登录节点执行
```bash
# kubelet日志
journalctl -u kubelet -f
# containerd日志
journalctl -u containerd -f
# 磁盘和inode
df -h
df -i
# 查看内核报错
dmesg -T
# CRI命令
crictl ps -a
crictl images
crictl info
# 时间同步状态
chronyc tracking
# 重启服务（故障紧急时执行，优先选凌晨低峰）
systemctl restart containerd
systemctl restart kubelet
```

## 十一、生产环境禁止操作清单（PROD红线）
1. P1故障优先恢复业务，不要长时间深挖根因；问题解决之后再分析；
2. 故障期间禁止同时操作两台及以上节点，防止集群雪崩；
3. drain排空严禁使用`--force`；
4. kubelet、containerd重启尽量放在凌晨业务低峰；紧急故障除外；
5. 禁止随意修改evictionHard驱逐阈值；修改必须提交工单；
6. 问题处理完成后导出kubelet、containerd、内核日志留存用于复盘。

## 十二、事后复盘与预防
1. 故障处理完毕填写故障报告：故障现象、时间线、根因、临时恢复方案、长期根治方案、新增监控告警项；
2. node‑exporter开启USE模型监控：磁盘使用率、inode使用率、内存占用、iowait、PLEG间隔；
3. 定期清理废弃镜像、过期日志；
4. 每季度做节点宕机演练，验证Pod跨节点重建；
5. 同类问题整理进Runbook知识库。

## 十三、关联文档
1. `node‑lifecycle.md`：节点生命周期；
2. `maintenance.md`：cordon/drain操作；
3. `scheduling.md`：Pod调度失败排障；
4. `06‑kubelet‑runtime.md`：kubelet配置、PLEG原理；
5. `certificate‑management.md`：证书过期401问题；
6. `10‑troubleshooting.md`：集群部署阶段报错手册。