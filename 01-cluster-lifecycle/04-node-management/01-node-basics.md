# 01-node-basics.md

## 一、文档说明

归属模块：Worker 节点管理
前置依赖：00-overview.md
适用场景：集群日常巡检、节点信息采集、基础状态校验、标准化信息核查
目标：掌握节点核心对象、状态字段、基础查询命令、资源/系统指标核查标准

## 二、K8s Node 对象核心概念

### 2.1 Node 是什么

Node 是集群计算载体，分为 Master/ControlPlane、Worker 节点；  
kubelet 常驻进程，向 APIServer 上报本机硬件、系统、资源、运行状态，注册为 Node 资源。

### 2.2 Node 核心状态维度

1. **Ready**：节点健康标识，True=kubelet正常上报心跳，False/Unknown失联/故障
2. **MemoryPressure**：内存压力，True=内存不足触发驱逐
3. **DiskPressure**：磁盘压力，磁盘/镜像分区使用率过高
4. **PIDPressure**：进程数耗尽压力
5. **NetworkUnavailable**：网络插件未就绪

### 2.3 Node 元数据核心字段

- metadata.name：节点主机名（集群唯一标识）
- metadata.labels：调度标签、机房/机型/业务分区、操作系统标识
- metadata.taints：污点，控制 Pod 是否可调度至本节点
- spec.unschedulable：调度开关，true=禁止新Pod调度（维护排空前置）
- status.addresses：节点IP列表（主机IP、内网IP、主机名）
- status.capacity：硬件总配额（CPU、内存、Pod最大数量、磁盘）
- status.allocatable：可分配资源（扣除系统预留、kube预留后可用配额）
- status.nodeInfo：系统信息（内核、OS、containerd、kubelet版本、主机架构）

## 三、节点基础查询命令（生产标准）

### 3.1 基础列表查看

```bash
# 精简节点列表（状态、角色、版本、系统）
kubectl get nodes

# 完整详情输出
kubectl get node <node-name> -o yaml

# 宽输出，展示内网IP、OS、内核
kubectl get nodes -o wide

# 仅输出节点名称列表
kubectl get nodes -o jsonpath='{.items[*].metadata.name}'
```

### 3.2 标签/污点查看

```bash
# 查看所有节点标签
kubectl get nodes --show-labels

# 查看单节点污点
kubectl describe node <node-name> | grep Taints
```

### 3.3 资源容量与可分配资源核查

```bash
# 查看节点资源配额
kubectl describe node <node-name>
# 重点字段：Capacity / Allocatable / Allocated resources
```

## 四、节点系统基础信息核查（主机侧）

### 4.1 操作系统与内核

```bash
# OS版本
cat /etc/os-release
# 内核版本
uname -r
# CPU架构
arch
```

### 4.2 硬件资源

```bash
# CPU核心
lscpu
# 内存总量
free -h
# 磁盘分区（镜像/根分区）
df -h
# 进程上限
cat /proc/sys/pid_max
```

### 4.3 运行时与kubelet版本

```bash
# containerd版本
ctr --version
# kubelet版本
kubelet --version
# 容器运行时状态
systemctl status containerd kubelet
```

### 4.4 网络基础校验

```bash
# 节点内网IP
hostname -i
# 主机名匹配node名称
hostname
# DNS连通性
nslookup kubernetes.default.svc.cluster.local
```

## 五、Node 状态判定标准

### 5.1 Ready = True 正常

kubelet 持续上报 10s 心跳，无资源压力，网络插件就绪。

### 5.2 Ready = False

1. kubelet 进程宕机、crashloop
2. containerd 异常无法创建容器
3. 磁盘满、磁盘IO卡死导致kubelet无法写日志/上报状态
4. 防火墙阻断节点与apiserver 6443端口

### 5.3 Ready = Unknown

节点网络断连、主机关机、内核panic，apiserver超过40s未收到心跳。

### 5.4 各类 Pressure 压力说明

1. MemoryPressure：节点可用内存低于阈值，kubelet开始驱逐低优先级Pod
2. DiskPressure：根分区/镜像存储分区使用率超过阈值，暂停镜像拉取、驱逐Pod
3. PIDPressure：系统进程数接近pid_max，新建容器失败

## 六、节点基础巡检标准化清单（日常巡检复用）

每次巡检执行以下检查项，输出记录：

1. 所有节点 `kubectl get nodes` 全部 Ready
2. 无 Memory/Disk/PID Pressure 异常标记
3. kubelet、containerd 服务 running
4. 节点磁盘使用率 <80%
5. 内存剩余量 >10% allocatable
6. 节点主机名与 node name 一一对应
7. 节点IP无冲突，内网互通
8. kubelet/containerd 版本统一，无跨大版本混杂
9. 关键业务节点标签、污点配置符合调度规范

## 七、常见基础问题

1. 节点主机名修改后 Node 对象无法匹配：删除旧node，重新join节点
2. Node 显示 NetworkUnavailable：calico/flannel 网络插件Pod异常，重启网络控制器
3. Allocatable 资源远小于 Capacity：kubelet配置预留大量系统资源，核对 kubelet config
4. 节点标签丢失：人为删除label，重新打标并录入标准化交付文档

## 八、关联文档跳转

- 调度标签/污点深度：07-scheduling-control.md
- 资源压力驱逐机制：08-resource-pressure.md
- kubelet运行时调优：06-kubelet-runtime.md
- 节点故障排查：05-node-troubleshooting.md

需要我把这份文档压缩成**生产极简运维版**，去掉理论、只保留可直接复制的命令与巡检清单吗？