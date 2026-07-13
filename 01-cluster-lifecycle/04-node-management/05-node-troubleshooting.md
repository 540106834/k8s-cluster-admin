# 03‑worker‑node‑management/05‑node‑troubleshooting.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/05‑node‑troubleshooting.md`
- 前置文档：
  `00‑overview.md`、`01‑node‑basics.md`、`04‑node‑lifecycle.md`、`06‑kubelet‑runtime.md`、`08‑resource‑pressure.md`、`07‑monitoring‑and‑troubleshooting`
- 集群基准：Kubernetes‑1.32.13，Lease心跳、containerd‑2.1.5、Calico‑3.30.4、CSI‑node、ipvs‑kube‑proxy、Ubuntu‑22.04、内网环境。
- 适用环境：DEV / FAT / UAT / PROD。
- 文档内容：统一排障方法论、Node Not‑Ready分层排查流程、kubelet故障、containerd异常、磁盘压力、inode耗尽、网络问题、内核OOM、CSI‑node故障、排障命令清单、故障分级处置。

## 二、节点故障通用排障思路（固定四步法）
1. **步骤1：确认故障范围**
    - 单节点异常：问题集中在当前主机：kubelet、containerd、磁盘、内核、防火墙；
    - 全部节点NotReady：问题在控制平面（apiserver、etcd、防火墙、证书过期）。
2. **步骤2：查看上层状态（远程操作，优先执行，不用登录节点）**
    1. 查看Node Conditions：Ready、MemoryPressure、DiskPressure、PIDPressure；
    2. 查看Lease续约记录，判断kubelet是否正常上报心跳；
    3. 查看node‑controller事件 `kubectl get events -n kube-system`。
3. **步骤3：登录节点排查组件**
    按照优先级：`kubelet → containerd → 系统资源 → 内核日志 → CNI → CSI`。
4. **步骤4：定位根因并修复，最后验证**
    修复后检查Lease续约、DaemonSet组件、监控指标、业务Pod运行状态。

## 三、场景1：Node状态 Not‑Ready（最高频故障）
### 3.1 第一层排查：查看Node Conditions（控制平面执行）
```bash
kubectl describe node node‑10‑0‑10‑21
```
4种Pressure任意一项为true都会导致NotReady：
1. `DiskPressure=true`：磁盘使用率或者inode耗尽，kubelet开启镜像垃圾回收；严重时节点NotReady；
2. `MemoryPressure=true`：内存不足，kubelet开始驱逐低优先级Pod；
3. `PIDPressure=true`：系统进程数量达到上限；
4. Ready=False：kubelet无法续约Lease。

查看Lease续约状态：
```bash
kubectl get lease node‑10‑0‑10‑21 -n kube-system -o yaml
```
- lastRenewTime距离当前超过20s：kubelet停止上报心跳，登录节点排查kubelet。

### 3.2 第二层：登录节点检查kubelet运行状态
```bash
systemctl status kubelet
# 实时查看kubelet日志
journalctl -u kubelet -o short -f
```
kubelet常见报错：
1. **连接apiserver失败**
   - 防火墙拦截6443、10250端口；
   - 时间偏差过大（chronyd异常，时差＞150ms，Lease续约失败）；
   - apiserver证书过期；
2. **kubelet‑config.yaml配置异常**
   - `/var/lib/kubelet/config.yaml` 文件损坏；权限不是600；
3. **PLEG Relist间隔过高**
   - 日志出现 `PLEG relist interval > 1s`；根因：磁盘IO压力过大或者容器数量过多；
4. **准入Webhook超时**：apiserver准入Webhook不可用导致kubelet请求阻塞。

### 3.3 第三层：检查containerd运行状态
```bash
systemctl status containerd
journalctl -u containerd
crictl info
```
containerd问题：
1. containerd崩溃：sandbox创建失败、镜像拉取失败；
2. cgroup驱动不一致：kubelet要求systemd，containerd配置成cgroupfs；节点直接NotReady；
3. 镜像GC频繁报错，磁盘inode耗尽。

### 3.4 第四层：操作系统层面问题
```bash
# 磁盘和inode
df -h
df -i
# 内核报错（OOM‑kill、硬件故障）
dmesg -T
# 时间同步状态
chronyc tracking
# 防火墙规则
ufw status verbose
```
高频问题：
1. inode耗尽：日志文件过多、大量容器日志碎片；df‑i查看100%占用；触发DiskPressure；
2. 内核OOM‑kill：系统把kubelet或者containerd进程杀掉；dmesg会显示 `Out‑of‑Memory: Killed process`；
3. 磁盘IO过高：%iowait很高，PLEG延迟飙升；
4. 防火墙规则变动：worker节点出站策略拦截访问apiserver。

### 3.5 第五层：CNI与CSI组件异常
```bash
# 在master查看该节点上DaemonSet Pod状态
kubectl get pods --field-selector spec.nodeName=node‑10‑0‑10‑21 -n kube-system
```
1. calico‑node CrashLoopBackOff：calico配置损坏、IP地址冲突；节点网络未就绪，节点状态NotReady；
2. csi‑node异常：CSI‑node Pod启动失败不影响节点Ready，但是PVC无法挂载。

### 3.6 Not‑Ready 快速修复执行顺序
1. 磁盘inode满：清理容器日志、旧镜像 `crictl images | grep <none>`；
2. 时间不同步：修复chronyd；
3. containerd异常：重启containerd；
4. kubelet异常：修复配置后重启kubelet；
> 重启kubelet不会删除现有Pod，只是停止上报状态，业务Pod继续运行。

## 四、场景2：节点资源压力问题（DiskPressure / MemoryPressure / PIDPressure）
### 4.1 Disk‑Pressure 处理步骤
1. 查看磁盘inode和容量：`df -h && df -i`；
2. kubelet默认自动执行镜像GC，删除未使用镜像；
3. GC之后使用率依然很高：
    - 清理容器日志：`/var/log/containers`；
    - 清理宿主机旧日志、core文件；
    - 清理无用镜像 `crictl rmi <image‑id>`；
4. 长期方案：扩容磁盘或者迁移大文件到PVC。

### 4.2 Memory‑Pressure 处理步骤
1. kubelet按照QoS优先级驱逐Pod：Best‑Effort > Burstable > Guaranteed；
2. 查看被驱逐Pod事件：`kubectl get events -n prod | grep Evicted`；
3. 优化：调高Pod内存limits，缩减非核心Pod副本，或者扩容节点内存。

### 4.3 PID‑Pressure
系统进程数达到节点allocatable PID上限；
1. 排查大量进程Pod；
2. 调整kubelet `pod‑pid‑limit`；或者升级服务器内核。

## 五、场景3：containerd故障细分问题
1. crictl info 超时：containerd卡死；重启containerd；
2. sandbox创建失败：harbor解析失败，dns问题；
3. 镜像拉取超时：网络策略拦截出站、harbor证书问题；
4. containerd日志刷屏：inotify数量不足，修改sysctl `fs.inotify.max_user_instances=8192`。

## 六、场景4：PLEG延迟过高（性能隐患，容易后期引发节点NotReady）
### 现象：kubelet日志里面频繁出现
`PLEG relist interval is high xxx ms`
- 正常：＜500ms；
- ＞1000ms属于异常，严重会导致kubelet卡顿；
### 根因：
1. 磁盘IO瓶颈（最主要）；
2. 节点运行Pod数量过多；
3. containerd版本BUG；
### 解决办法：
1. 清理磁盘降低iowait；
2. 拆分Pod分摊到更多节点；
3. 升级containerd‑2.1.5稳定版本。

## 七、场景5：节点宕机（服务器硬件故障/内核panic）
1. 现象：Lease长时间无法续约，节点状态NotReady；
2. Node‑Controller等待 `pod‑eviction‑timeout（5min）`之后，开始在其他节点重建Pod；
3. 原节点恢复上线之后：kubelet重新续约Lease，但是原来旧Pod会被控制器清理；
4. 排障：查看服务器控制台日志、内核崩溃日志、硬件报错。

## 八、场景6：执行drain排空失败问题（前面文档已有，此处精简排障）
1. drain卡住：PDB minAvailable约束，扩容副本解决；
2. 裸Pod导致drain失败：手动确认业务安全后删除裸Pod；PROD禁止使用`--force`；
3. empty‑dir问题：增加参数`--delete‑emptydir‑data`；
4. 新Pod启动失败导致旧Pod无法删除：查看events排查镜像、准入、PVC问题。

## 九、生产排障执行红线（PROD强制）
1. 排查阶段优先查看日志和events，禁止盲目重启kubelet、containerd；
2. 一级故障（节点宕机、磁盘100%）优先恢复业务，再深挖根因；
3. 重启containerd和kubelet尽量避开业务高峰；
4. 节点故障期间不要批量操作多个节点，防止集群雪崩；
5. 故障解决之后必须查看Prometheus指标确认业务恢复；
6. 严重故障填写事故复盘文档，优化监控告警规则。

## 十、排障命令汇总（可直接复制）
### 1. 远程查询（master节点执行）
```bash
# 查看节点状态与压力条件
kubectl describe node node‑10‑0‑10‑21

# 查看Lease续约时间
kubectl get lease node‑10‑0‑10‑21 -n kube-system -o yaml

# 查看节点上所有Pod
kubectl get pods --field-selector spec.nodeName=node‑10‑0‑10‑21 -A

# 查看事件
kubectl get events -A | grep -E "Evict|Failed|Warning"
```

### 2. 登录节点执行
```bash
# kubelet日志
journalctl -u kubelet -f

# containerd日志
journalctl -u containerd -f

# 磁盘与inode
df -h
df -i

# 内核报错
dmesg -T

# CRI命令
crictl ps -a
crictl images
crictl info

# 时间同步
chronyc tracking

# 重启服务（谨慎）
systemctl restart containerd
systemctl restart kubelet
```

## 十一、DEV/FAT/UAT/PROD差异化标准
1. DEV：故障可以随意重启kubelet和containerd，快速恢复优先；
2. FAT：排查步骤对齐生产；重启服务选择工作时段即可；
3. UAT：禁止白天重启核心组件；故障处理完成简单记录问题；
4. PROD：
    1. 严格按照排障顺序执行，先看events再看日志，禁止盲目重启；
    2. 重启kubelet/containerd选择凌晨低峰窗口；
    3. 节点磁盘使用率达到80%提前处理，不能等到Not‑Ready之后再修复；
    4. 故障处理完毕后复盘，并补充Prometheus告警规则。

## 十二、最佳实践
1. 前置预防：node‑exporter配置USE模型告警，磁盘inode、内存、PLEG延迟提前告警；
2. 平时定期查看`dmesg`内核日志，提前发现硬件隐患；
3. containerd和kubelet使用固定稳定版本（containerd‑2.1.5）；
4. 生产环境定期做节点宕机演练，验证Pod跨节点重建；
5. 节点故障处理完成后，整理问题录入runbook，形成知识库。

## 十三、关联文档
1. `01‑node‑basics.md`：节点状态与Lease机制；
2. `06‑kubelet‑runtime.md`：PLEG原理、kubelet配置、镜像GC；
3. `08‑resource‑pressure.md`：kubelet驱逐原理；
4. `03‑node‑drain.md`：drain排空失败问题；
5. `10‑runbooks.md`：节点宕机完整应急处理步骤；
6. `07‑monitoring‑and‑troubleshooting`：node‑exporter告警配置。