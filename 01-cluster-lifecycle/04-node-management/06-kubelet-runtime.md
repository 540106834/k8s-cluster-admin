# 03‑worker‑node‑management/06‑kubelet‑runtime.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/06‑kubelet‑runtime.md`
- 前置文档：`00‑overview.md`、`01‑node‑basics.md`、`05‑node‑troubleshooting.md`、`08‑resource‑pressure.md`
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5，Lease心跳、PLEG机制、systemd cgroup驱动，Ubuntu‑22.04，离线内网环境。
- 适用环境：DEV / FAT / UAT / PROD
- 文档内容：kubelet整体工作原理、配置文件解析、PLEG核心机制、容器镜像GC策略、探针执行逻辑、kubelet‑CRI交互、kubelet性能调优、日志配置、常见报错、生产参数最佳配置。

## 二、kubelet整体工作原理
### 2.1 kubelet核心职责
1. 定期向apiserver获取本节点Pod清单；
2. 通过CRI接口调用containerd创建sandbox和业务容器；
3. 执行 startupProbe、livenessProbe、readinessProbe；探针失败按照策略重启容器；
4. 运行PLEG(Pod Lifecycle Event Generator)监听容器状态变化；上报Pod状态给apiserver；
5. 每10s更新Lease资源维持节点心跳；上报节点4种状态（Ready、MemoryPressure、DiskPressure、PIDPressure）；
6. 判断系统资源压力，按照QoS优先级驱逐Pod；
7. 执行镜像垃圾回收、容器清理；管理本地secret/configmap。

### 2.2 kubelet配置文件加载顺序
1. 启动参数：`/var/lib/kubelet/config.yaml`（核心配置文件）；
2. kubelet启动参数文件：`/var/lib/kubelet/kubeadm‑flags.env`，由kubeadm生成；
3. 动态配置（可选）：kubelet‑config ConfigMap，开启动态配置后可以不用重启kubelet生效配置；
4. systemd启动单元：`/lib/systemd/system/kubelet.service`，只设置exec启动命令。

> 生产环境：统一使用静态配置文件，不开启动态配置避免配置漂移。

### 2.3 kubelet与CRI交互流程
1. kubelet通过unix‑socket `/run/containerd/containerd.sock` 和 containerd通信；
2. 流程：kubelet下发CreatePodSandbox → 创建pause容器 → 创建业务容器；
3. containerd再调用runc启动容器进程；
4. kubelet通过CRI接口获取容器PID、状态、资源占用。

## 三、kubelet核心组件‑PLEG（重点）
### 3.1 PLEG工作机制
1. PLEG周期性读取containerd容器状态，生成Pod生命周期事件（启动、退出、删除）；
2. 默认遍历间隔1s；正常PLEG relist间隔应当小于500ms；
3. 当磁盘IO压力过大、容器数量过多时，`PLEG relist interval >1s`；
4. PLEG延迟过高会引发连锁问题：
   - Pod状态上报延迟；探针执行滞后；
   - kubelet工作队列堆积；严重会导致节点NotReady。

### 3.2 造成PLEG延迟过高的原因（生产高频）
1. 磁盘iowait很高（磁盘性能不足，SSD故障，大量日志写入）；
2. 节点运行Pod数量过多（几百个容器）；
3. inotify资源不足；
4. containerd版本BUG（旧版本问题多，生产锁定 containerd‑2.1.5）。
### 优化方案
1. 底层更换高速SSD存储；
2. 拆分Pod分散到更多节点，减少单节点容器数量；
3. 调高内核inotify参数：
    ```bash
    fs.inotify.max_user_watches=524288
    fs.inotify.max_user_instances=8192
    ```
4. 升级containerd‑2.1.5稳定版。

## 四、kubelet镜像GC（垃圾回收机制）
### 4.1 GC触发条件（两个条件任一满足就执行）
```yaml
imageGCHighThresholdPercent: 85 #磁盘使用率达到85%触发GC
imageGCLowThresholdPercent: 80  #GC之后降到80%停止清理
```
1. 磁盘占用 ≥85%，自动清理镜像；
2. 镜像清理顺序：先删除未使用镜像，再删除旧版本镜像。

### 4.2 容器GC
```yaml
minimumAge: 0
maxPerPodContainer: 1
maxContainers: 100
```
- 每个Pod最多保留1个停止后的容器；整个节点最多保留100个停止容器；多余的停止容器被自动清理。

### 生产注意事项
1. kubelet GC只清理镜像和停止容器；不会清理宿主机日志文件；`/var/log/containers`日志堆积会造成Disk‑Pressure；
2. 生产配合log‑rotate或者filebeat轮转容器日志。

## 五、资源压力驱逐配置（和08‑resource‑pressure.md配套）
kubelet配置文件中压力阈值（生产默认值）
```yaml
evictionHard:
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%
  imagefs.available: 15%
  imagefs.inodesFree: 5%
evictionSoft: #软驱逐，配合宽限期eviction‑soft‑grace‑period
  memory.available: 200Mi
```
1. 达到evictionHard阈值立刻触发驱逐；
2. 驱逐顺序严格按照QoS：Best‑Effort > Burstable > Guaranteed；
3. 驱逐完成后节点标记MemoryPressure / Disk‑Pressure。

## 六、探针（Probe）执行逻辑（kubelet负责执行）
kubelet负责执行三种探针：
1. startupProbe：启动探针，启动期间关闭liveness探针；解决应用启动慢问题；
2. livenessProbe：存活探针，失败则删除Pod，控制器重建；
3. readinessProbe：就绪探针，失败会把Pod从Service的Endpoint剔除；流量不再转发到该Pod。
> 探针支持：exec、httpGet、tcpSocket、grpc；探测请求由kubelet发起。

## 七、kubelet‑config.yaml 生产标准配置示例（精简核心字段）
```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# 1.基础配置
rootDirectory: /var/lib/kubelet
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook
# 2.cgroup驱动，生产必须为systemd
cgroupDriver: systemd
# 3.资源驱逐配置
evictionHard:
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%
  imagefs.available: 15%
#4.镜像GC配置
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
#5.Pod最大数量
maxPods: 250
#6.Lease续约配置
nodeLeaseDurationSeconds: 40
#7.PLEG刷新周期
podPLEGRelistPeriod: 1s
#8.日志配置
containerLogMaxSize: 50Mi
containerLogMaxFiles: 5
```
> 配置修改后执行：`systemctl restart kubelet`生效。

## 八、kubelet日志查看方式
### 8.1 systemd日志查看（主流）
```bash
#实时日志
journalctl -u kubelet -f
#查看最近1000行
journalctl -u kubelet -n 1000
#只看错误日志
journalctl -u kubelet | grep -i error
#导出日志用于故障分析
journalctl -u kubelet > kubelet-$(date +%Y%m%d).log
```
### 8.2 日志轮转配置
kubelet配置：每个容器日志文件最大50Mi，保留5份；超出自动切割；
容器日志目录：`/var/log/containers`，由containerd输出日志。

## 九、高频故障问题分析
### 问题1：kubelet频繁重启
1. 防火墙阻断6443端口，kubelet无法连接apiserver；
2. chronyd时间偏差过大，Lease续约失败；
3. `/var/lib/kubelet/config.yaml`权限不是600；
4. containerd服务异常，crictl超时；
5. 内核OOM‑kill把kubelet进程杀掉（dmesg查看）。

### 问题2：kubelet上报节点NotReady
1. Disk‑Pressure、Memory‑Pressure开启；
2. PLEG延迟过高；
3. containerd挂掉，CRI通信失败。

### 问题3：kubelet日志大量报错：too many open files
修改systemd配置文件：`/lib/systemd/system/kubelet.service`
```ini
[Service]
LimitNOFILE=65535
```
执行：
```bash
systemctl daemon-reload
systemctl restart kubelet
```

### 问题4：kubelet‑config.yaml修改不生效
1. 修改配置后必须重启kubelet；
2. 确认kubeadm‑flags.env没有覆盖参数。

### 问题5：镜像GC不执行
1. 磁盘使用率未达到85%阈值；
2. inodes耗尽优先触发Pressure，GC被阻塞。

## 十、生产环境性能调优清单
1. cgroup‑driver固定为systemd，禁止cgroupfs；
2. 调高系统inotify、nofile内核参数；
3. maxPods=250控制单节点Pod数量，避免PLEG延迟；
4. containerd版本固定为2.1.5；
5. 磁盘选用SSD，iowait指标纳入Prometheus告警；
6. kubelet开启日志轮转，限制日志文件大小；
7. node‑exporter监控PLEG延迟，PLEG>800ms触发告警。

## 十一、DEV / FAT / UAT / PROD差异化标准
1. DEV：无需严格调优，maxPods可以设置更大；日志不做严格限制；
2. FAT：内核参数对齐生产；containerd版本统一2.1.5；PLEG超过1s人工排查；
3. UAT：复用生产kubelet配置；禁止白天重启kubelet；
4. PROD（强制约束）
    1. cgroup‑driver必须为systemd，配置文件权限600；
    2. PLEG relist间隔＞800ms触发告警；
    3. kubelet重启操作仅凌晨业务低峰窗口执行；
    4. 定期检查容器日志目录，避免日志堆积触发DiskPressure；
    5. 禁止随意修改evictionHard驱逐阈值，修改必须走工单审批。

## 十二、常用命令汇总
```bash
#查看kubelet配置
cat /var/lib/kubelet/config.yaml

#查看kubelet运行状态
systemctl status kubelet

#查看kubelet实时日志
journalctl -u kubelet -f

#重启kubelet
systemctl restart kubelet

#查看PLEG延迟（在kubelet日志中查看）
journalctl -u kubelet | grep "PLEG relist interval"

#查看CRI连通性
crictl info
```

## 十三、关联文档
1. `01‑node‑basics.md`：Lease续约机制；
2. `08‑resource‑pressure.md`：驱逐机制、QoS等级；
3. `05‑node‑troubleshooting.md`：节点Not‑Ready排障；
4. `09‑node‑hardening.md`：系统内核参数加固；
5. `07‑monitoring‑and‑troubleshooting`：kubelet指标与Prometheus告警配置。