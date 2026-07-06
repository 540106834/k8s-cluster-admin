# Worker Node Management Overview（生产级总览）

---

**文档定位**：K8s Worker 节点运维目录导航页｜框架说明 + 全目录操作入口 + 故障排查总入口｜生产环境强制执行

## 1. 节点作用说明

Worker 节点是 Kubernetes 集群中承载业务 Pod 的执行层节点，核心职责如下：

- 运行业务容器 Pod 工作负载
- kubelet 组件完成 Pod/节点生命周期管控
- 提供 Containerd CRI 容器运行时环境
- 接收控制面调度器下发的任务调度指令

## 2. 节点核心组件调用模型

### 2.1 集群全局调用链路

```text
Scheduler → API Server → kubelet → containerd → Pod
```

### 2.2 Worker 节点内部组件能力模型

```text
kubelet（节点核心代理组件）
  ├── Pod lifecycle management      # Pod 全生命周期管理
  ├── node status reporting         # 节点状态上报至控制面
  ├── volume mount                  # 存储卷挂载/卸载管理
  └── container runtime interface   # CRI 运行时接口适配

containerd（容器运行时）
  ├── image pull                    # 镜像拉取、仓库鉴权
  ├── container runtime             # 容器启停、生命周期执行
  └── snapshot filesystem           # 容器分层快照文件系统
```

## 3. Worker 节点标准生命周期状态

```text
NotReady → Ready → SchedulingDisabled → Draining → Removed
```

### 状态释义对照表

|节点状态|生产场景含义|运维处置倾向|
|---|---|---|
|`NotReady`|kubelet 异常、节点网络故障、资源压力超标|故障排查|
|`Ready`|节点健康，集群可正常调度业务 Pod|正常运行|
|`SchedulingDisabled`|执行 cordon 操作，禁止新 Pod 调度至本节点|节点维护前置操作|
|`Draining`|节点正在驱逐存量业务 Pod，下线预热中|等待驱逐完成|
|`Removed`|节点已从 Kubernetes 集群完成剔除删除|物理/主机资源回收|

## 4. Worker 节点职责边界（权责划分）

### 节点负责范围

- 业务 Pod 容器运行、现场环境执行
- 本地容器生命周期启停、重启、销毁管控
- 节点本地硬件资源管控：CPU / 内存 / 磁盘 / PID 资源限额
- 节点健康状态、资源水位向控制面上报

### 节点不负责范围

- Pod 跨节点调度决策（由集群 Scheduler 控制面组件执行）
- 集群全局控制器决策（apiserver、controller-manager）
- 集群权限、全局资源配额顶层管控

## 5. 生产运维四大核心目标

**生产环境所有 Worker 节点运维操作，必须围绕以下四个目标执行：**
**稳定性 → 可观测性 → 可恢复性 → 安全性**

## 6. 全流程运维操作导航索引（核心入口）

下方为目录跳转入口，所有专项运维操作请严格按照对应文档执行，禁止自定义操作流程

### 6.1 节点接入初始化

跳转文档：**`02-node-join.md`**

- kubeadm join 集群接入流程
- 集群 Token 生命周期管理、过期补发
- 节点入网前置巡检、系统环境初始化校验
- 多网卡、内网专线复杂场景节点接入适配

### 6.2 节点业务下线&集群剔除

跳转文档：**`03-node-drain.md`**

- cordon 调度冻结、drain 业务 Pod 驱逐标准流程
- Pod 驱逐容忍、中断优先级生产策略
- 异常节点强制下线兜底方案
- 集群内节点完整删除收尾流程

### 6.3 节点全生命周期运维

跳转文档：**`04-node-lifecycle.md`**

- 集群版本滚动升级（Worker 侧）
- 生产维护窗口规划与低峰运维作业
- 物理机替换、节点扩容替换标准方案
- 业务无感知节点灰度迁移方案

### 6.4 节点通用故障排查

跳转文档：**`05-node-troubleshooting.md`**

- 节点 NotReady 典型故障闭环处理
- kubelet 闪退、挂死异常排障
- Containerd 运行时异常排查
- 集群 CNI 节点网络不通、跨主机通信异常
- 节点证书过期、证书鉴权失败故障

### 6.5 Kubelet & 容器运行时调优排障

跳转文档：**`06-kubelet-runtime.md`**

- kubelet 启动参数、运行时参数异常修正
- Containerd 日志调试、底层问题定位
- Cgroup Driver 驱动一致性故障修复
- 镜像拉取失败、仓库鉴权异常处理

### 6.6 节点调度策略管控

跳转文档：**`07-scheduling-control.md`**

- 节点污点(Taint) & 容忍度(Toleration)配置管理
- 节点业务标签(Label)生命周期维护
- 节点/ Pod 亲和、反亲和调度规则配置
- 生产业务节点隔离、专属节点调度策略

### 6.7 节点资源压力与驱逐管控

跳转文档：**`08-resource-pressure.md`**

- MemoryPressure 内存高压告警处置
- DiskPressure 磁盘爆满、磁盘高压处置
- PIDPressure 进程资源耗尽故障
- kubelet 原生资源驱逐机制参数调优

### 6.8 节点生产安全加固

跳转文档：**`09-node-hardening.md`**

- 服务器 SSH 登录权限、访问安全加固
- kubelet API 未授权访问防护配置
- 节点入站出站 API 访问权限收敛
- 容器运行时权限隔离、最小权限落地

### 6.9 标准化故障应急 Runbook

跳转文档：**`10-runbooks.md`**

- 节点突发 NotReady 应急处置流程
- Pod 卡死、僵死容器应急清理
- 节点磁盘占满生产紧急预案
- kubelet 异常重启快速恢复预案

## 7. 集群基线基础信息（静态固定｜禁止修改）

|主机名|内网IP|集群角色|备注|
|---|---|---|---|
|k8s-master-01|192.168.11.161|control-plane（控制面）|单控制面集群|
|k8s-worker-01|192.168.11.162|worker（业务计算节点）|生产业务承载节点|
|k8s-worker-02|192.168.11.163|worker（业务计算节点）|生产业务承载节点|
|harbor|192.168.11.170|registry（镜像仓库）|集群内网镜像源|

## 8. 集群环境基线版本

- Kubernetes：**v1.32.13**
- Containerd：**v2.1.2**
- 操作系统：**Ubuntu 22.04 LTS**
- Harbor 镜像仓库：**v2.11**

## 9. 生产环境强制操作规范

### 节点运维黄金三原则（生产强制执行）

先隔离（cordon） → 再迁移（drain） → 后操作（maintenance）

### 生产环境禁止操作红线

- 未执行 drain 驱逐，直接关机/重启生产 Worker 节点
- 未校验业务 Pod 运行状态，直接删除集群节点资源
- 生产节点直接修改 kubelet/containerd 核心参数，无灰度、无回滚预案
- 高压告警节点直接重载服务，不做业务隔离

## 10. 快速诊断命令入口（日常排障首选）

所有节点故障优先执行以下命令定位基础问题

### 集群全节点概览检查

```bash
kubectl get nodes -o wide
```

### 单节点详细事件&告警信息

```bash
kubectl describe node <node-name>
```

### Kubelet 服务状态与实时日志

```bash
systemctl status kubelet
journalctl -u kubelet -f
```

### Containerd 运行时与容器列表

```bash
systemctl status containerd
crictl ps -a
```

---

## 11. 文档核心总结

Worker Node 运维的核心是围绕**节点生命周期、kubelet运行状态、节点调度控制、节点资源压力**四条主线进行标准化管理；所有生产变更、故障运维操作，必须通过 cordon+drain 流程保障业务连续性。
