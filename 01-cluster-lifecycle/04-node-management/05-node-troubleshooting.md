# 03-worker-node-management/05-node-troubleshooting.md
## 文档元信息
归属模块：Worker 节点管理
前置依赖：00-overview.md / 01-node-basics.md / 06-kubelet-runtime.md
配套文档：08-resource-pressure.md、10-runbooks.md
适用场景：节点 NotReady、Unknown、资源压力、容器创建失败、节点失联、网络异常、kubelet 崩溃类线上故障排查
定位：集群生产级节点故障标准化排查手册

# 一、故障分级与排查顺序规范
## 1.1 故障分级
1. P0：节点 Unknown / 整节点失联，业务批量驱逐
2. P1：节点 NotReady，存在资源压力标记（Disk/Memory/PID Pressure）
3. P2：节点 Ready 但无法创建Pod、镜像拉取失败、调度异常
4. P3：节点性能抖动、日志打满、内核报错、偶发容器OOM

## 1.2 标准排查流程（固定顺序，禁止颠倒）
1. 控制平面侧：查看 Node 对象状态、事件、污点标签
2. 节点主机连通性：ping/ssh、6443端口连通性
3. 系统基础状态：磁盘、内存、CPU、PID、内核日志
4. 运行时组件：containerd → kubelet 服务状态 & 日志
5. 网络层：CNI、宿主机网桥、DNS、主机防火墙
6. 资源驱逐与阈值：kubelet 驱逐配置、已驱逐Pod记录
7. 内核/硬件：OOM、IO hang、硬件故障、内核panic

# 二、第一步：控制平面排查（无需登录节点）
## 2.1 查看节点整体状态
```bash
kubectl get node $NODE_NAME -o wide
# 输出重点：STATUS、ROLES、AGE、VERSION、INTERNAL-IP、OS-IMAGE
```

## 2.2 完整节点描述（核心故障信息）
```bash
kubectl describe node $NODE_NAME
# 重点查看三块内容
# 1) Status Conditions：Ready/MemoryPressure/DiskPressure/PIDPressure/NetworkUnavailable
# 2) Allocated resources：资源占用是否打满
# 3) Events：节点近1小时所有事件（驱逐、心跳丢失、CNI报错）
```

## 2.3 节点事件单独过滤
```bash
# 只看目标节点事件
kubectl get events --field-selector involvedObject.name=$NODE_NAME --sort-by='.lastTimestamp'
```

## 2.4 检查节点污点/不可调度标记
```bash
kubectl describe node $NODE_NAME | grep -E "Taints|Unschedulable"
# Unschedulable=true：节点被排空锁定，禁止新Pod调度
```

# 三、故障大类1：节点状态 Unknown（P0 最高优先级）
## 3.1 根因判定逻辑
APIServer 超过40s未收到 kubelet 心跳，标记 Unknown；集群自动驱逐该节点所有Pod。
### 常见诱因
1. 节点宕机、重启、内核panic、硬件故障
2. 节点与控制平面网络中断（防火墙、交换机、路由故障）
3. 节点主机时间偏移过大，证书校验失败
4. kubelet 彻底崩溃、持续重启无法上报状态

## 3.2 排查步骤
1. 连通性校验
```bash
# 1. 能否ssh登录节点
ssh $NODE_IP
# 2. 节点能否访问apiserver 6443端口
curl -vk https://$APISERVER_IP:6443/healthz
# 3. 时间同步校验
date; ssh $NODE_IP date
```
2. 节点离线处理预案
- 能登录：查看 kubelet/containerd 日志、系统内核日志
- 无法登录：机房确认服务器电源、网络、硬盘故障；执行节点驱逐 `kubectl drain` 后删除重建节点

## 3.3 恢复操作
节点恢复连通且kubelet正常运行后，状态自动恢复Ready；长期失联节点执行：
```bash
# 安全排空节点
kubectl drain $NODE_NAME --ignore-daemonsets --delete-emptydir-data
# 删除失效Node对象
kubectl delete node $NODE_NAME
# 重新join节点（参考02-node-join.md）
```

# 四、故障大类2：节点 NotReady（P1）
## 4.1 前置判断：查看状态条件
```bash
kubectl get node $NODE_NAME -o jsonpath='{.status.conditions[*].type}{"\n"}{.status.conditions[*].status}'
```
分4种场景逐一排查：

## 场景A：NetworkUnavailable=True
CNI网络插件未就绪，节点网络未初始化
1. 检查集群CNI Pod（calico/flannel/cilium）
```bash
kubectl get pods -n kube-system | grep calico
```
2. 登录节点查看CNI日志
```bash
journalctl -u calico-node -f
```
3. 修复：删除异常CNI Pod、核对节点iptables/nftables是否被业务脚本清空

## 场景B：DiskPressure=True
磁盘占用超出kubelet阈值，暂停拉镜像、驱逐Pod
1. 节点侧磁盘检查
```bash
df -h
# 查看镜像存储分区占用
du -sh /var/lib/containerd
# 清理无效镜像、退出容器
crictl images prune
crictl rm --all
```
2. 临时扩容/清理日志：/var/log、容器日志打满是高频诱因
3. 永久优化：调整kubelet驱逐阈值（08-resource-pressure.md）

## 场景C：MemoryPressure=True
节点可用内存低于阈值，触发内存驱逐
1. 查看节点内存占用
```bash
free -h
# 查看宿主机进程内存占用
top/htop
# 查看集群Pod内存分配占用
kubectl describe node $NODE_NAME | grep -A10 "Allocated resources"
```
2. 处理：下线低优先级Pod、增加节点内存、调整Pod内存request/limit

## 场景D：PIDPressure=True
系统进程数接近 pid_max 上限
```bash
# 当前进程总数
ps aux | wc -l
# 系统最大进程数
cat /proc/sys/kernel/pid_max
# 临时调高
echo 4194304 > /proc/sys/kernel/pid_max
```

## 场景E：仅Ready=False，无任何Pressure标记
核心为 kubelet / containerd 组件异常
### 排查命令（节点内执行）
```bash
# 1. 检查服务运行状态
systemctl status containerd kubelet
# 2. 实时日志
journalctl -u containerd -f --since "10m ago"
journalctl -u kubelet -f --since "10m ago"
# 3. 证书校验（时间偏移/证书过期）
kubeadm certs check-expiration
# 4. kubelet配置文件校验
kubelet -v4 --config /var/lib/kubelet/config.yaml
```
### 高频报错根因
1. containerd socket 无法连接：/run/containerd/containerd.sock 权限丢失
2. kubelet 证书过期、节点时间不同步
3. /var/lib/kubelet 目录权限被篡改
4. 防火墙拦截节点访问APIServer

# 五、故障大类3：节点Ready，但Pod创建/运行异常
## 5.1 镜像拉取失败
1. containerd镜像源不可达，替换内网Harbor镜像源
2. 私有仓库证书缺失，配置containerd hosts.toml
3. 磁盘满触发DiskPressure，无法写入镜像层

## 5.2 Pod 调度失败无法落地
1. 节点污点 taint 排斥业务Pod：`kubectl taint node` 清理多余污点
2. 节点打满不可调度标记 `spec.unschedulable: true`
```bash
# 取消不可调度
kubectl uncordon $NODE_NAME
```
3. 节点资源allocatable耗尽，无剩余CPU内存

## 5.3 容器启动失败、CrashLoopBackOff
1. containerd运行时故障：sandbox创建失败
2. 内核缺少cgroup/ipvs模块
3. 宿主机安全策略（selinux/apparmor）拦截容器进程

# 六、内核与硬件底层故障排查
## 6.1 内核日志（关键！大部分底层故障藏于此）
```bash
# 近30分钟内核日志
dmesg -T --human | grep -i error
dmesg -T | grep -i oom
dmesg -T | grep -i io error
```
### 典型报错对应根因
- Out of memory: Kill process：内核OOM杀死kubelet/容器进程
- I/O error dev：磁盘硬件故障、磁盘坏道
- segfault：kubelet/containerd二进制损坏、内存硬件故障

## 6.2 系统资源限制核查
```bash
# 文件句柄耗尽
ulimit -n
cat /proc/sys/fs/file-nr
# cgroup状态
cat /sys/fs/cgroup/memory/memory.usage_in_bytes
```

# 七、通用应急恢复操作（Runbook 速查）
## 7.1 重启运行时组件
```bash
# 重启containerd
systemctl restart containerd
# 重启kubelet
systemctl restart kubelet
```

## 7.2 节点临时维护锁（禁止新Pod调度）
```bash
kubectl cordon $NODE_NAME
```

## 7.3 节点安全排空（下线/维修前必执行）
```bash
kubectl drain $NODE_NAME --ignore-daemonsets --delete-emptydir-data
```

## 7.4 清理节点垃圾释放磁盘
```bash
# 清理停止容器
crictl rm $(crictl ps -a -q)
# 清理无用镜像
crictl images prune
# 清理容器日志
truncate -s 0 /var/log/containers/*.log
```

# 八、故障复盘记录模板（生产标准化）
1. 故障节点名称、故障发生时间
2. 初始现象：Node状态 / 业务影响范围
3. 排查关键日志/命令输出
4. 根因定位（组件/系统/硬件/人为操作）
5. 临时恢复操作
6. 永久修复方案 & 预防措施
7. 关联文档：08-resource-pressure.md、10-runbooks.md

# 九、文档跳转关联
- kubelet与containerd深度调优：06-kubelet-runtime.md
- 资源压力、驱逐阈值详解：08-resource-pressure.md
- 节点安全加固：09-node-hardening.md
- 标准化事故处理流程：10-runbooks.md
- 节点生命周期上线/退役：04-node-lifecycle.md