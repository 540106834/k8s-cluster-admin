# 03‑worker‑node‑management/01‑node‑basics.md

## 一、文档基础信息

- 文件路径：`03‑worker‑node‑management/01‑node‑basics.md`
- 前置文档：`03‑worker‑node‑management/00‑overview.md`
- 集群基准：Kubernetes‑1.32.13，Lease模式心跳、containerd‑2.1.5、Calico‑3.30.4、ipvs‑kube‑proxy、CSI‑node，Ubuntu‑22.04。
- 适用环境：DEV / FAT / UAT / PROD
- 文档内容：Node资源结构、节点状态含义、Lease心跳查看、标签和污点查看、组件运行状态核查、系统资源查看、基础健康检查命令、节点资源判定标准、日常巡检项。

## 二、Node对象核心组成

### 1. Node结构体核心字段

1. `metadata`
    - name：节点主机名；
    - labels：环境、机房、硬件类型、操作系统；
    - annotations：kubelet版本、容器运行时版本、内核版本；
2. `spec`
    - `podCIDR`：Pod网段；
    - `unschedulable`：是否禁止调度；
    - `taints`：污点配置；
3. `status`（最重要）
    - `conditions`：节点健康状态数组（Ready、MemoryPressure、DiskPressure、PIDPressure）；
    - `allocatable`：节点可分配CPU、内存、Pod数量；
    - `capacity`：硬件总资源；
    - `nodeInfo`：操作系统、内核版本、kubelet版本、CRI版本；
    - `images`：节点本地缓存镜像列表。

### 2. status‑Conditions四个核心状态（kubelet上报给apiserver）

| Condition字段        | 含义       | 生产判定标准                                 |
| ------------------ | -------- | -------------------------------------- |
| Ready              | 节点是否正常就绪 | True：kubelet正常续约Lease；False：节点NotReady |
| MemoryPressure     | 内存压力     | True：节点可用内存不足，kubelet触发Pod驱逐           |
| DiskPressure       | 磁盘压力     | True：磁盘空间不足或inode耗尽，kubelet清理镜像、驱逐Pod  |
| PIDPressure        | 进程压力     | True：系统PID资源不足，无法创建新进程或Pod             |
| NetworkUnavailable | 网络不可用状态  | True：节点网络未正常配置，通常与CNI插件异常、网络初始化失败有关    |



> 只有四个压力条件全部为false并且Ready=true，节点才可以正常调度Pod。

### 3. Lease资源（kube‑system命名空间）

kubelet每10s更新对应节点的Lease资源；  
node‑controller读取Lease判断节点存活；  
默认 `pod‑eviction‑timeout=5m`，超过5分钟未续约则判定节点宕机，开始在其他节点重建Pod。

| 参数                            | 组件                      | 默认值 | 作用                   |
| ----------------------------- | ----------------------- | --- | -------------------- |
| `--lease-renew-interval`      | kubelet                 | 10s | kubelet 更新 Lease 的周期 |
| `--node-monitor-grace-period` | kube-controller-manager | 40s | 多久没收到心跳认为 Node 异常    |
| `--pod-eviction-timeout`      | kube-controller-manager | 5m  | Node 异常后多久开始驱逐 Pod   |


## 三、基础查看命令（生产日常高频）

### 3.1 基础概览

```bash
# 查看节点简短状态
kubectl get nodes

# 查看节点详细信息（labels、taints、conditions、allocatable）
kubectl describe node k8s-node-192-168-11-163

# 只查看节点标签
kubectl get node k8s-node-192-168-11-163 --show-labels

# 查看污点
kubectl describe node k8s-node-192-168-11-163 | grep -A 10 Taints

# 查看Lease续约情况
kubectl get lease -n kube-system
kubectl get lease k8s-node-192-168-11-163 -n kube-system -o yaml

root@k8s-manager-192-168-11-6:~# kubectl get lease -A
NAMESPACE         NAME                                   HOLDER                                                                      AGE
kube-node-lease   k8s-master-192-168-11-161              k8s-master-192-168-11-161                                                   9d
kube-node-lease   k8s-node-192-168-11-162                k8s-node-192-168-11-162                                                     9d
kube-node-lease   k8s-node-192-168-11-163                k8s-node-192-168-11-163                                                     9d
kube-node-lease   k8s-node-192-168-11-164                k8s-node-192-168-11-164                                                     2d5h
kube-system       apiserver-avva7joqpn7f67g4ayhl4ogvt4   apiserver-avva7joqpn7f67g4ayhl4ogvt4_05c100cb-7dd9-4a66-bde6-521018081eee   9d
kube-system       kube-controller-manager                k8s-master-192-168-11-161_77680637-db79-4699-b6b9-3ef9c7da6db7              9d
kube-system       kube-scheduler                         k8s-master-192-168-11-161_28a280cc-cc9e-4244-af01-2669285ab834              9d

```

### 3.2 资源容量查看

```bash
# 查看capacity和allocatable
kubectl get node k8s-node-192-168-11-163 -o jsonpath='{.status.capacity}{"\n"}{.status.allocatable}' | jq

# 查看节点上正在运行的Pod
kubectl get pods --field-selector spec.nodeName=k8s-node-192-168-11-163 -A

# 查看节点缓存镜像
kubectl get node k8s-node-192-168-11-163 -o json | jq .status.images[].names
```

### 3.3 节点操作系统层面登录查看（登录对应主机执行）

```bash
# 内核版本
uname -r
# 系统版本
cat /etc/os-release
# CPU内存
free -h
lscpu
# 磁盘使用率 & inode
df -h
df -i
# 查看kubelet状态
systemctl status kubelet
# 查看containerd状态
systemctl status containerd
# 查看kubelet实时日志
journalctl -u kubelet -f
# 查看CRI容器列表
crictl ps -a
# 查看本地镜像
crictl images
```

## 四、节点上必须运行的组件核查清单

### 4.1 systemd组件（主机层面）

1. kubelet：必须active‑running；
2. containerd：必须active‑running；
3. chronyd：时间同步服务，时间偏差超过150ms会导致Lease续约异常。

### 4.2 DaemonSet组件（集群层面）

```bash
# 检查本节点运行的daemonset Pod：calico‑node、csi‑node、node‑exporter、filebeat
kubectl get pods --field-selector spec.nodeName=k8s-node-192-168-11-163 -n kube-system
root@k8s-manager-192-168-11-6:~# kubectl get pods --field-selector spec.nodeName=k8s-node-192-168-11-163 -n kube-system
NAME                             READY   STATUS    RESTARTS   AGE
calico-node-xjtz6                1/1     Running   0          9d
kube-proxy-mh28k                 1/1     Running   0          9d
metrics-server-5654b75cf-228pf   1/1     Running   0          9d

```

必备组件：

1. calico‑node：CNI网络，异常Pod网络不通；
2. csi‑node：存储挂载，PVC无法挂载；
3. kube‑proxy：ipvs规则生成；
4. node‑exporter：监控指标采集；
5. filebeat：日志采集。

## 五、资源水位判定标准（和Prometheus告警阈值统一）

### 5.1 系统资源（node‑exporter指标）

1. CPU
   - 70%～85%：Warning预警；＞85%：Critical严重；
2. 内存
   - 70%～85%：Warning；＞85%触发MemoryPressure，kubelet开始驱逐Pod；
3. 磁盘分区
   - 磁盘使用率80‑85%：Warning；＞85% DiskPressure开启；
   - inode使用率＞80%预警；＞90%高危；
4. 系统进程PID：
   - 进程数超过allocatable pid上限触发 PIDPressure。

### 5.2 kubelet内部指标（kubelet metrics）

1. PLEG Relist Interval >1s 属于异常；正常应当 <500ms；
2. 镜像垃圾回收：磁盘低于阈值自动清理旧镜像；
3. 容器创建延迟：创建sandbox耗时超过1s需要排查。

### 5.3 Pod分配情况

1. 节点实际分配CPU、内存不能超过allocatable资源；
2. 集群按照QoS优先级划分：`Guaranteed > Burstable > Best‑Effort`，资源紧张时优先驱逐最低优先级Pod。

## 六、标准化标签（所有节点统一配置）

### 强制五维标签（生产全部节点必须配置）

```yaml
labels:
  env: prod
  node‑role: worker
  rack: rack‑01
  hardware‑type: physical
  os‑version: ubuntu‑2204
```

- env：环境 dev/fat/uat/prod；
- node‑role：worker/master；
- rack：机房机柜编号；用于节点亲和反亲和调度；
- hardware‑type：physical/vm；区分物理机与虚拟机；
- os‑version：操作系统版本。

### 内置污点（系统自动生成）

1. `node‑kubernetes.io/unschedulable:NoSchedule`：执行cordon自动添加；禁止调度新Pod；
2. 硬件故障污点可手动添加：例如 `node‑kubernetes.io/hardware‑fault:NoSchedule`。

## 七、日常例行检查清单（分为kubectl远程检查和主机登录检查）

### 7.1 远程检查（不需要登录主机，日常每日自动化执行）

1. 确认所有节点 Ready=true；
2. MemoryPressure、DiskPressure、PIDPressure全部为false；
3. Lease续约时间间隔正常，最后更新时间在10‑20s之内；
4. calico‑node、csi‑node、kube‑proxy全部正常Running；
5. 节点标签齐全，无废弃污点；
6. 查看节点Pod状态，不存在大量CrashLoopBackOff。

### 7.2 每周登录节点人工检查

1. 确认kubelet、containerd状态正常；
2. 查看系统内核日志 `dmesg`，查看OOM‑kill、硬件报错；
3. 核查sysctl内核参数是否符合加固文档；
4. 清理废弃镜像：`crictl images | grep <none>`；
5. 核查chronyd时间同步正常。

## 八、DEV/FAT/UAT/PROD差异化标准

1. DEV：标签可以随意，资源水位宽松，磁盘90%以内都不用处理；
2. FAT：强制基础标签；资源告警仅消息通知；inode超过85%再处理；
3. UAT：标签体系对齐生产，资源阈值完全复用生产标准；每周登录节点检查；
4. PROD（强制约束）
    1. 所有节点强制配置五维标签；禁止缺失标签；
    2. 只要出现Pressure条件立即排查处理；绝不允许节点长期处于压力状态；
    3. Lease续约异常立即排查网络、防火墙、时间同步；
    4. 每周人工登录节点查看内核日志，清理无用镜像；
    5. 节点状态异常，优先查看kubelet日志，然后排查内核报错。

## 九、常见问题快速判断

### 问题1：节点状态NotReady

优先排查顺序：

1. 查看Lease是否按时更新；时间同步是否正常；
2. systemctl status kubelet；journalctl -u kubelet查看报错；
3. containerd是否运行正常；
4. 磁盘inode耗尽、内存过高触发压力条件。

### 问题2：节点有DiskPressure

1. 执行`df -i`查看inode是否耗尽；
2. kubelet自动GC镜像，如果GC后依然很高，人工清理大文件。

### 问题3：PLEG延迟过高Pod Lifecycle Event Generator

1. 磁盘IO过高；
2. 容器数量太多；
3. containerd卡顿，必要时重启containerd。

## 十、生产最佳实践

1. 日常优先使用kubectl远程查看节点信息，减少登录宿主机操作；
2. 节点标签提前规划，为后续调度策略、资源统计做铺垫；
3. 依靠Lease状态判断节点健康，不要只依赖节点Ready字段；
4. node‑exporter监控指标全部接入Prometheus，USE模型配置告警；
5. 定期清理无用镜像、废弃容器，避免磁盘打满触发驱逐。

## 十一、关联文档

1. `04‑node‑lifecycle.md`：节点生命周期；
2. `08‑resource‑pressure.md`：kubelet驱逐机制详细原理；
3. `06‑kubelet‑runtime.md`：kubelet‑PLEG、GC镜像原理；
4. `05‑node‑troubleshooting.md`：节点NotReady完整排障步骤；
5. `07‑monitoring‑and‑troubleshooting`：node‑exporter指标、告警阈值配置文档。