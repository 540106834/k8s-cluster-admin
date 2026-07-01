# Pod 生命周期管理规范（02\-pod\-lifecycle\.md）Ubuntu22\.04 离线生产版

## 1\. 文档概述

### 1\.1 文档定位

本文为 Kubernetes 生产集群 **Pod 全生命周期标准化运维规范**，适配 **Ubuntu22\.04、K8s v1\.32、kubeadm 离线 Harbor 集群**。Pod 是 K8s 集群最小调度单元，本文统一 Pod 创建、启动、运行、重启、销毁、退出全流程机制，标准化探针配置、状态判定、生命周期钩子、异常识别、生产最佳实践，是所有工作负载运维的底层核心基准规范。

### 1\.2 核心价值

所有 Deployment、StatefulSet、DaemonSet、Job、CronJob 均基于 Pod 运行，掌握 Pod 生命周期是解决**启动失败、重启崩溃、健康检查失败、调度异常、发布抖动**等生产问题的核心基础，可彻底规避因生命周期机制不熟悉导致的误判、误操作、故障扩大问题。

### 1\.3 适用场景

- Pod 启动流程、运行状态、退出状态识别与判定

- 就绪探针、存活探针、启动探针生产标准化配置

- 生命周期前置/后置钩子（preStop/postStart）运维适配

- Pod 重启策略、退出码、异常重启根因定位

- 发布滚动更新、节点驱逐、资源调度引发的 Pod 重建分析

- 生产 Pod 异常状态排查与生命周期故障治理

## 2\. Pod 核心基础定义

### 2\.1 Pod 核心特性

- Pod 是 K8s **最小可调度、可部署单元**，不可拆分调度

- 一个 Pod 内可包含多个容器，共享网络栈、存储卷、命名空间

- Pod 为**瞬时、可销毁、不可自愈**资源，由上层控制器管理生命周期

- 生产环境禁止裸 Pod 运行，必须通过控制器托管（Deployment/StatefulSet 等）

### 2\.2 Pod 完整生命周期链路

创建 → 调度\(Pending\) → 拉取镜像 → 启动容器 → 初始化就绪 → 正常运行 → 健康检测持续巡检 → 触发重建/驱逐/删除 → 优雅终止 → 强制销毁 → 重建/退出

## 3\. Pod 阶段状态完整解析（PHASE）

Pod Phase 为宏观运行阶段，共 5 种标准状态，生产运维优先以此判断整体运行态势。

### 3\.1 Pending（等待中）

Pod 已被 APIServer 接收、写入 etcd，但未调度或未完成初始化。

**常见原因**：节点资源不足、节点亲和性不匹配、镜像拉取失败、PVC 未绑定、配额限制、节点污点排斥。

### 3\.2 Running（运行中）

Pod 已调度至目标节点，所有初始化容器完成执行，业务容器已启动。

**注意**：Running 仅代表容器进程启动，**不代表业务就绪可用**，需结合就绪探针判断服务可用性。

### 3\.3 Succeeded（成功终止）

所有容器正常执行完毕、退出码为 0，任务完成，不再重启。常见于 Job 一次性任务。

### 3\.4 Failed（失败终止）

容器异常退出、退出码非 0，任务执行失败，重启策略禁止重启则进入此状态。

### 3\.5 Unknown（未知状态）

节点失联、kubelet 挂掉、网络中断，APIServer 无法获取 Pod 状态，状态超时未知。

## 4\. Pod 详细运行状态与异常状态解析

Phase 仅为粗粒度状态，生产排障需关注 **容器细分状态与 Reason 异常原因**。

### 4\.1 启动类异常状态

- **ImagePullBackOff**：镜像拉取失败，镜像名称错误、离线仓库无镜像、网络不通、权限不足

- **ErrImagePull**：瞬时镜像拉取错误，大概率仓库连通、镜像格式问题

- **ErrImageNeverPull**：镜像拉取策略禁止拉取，本地无镜像

- **CreateContainerError**：容器创建失败，配置错误、挂载目录不存在、权限不足、参数非法

- **CreateContainerConfigError**：ConfigMap/Secret 缺失、配置挂载失败

### 4\.2 运行崩溃类异常状态

- **CrashLoopBackOff**：容器反复启动反复崩溃，启动后立即退出，kubelet 不断重试拉起

- **OOMKilled**：内存超出限制，被系统 OOM 机制强制杀死

- **StartupProbeFailed**：启动探针失败，容器未通过启动检测

- **LivenessProbeFailed**：存活探针失败，判定容器异常，触发重启

- **ReadinessProbeFailed**：就绪探针失败，容器正常运行但业务未就绪，不接收流量

### 4\.3 调度阻塞类异常

- **Unschedulable**：节点资源不足、亲和性/污点策略不匹配、配额已满

- **ContainerCreating**：容器创建中，长时间卡住代表挂载、网络、镜像异常

## 5\. Pod 重启策略（restartPolicy）

重启策略决定容器退出后是否自动重启，全局作用于 Pod 所有容器，**控制器可限定策略范围**。

### 5\.1 三种重启策略

- **Always（默认）**：容器无论正常/异常退出，均自动重启，适配常驻业务（Deployment/DaemonSet）

- **OnFailure**：仅异常退出（非0退出码）重启，正常完成不重启，适配一次性任务

- **Never**：无论成败均不重启，适配离线一次性脚本、临时任务

### 5\.2 控制器默认适配规则

- Deployment / StatefulSet / DaemonSet：强制 Always 常驻重启

- Job / CronJob：默认 OnFailure，按需重试

## 6\. 三大探针生产标准化规范（核心）

K8s 通过探针实现**业务健康感知、流量精准调度、异常自动重启**，生产所有业务必须配置全套探针。

### 6\.1 启动探针 startupProbe

用于适配**启动慢、初始化耗时久**的业务，保护启动阶段不被存活探针误杀重启。

- 作用：容器启动阶段专属检测，启动成功后不再执行

- 生产场景：Java、微服务、中间件、数据库类慢启动业务

### 6\.2 存活探针 livenessProbe

检测容器**运行健康状态**，检测失败直接重启容器，解决僵死、死锁、假死进程问题。

### 6\.3 就绪探针 readinessProbe

检测容器**业务是否就绪可对外提供服务**，失败不重启容器，仅将 Pod 从 Service 流量池中摘除。

**生产核心意义**：实现滚动更新零停机、避免启动中业务接收流量报错。

### 6\.4 探针三种检测方式

- **httpGet**：HTTP 接口探测，适配 Web 业务（最常用）

- **tcpSocket**：端口连通性探测，适配 TCP 中间件、数据库

- **exec**：命令行探测，适配自定义健康检测脚本业务

### 6\.5 生产标准探针模板

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 2
startupProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 20

```

## 7\. Pod 生命周期钩子机制

### 7\.1 postStart 启动钩子

容器创建成功后触发，用于初始化脚本、权限配置、预热任务。

### 7\.2 preStop 优雅终止钩子（生产关键）

Pod 删除/重建前触发，用于**优雅关闭连接、保存现场、释放资源、注销注册中心**，配合终止宽限期实现零停机发布。

生产必须配置 preStop 钩子，杜绝强制杀死进程导致的业务数据丢失、连接报错。

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh","-c","sleep 3"]

```

## 8\. Pod 优雅终止完整流程

生产发布、节点驱逐、手动删除 Pod 均遵循此流程，是零停机发布的核心原理。

1. 接收删除请求，Pod 状态变为 Terminating

2. Service 立即摘除该 Pod 流量，停止新流量进入

3. 执行 preStop 生命周期钩子脚本

4. 等待优雅终止宽限期（默认 30s）

5. 宽限期结束，无论是否执行完毕，强制 kill 容器进程

6. kube\-controller\-manager 触发新建 Pod 完成替换

## 9\. Pod 退出码详解（排障核心）

- **Exit 0**：正常退出，任务执行完成

- **Exit 1**：通用业务异常，代码报错、参数错误

- **Exit 137**：被系统强制杀死（OOM、kill \-9、资源不足）

- **Exit 139**：程序段错误、内存指针异常

- **Exit 143**：优雅关闭信号终止（kill \-15，正常发布重建）

## 10\. 日常运维常用命令

```bash
# 查看Pod状态与重启次数
kubectl get pods -n <ns>

# 查看Pod详细事件、状态、报错
kubectl describe pod <pod-name> -n <ns>

# 查看容器日志排查崩溃原因
kubectl logs <pod-name> -n <ns>
kubectl logs -p <pod-name> -n <ns>

# 实时查看Pod生命周期事件
kubectl get events -n <ns> --sort-by=.metadata.creationTimestamp

```

## 11\. 生产红线规范

- 生产常驻业务禁止裸 Pod 运行，必须由控制器托管

- 所有生产业务必须配置 startup、liveness、readiness 全套探针

- 所有生产业务必须配置 preStop 优雅终止钩子，保障发布无损

- 禁止探针参数配置不合理（超时过短、次数过少）导致批量误重启

- 禁止忽略 Pod 重启、OOM、探针失败告警带病运行

- 禁止常驻业务使用 OnFailure / Never 重启策略

## 12\. 常见故障快速排障

- **反复 CrashLoopBackOff**：优先查看日志、检查启动命令、配置文件、端口占用、权限问题

- **频繁自动重启**：大概率存活探针误判、内存溢出、线程死锁

- **发布成功但业务报错**：就绪探针未就绪，流量未平滑切换

- **更新发布瞬间报错**：未配置 preStop，旧连接强制中断

- **Pod OOM 重启**：业务内存泄漏、资源限制过低，需优化程序或调整 limit

## 13\. 关联文档

- Deployment 运维规范：`03-deployment-management.md`

- 工作负载排障手册：`15-workload-troubleshooting.md`

- 滚动发布与回滚规范：`11-rollout-management.md`、`12-rollback-management.md`

> （注：部分内容可能由 AI 生成）
