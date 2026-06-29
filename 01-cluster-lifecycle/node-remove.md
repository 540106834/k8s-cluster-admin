# Worker 节点下线缩容规范（node-remove.md）Ubuntu22.04 + K8s v1.32 离线生产版

## 1. 文档概述

### 1.1 文档定位

本文为 Kubernetes 集群 **Worker 节点下线、缩容、故障节点剔除、节点销毁** 标准运维文档，完全适配 **Ubuntu 22.04、K8s v1.32、kubeadm 自建离线 Harbor 集群**。
统一生产环境节点优雅下线流程、异常节点强制删除流程、集群残留清理、主机环境重置规范，杜绝缩容引发业务中断、资源残留、集群状态异常等生产事故，为集群缩容、机器替换、机房裁撤的唯一标准。

### 1.2 适用场景

- 集群日常缩容、闲置节点下线销毁
- 硬件故障、系统异常节点剔除替换
- 版本升级、基线不统一节点替换下线
- 机房迁移、环境重构批量节点销毁
- 节点卡死、失联、NotReady 异常强制清理

### 1.3 核心原则

- **优雅优先**：正常节点必须执行驱逐下线，禁止直接删节点
- **业务无损**：下线前校验副本数、冗余策略，避免单实例业务中断
- **彻底清理**：集群资源、主机残留配置双向清理，杜绝脏数据
- **状态闭环**：下线完成必须验收集群状态、业务稳定性

## 2. 节点下线前置检查（生产必做）

任何节点下线操作前，必须完成以下检查，不满足条件禁止下线。

### 2.1 业务高可用检查

- 核查待下线节点业务副本数 **≥2**，确保驱逐后有冗余实例承接流量
- 识别单副本、有状态、数据库、中间件核心业务，提前做流量切换或停机维护
- 确认业务 PDB  Pod 中断预算策略，避免驱逐失败、业务卡死
- 核心业务需提前确认流量监控、QPS、报错指标，无异常波动再操作

### 2.2 节点资源状态检查

```bash
# 查看节点状态、业务Pod分布
kubectl get nodes

root@k8s-master01-192-168-11-4:~# kubectl get nodes
NAME                        STATUS   ROLES                       AGE    VERSION
k8s-master01-192-168-11-4   Ready    control-plane,etcd,master   114d   v1.32.11+rke2r3
k8s-node01-192-168-11-5     Ready    <none>                      114d   v1.32.11+rke2r3
k8s-node02-192-168-11-6     Ready    <none>                      114d   v1.32.11+rke2r3
k8s-node03-192-168-11-172   Ready    <none>                      112d   v1.32.11+rke2r3

kubectl get pods -A -o wide | grep k8s-node03-192-168-11-172
root@k8s-master01-192-168-11-4:~# kubectl get pods -A -o wide | grep k8s-node03-192-168-11-172
apps-test         demo-app-8647f6d59-qpq2x                                1/1     Running   0             31d    10.42.4.42       k8s-node03-192-168-11-172   <none>           <none>
argocd            argocd-applicationset-controller-7f598c9547-s8nwb       1/1     Running   0             22d    10.42.4.58       k8s-node03-192-168-11-172   <none>           <none>
dev               dev-nginx-gitops-7c9844476d-hwbjj                       1/1     Running   0             18d    10.42.4.61       k8s-node03-192-168-11-172   <none>           <none>
kube-system       kube-flannel-ds-djkjn                                   1/1     Running   0             112d   192.168.11.172   k8s-node03-192-168-11-172   <none>           <none>
kube-system       kube-proxy-k8s-node03-192-168-11-172                    1/1     Running   0             112d   192.168.11.172   k8s-node03-192-168-11-172   <none>           <none>
kube-system       rke2-metrics-server-7b99dd84dd-hzf44                    1/1     Running   0             47d    10.42.4.26       k8s-node03-192-168-11-172   <none>           <none>
metallb-system    controller-749d85b6f5-dg76r                             1/1     Running   0             45d    10.42.4.34       k8s-node03-192-168-11-172   <none>           <none>
metallb-system    speaker-lcb4s                                           1/1     Running   0             45d    192.168.11.172   k8s-node03-192-168-11-172   <none>           <none>


# 查看节点资源负载
kubectl top node k8s-node03-192-168-11-172
root@k8s-master01-192-168-11-4:~# kubectl top node k8s-node03-192-168-11-172
NAME                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
k8s-node03-192-168-11-172   71m          3%       1657Mi          42%

# 检查是否存在本地盘、hostPath 绑定业务
kubectl get pods -A -o wide | grep k8s-node03-192-168-11-172 | xargs kubectl describe pod

```

- 存在 **本地盘业务** 禁止直接驱逐，需手动迁移数据
- 存在独占、守护进程类业务，提前评估迁移方案
- 确认节点无批量重启、异常报错、资源打满情况

### 2.3 集群整体状态检查

```bash
# 检查系统组件健康
kubectl get cs
kubectl get pods -n kube-system

# 检查网络、存储插件状态
kubectl get calicoapiserverconfigs -n kube-system

```

集群系统组件异常、网络抖动、存储挂载异常时，禁止执行节点下线操作。

## 3. 正常节点优雅下线流程（生产标准流程）

适用于节点 **Ready 状态、可正常通信** 的日常缩容、节点替换场景。

### 3.1 节点封锁（禁止新Pod调度）

```bash
# 封锁节点，停止新业务调度
kubectl cordon k8s-node03-192-168-11-172

```

执行后节点状态变为 **SchedulingDisabled**，仅存量Pod运行，不再接收新调度任务。

### 3.2 节点业务平滑驱逐

```bash
# 平滑驱逐所有Pod，自动调度至其他健康节点
kubectl drain k8s-node03-192-168-11-172 --ignore-daemonsets --delete-emptydir-data

root@k8s-master01-192-168-11-4:~# kubectl drain k8s-node03-192-168-11-172 --ignore-daemonsets --delete-emptydir-data
node/k8s-node03-192-168-11-172 already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/kube-flannel-ds-djkjn, metallb-system/speaker-lcb4s
evicting pod metallb-system/controller-749d85b6f5-dg76r
evicting pod argocd/argocd-applicationset-controller-7f598c9547-s8nwb
evicting pod kube-system/rke2-metrics-server-7b99dd84dd-hzf44
evicting pod dev/dev-nginx-gitops-7c9844476d-hwbjj
evicting pod apps-test/demo-app-8647f6d59-ljkmq
pod/controller-749d85b6f5-dg76r evicted
pod/dev-nginx-gitops-7c9844476d-hwbjj evicted
pod/rke2-metrics-server-7b99dd84dd-hzf44 evicted
pod/argocd-applicationset-controller-7f598c9547-s8nwb evicted
pod/demo-app-8647f6d59-ljkmq evicted
node/k8s-node03-192-168-11-172 drained

```

**参数说明**：

- `--ignore-daemonsets`：忽略Calico、kube-proxy等守护进程Pod，不强制驱逐

- `--delete-emptydir-data`：清理临时目录数据，避免残留脏数据

**驱逐拦截处理**：若提示PDB拦截、单副本拦截，返回前置检查，手动处理后重新执行驱逐。

### 3.3 确认节点无业务Pod

```bash
root@k8s-master01-192-168-11-4:~# kubectl get pods -A | grep k8s-node03-192-168-11-172
kube-system       kube-proxy-k8s-node03-192-168-11-172                    1/1     Running   0             112d

```

仅保留DaemonSet组件，无业务Pod即为驱逐完成。

### 3.4 集群删除节点

```bash
root@k8s-master01-192-168-11-4:~# kubectl delete node k8s-node03-192-168-11-172
node "k8s-node03-192-168-11-172" deleted
root@k8s-master01-192-168-11-4:~# kubectl get nodes
NAME                        STATUS   ROLES                       AGE    VERSION
k8s-master01-192-168-11-4   Ready    control-plane,etcd,master   114d   v1.32.11+rke2r3
k8s-node01-192-168-11-5     Ready    <none>                      114d   v1.32.11+rke2r3
k8s-node02-192-168-11-6     Ready    <none>                      114d   v1.32.11+rke2r3
root@k8s-master01-192-168-11-4:~# kubectl top nodes
NAME                        CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
k8s-master01-192-168-11-4   1349m        22%      2895Mi          36%         
k8s-node01-192-168-11-5     55m          2%       1809Mi          46%         
k8s-node02-192-168-11-6     97m          4%       1878Mi          48%

```

## 4. 异常节点强制下线流程（故障节点专用）

适用于节点 **NotReady、失联、卡死、无法通信**，无法执行drain优雅驱逐的场景。

### 4.1 直接删除集群节点记录

```bash
kubectl delete node <node-name>

```

### 4.2 清理集群残留资源

异常节点强制删除后，容易残留僵死Pod、端点记录，需手动清理：

```bash
# 强制清理残留僵死Pod
kubectl get pods -o wide | grep <node-name> | awk '{print $1}' | xargs kubectl delete pod --grace-period=0 --force

```

## 5. 节点本机环境重置（彻底脱群）

节点从集群删除后，需清空本机K8s配置、证书、运行时数据，防止后续误入网、配置冲突，适配离线kubeadm集群。

### 5.1 kubeadm重置节点

```bash
kubeadm reset -f

```

### 5.2 清理残留目录与配置

```bash
# 清理证书、配置、网络残留
rm -rf /etc/kubernetes/
rm -rf $HOME/.kube/
rm -rf /var/lib/kubelet/*
rm -rf /var/lib/cni/

# 重启containerd清理容器残留
systemctl restart containerd
crictl rm -a
```

### 5.3 恢复系统基线（可选）

若机器需要复用为普通服务器，可恢复swap、防火墙等系统配置；若后续复用为K8s节点，保持基线不变。

## 6. 批量节点下线规范

批量缩容、机房迁移场景，禁止一次性批量下线多节点，遵循**分批下线、逐台验收**原则。

1. 单次仅下线单台节点，验收业务稳定后再操作下一台

2. 跨AZ节点优先分批下线，避免单AZ业务集中中断

3. 批量下线完成后，全局校验集群Pod健康、网络连通、存储挂载

## 7. 下线后生产验收（必做）

节点下线为变更类高危操作，必须逐项验收，确认无业务影响。

```bash
# 1. 所有节点状态正常
kubectl get nodes

# 2. 所有Pod运行正常，无重启、崩溃、调度失败
kubectl get pods --all-namespaces | grep -E "CrashLoopBackOff|Error|Pending"

# 3. 系统组件健康
kubectl get pods -n kube-system

# 4. 校验业务接口、日志、监控无异常

```

**验收标准**：

- 集群节点数量符合缩容预期，无残留脏节点

- 所有业务Pod正常重建、运行、流量恢复

- 无调度异常、网络异常、存储挂载异常

- 业务监控QPS、错误率、延迟无波动

## 8. 常见故障与排错

### 8.1 drain驱逐失败：PDB拦截

原因为业务Pod中断预算限制，单实例不可驱逐。解决方案：临时调整PDB策略或手动扩容副本后再驱逐。

### 8.2 drain驱逐失败：本地盘数据残留

存在hostPath本地存储业务，禁止强制删除，需手动迁移数据、删除对应Pod后重试。

### 8.3 节点删除后残留僵死Pod

使用 `--grace-period=0 --force` 强制删除，同时检查endpoint资源是否残留，清理无效端点。

### 8.4 节点重置后无法重新入网

大概率是残留cni网络配置、kubelet状态未清空，完整清理 `/var/lib/cni`、`/var/lib/kubelet` 目录后重试。

## 9. 生产红线禁止规范

- **禁止直接删除节点不执行drain驱逐**，引发业务强制中断、数据丢失

- 禁止单副本核心业务无预处理直接下线节点

- 禁止集群状态异常、业务抖动时执行缩容操作

- 禁止批量一次性下线多台核心节点，无分批验收

- 禁止下线后不清理本机残留配置，导致后续入网冲突

- 禁止下线完成后不做业务验收，遗留隐性故障

## 10. 关联文档

- 节点入网扩容：`node-join.md`

- 节点日常运维：`worker-node-management.md`

- 节点在线维护：`node-maintenance.md`

- 集群安装基线：`cluster-installation.md`

> （注：部分内容可能由 AI 生成）
