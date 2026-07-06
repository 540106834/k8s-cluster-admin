# 02-pod-lifecycle.md

## 一、文档基础信息

- 归属目录：`02-workload-management/`
- 前置阅读：`01-namespace-management.md`、`00-README.md`
- 集群基准：Kubernetes v1.32.13，containerd 2.1.5，Calico v3.30.4
- 适用环境分层：DEV本地、FAT、UAT、PROD
- 核心覆盖：Pod完整生命周期、状态流转、容器启停流程、三类健康探针、退出码解析、优雅终止、故障定位

## 二、Pod 核心底层定义

1. Pod 是 K8s **最小调度原子单元**，控制器(Deployment/StatefulSet/DaemonSet)仅管理Pod，不直接调度容器；
2. 一个Pod包含一组强耦合容器：1个主业务容器 + 多个Sidecar（日志采集、监控、代理等）；
3. Pod 共享同一网络栈、IPC、主机名、存储卷，容器间互通使用 `localhost`；
4. Pod 无自愈能力，删除/崩溃后不会自动重建，依赖上层控制器实现副本保活；
5. Pod 生命周期一次性：销毁后不会恢复，重建会生成全新Pod（IP/UID全部变更）。

## 三、Pod 完整生命周期全流程

### 3.1 阶段1：调度阶段(Pending)

1. APIServer接收Pod资源写入etcd；
2. Scheduler筛选满足资源、节点亲和、污点容忍的节点；
3. 绑定节点，写入Pod `spec.nodeName`；
4. kubelet监听本机Pod变更，下发至containerd创建容器。

阻塞场景：资源不足、节点亲和不匹配、镜像拉取失败、密钥/配置缺失。

### 3.2 阶段2：容器创建与初始化

1. 拉取镜像；
2. 启动 `initContainer` 初始化容器（串行执行，全部成功才启动业务容器）；
3. 启动业务容器+sidecar容器；
4. 容器就绪探针就绪后，加入Service Endpoint，接收流量。

### 3.3 阶段3：运行阶段(Running)

所有主容器正常启动，就绪探针通过，持续提供业务服务。

### 3.4 阶段4：终止阶段(Terminating)

触发条件：控制器缩容、手动删除Pod、节点驱逐、节点故障；

1. Pod标记Terminating，从Service Endpoint移除，切断新流量；
2. 发送 `SIGTERM` 信号给容器，等待 `terminationGracePeriodSeconds`（默认30s）；
3. 等待程序优雅关闭、内存落盘、连接释放；
4. 超时未退出则强制发送 `SIGKILL` 杀死容器；
5. 清理卷、网络资源，Pod进入Terminated状态。

### 3.5 阶段5：回收完成

Pod资源从集群etcd清除，控制器按需新建Pod补齐副本数。

## 四、Pod 标准状态流转详解

### 4.1 Pending

Pod已创建，未调度/容器未拉起。
常见原因：

- 无节点满足CPU/内存资源；
- 镜像仓库不可达、镜像名称错误；
- Secret/ConfigMap不存在；
- 节点污点、亲和策略不匹配。

### 4.2 Running

所有init容器执行完成，业务容器全部启动，至少一个就绪探针通过。

### 4.3 Failed

容器启动失败、异常退出且重启策略为Never/OnFailure。
典型场景：程序启动报错、镜像内部程序崩溃、权限不足。

### 4.4 Unknown

节点失联，kubelet未上报状态，节点宕机/断网。

### 4.5 Terminating

收到删除指令，正在优雅关闭，等待终止宽限期。

### 4.6 CrashLoopBackOff

容器反复启动崩溃，kubelet退避重试（间隔递增）。
高频诱因：启动命令错误、端口冲突、OOM、配置文件缺失、数据库连接失败。

## 五、InitContainer 初始化容器机制

### 5.1 特性

1. 串行执行，按yaml定义顺序依次运行；
2. 全部执行成功退出(exit 0)，业务容器才会启动；
3. init容器失败会反复重启，直到成功；
4. 共享Pod存储卷，可提前拉取配置、初始化数据库、注册服务。

### 5.2 典型使用场景

- 等待中间件(MySQL/Redis)就绪；
- 下载业务配置文件；
- 目录权限初始化；
- 注册服务到注册中心。

### 示例片段

```yaml
spec:
  initContainers:
  - name: wait-mysql
    image: harbor.jinshaoyong.com/k8s/busybox:latest
    command: ["sh","-c","until ping mysql.uat.svc.cluster.local -c 1;do sleep 2;done"]
```

## 六、三类健康检查探针（生产强制配置）

### 6.1 startupProbe 启动探针

作用：区分**启动慢应用**与真实崩溃，避免刚启动就被kill。
适用：Java、微服务、大镜像启动耗时较长程序。

```yaml
startupProbe:
  httpGet:
    path: /health/startup
    port: 8080
  failureThreshold: 30
  periodSeconds: 5
```

### 6.2 livenessProbe 存活探针

作用：检测容器是否卡死、死锁、进程僵死；探测失败直接杀死重建Pod。

```yaml
livenessProbe:
  httpGet:
    path: /health/live
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
```

### 6.3 readinessProbe 就绪探针

作用：判断Pod是否可接收流量；失败则从Service后端摘除，不杀容器。
关键：滚动更新、扩容时，只有readiness通过才接入流量。

```yaml
readinessProbe:
  httpGet:
    path: /health/ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
```

### 6.4 探针三种探测方式

1. httpGet：Web服务接口探测（主流）
2. tcpSocket：端口连通检测（Redis/Mysql）
3. exec：执行命令检测（脚本、进程检查）

## 七、容器重启策略 restartPolicy

仅作用Pod，控制器会覆盖Pod重建逻辑

1. Always（默认，Deployment/StatefulSet/DaemonSet固定使用）
   容器退出无论成功失败，自动重启；适合常驻业务。
2. OnFailure
   仅异常退出(exit≠0)才重启；适合一次性任务Job。
3. Never
   退出后永不重启；临时测试Pod使用。

## 八、容器退出码含义（故障排查核心）

| 退出码 | 含义 | 处理方案 |
|--------|------|----------|
| 0 | 正常退出 | Job正常完成，无需处理 |
| 1 | 通用程序异常 | 代码报错、启动参数错误 |
| 137 | SIGKILL 强制杀死 | OOM内存超限、节点资源挤压 |
| 143 | SIGTERM 优雅终止 | 缩容/删除Pod正常信号 |
| 255 | 未知异常、权限不足、镜像损坏 | 查看容器日志定位 |

## 九、Pod 优雅终止完整流程（生产关键）

1. kubectl delete / 控制器缩容，Pod标记 `Terminating`；
2. Service同步移除该Pod Endpoint，停止转发新请求；
3. 发送 `SIGTERM` 信号给容器进程；
4. 程序捕获信号，执行收尾：关闭连接、刷新缓存、保存数据；
5. 等待 `terminationGracePeriodSeconds:30`；
6. 超时未退出，发送 `SIGKILL` 强制销毁；
7. 清理网络、存储卷资源。

### 生产优化配置

```yaml
spec:
  # 延长优雅关闭时间，给业务足够收尾窗口
  terminationGracePeriodSeconds: 60
  containers:
  - name: app
    # 容器内处理SIGTERM信号
    lifecycle:
      preStop:
        exec:
          command: ["sh","-c","sleep 10"]
```
`preStop` 钩子：收到删除信号先执行一段脚本，再下发SIGTERM，用于等待存量请求完成。

## 十、生命周期钩子 lifecycle

1. postStart：容器创建后立即执行，不阻塞容器启动；
2. preStop：容器终止前执行，优雅关闭前置操作。

## 十一、分环境落地规范（DEV/FAT/UAT/PROD）

1. DEV本地：探针可省略，方便快速调试；
2. FAT测试：必须配置readiness、liveness，startup可选；
3. UAT预生产：完整三套探针，对齐生产参数；
4. PROD生产：强制 startupProbe + readinessProbe + livenessProbe，配置preStop延长优雅关闭窗口，严格设置resources limits防止OOM CrashLoop。

## 十二、常用排查命令

```bash
# 查看Pod基础状态
kubectl get pods -n fat

# 查看Pod完整生命周期事件（调度、探针、杀死记录）
kubectl describe pod xxx -n uat

# 查看容器日志定位崩溃原因
kubectl logs xxx -n prod
# 查看崩溃前历史日志
kubectl logs -p xxx -n prod

# 进入容器调试
kubectl exec -it xxx -n fat -- sh

# 实时观察Pod状态变化
kubectl get pods -n prod -w
```

## 十三、高频生命周期故障

1. CrashLoopBackOff
   排查：kubectl logs 查看启动报错、内存limit、端口占用、配置缺失。
2. Pod长期Pending
   检查describe events：资源不足、镜像拉取失败、Secret不存在。
3. Running但无法访问服务
   readiness探针失败，未加入Service Endpoint，核对健康接口。
4. OOM 退出码137
   调大容器memory limits，优化程序内存占用。
5. 删除Pod业务瞬间断流
   未配置preStop、优雅关闭时间太短，存量请求未处理完成。
6. 滚动更新新旧Pod同时接收流量
   readiness探针初始延迟太短，程序未就绪就接入流量。

## 十四、关联文档

1. 上层目录：`00-README.md`
2. 资源约束配套：`07-resource-management.md` LimitRange/Quota防止OOM
3. 无状态编排：`03-deployment-management.md` 滚动更新依赖就绪探针
4. 故障汇总：`10-workload-troubleshooting.md` Pod启动崩溃完整排错流程
5. 网络隔离：`06-cni-calico.md` 探针网络连通性异常排查