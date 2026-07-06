# Kubernetes 集群版本升级规范（kubernetes\-upgrade\.md）Ubuntu22\.04 离线生产版

## 1\. 文档概述

### 1\.1 文档定位

本文为 **Kubernetes 生产集群版本迭代升级标准文档**，适配**Ubuntu22\.04、kubeadm 自建离线Harbor集群、K8s小版本迭代升级**，覆盖控制面、Worker节点、核心组件、离线镜像迁移、升级验收、故障回滚全流程，是集群版本迭代、漏洞修复、社区版本更新的唯一生产基准。

### 1\.2 升级核心原则（生产红线）

- **仅小版本滚动升级**：生产集群禁止跨大版本跳跃升级（如 v1\.32\.x → v1\.33\.x 需逐版本过渡），仅支持 Z 号小版本迭代

- **控制面优先升级**：先升级Master控制面，稳定后再逐台滚动升级Worker节点

- **灰度逐台升级**：禁止所有节点同时升级，单节点升级验收无误后再迭代下一台

- **离线环境闭环**：全程依赖内网Harbor私有镜像，无任何外网拉取、外网源依赖

- **可回滚、可兜底**：升级前备份所有配置、证书、资源清单，异常即刻回滚

- **业务零中断**：依托节点驱逐机制，实现升级过程业务无感知、无宕机

### 1\.3 适用场景

- K8s小版本安全漏洞修复、社区补丁迭代（如 v1\.32\.10 → v1\.32\.13）

- 集群组件版本统一、基线标准化升级

- 离线集群镜像版本更新、组件能力迭代

- 证书、kubelet、kubeadm、kubectl 版本同步更新

## 2\. 升级前置条件（必检）

### 2\.1 集群健康状态检查

集群异常、业务抖动、组件报错时，禁止执行版本升级操作

```bash
# 节点全健康检查
kubectl get nodes
# 系统组件状态检查
kubectl get pods -n kube-system
# 核心业务Pod状态校验
kubectl get pods --all-namespaces | grep -E "CrashLoopBackOff|Error|Pending"
# 集群资源对象完整性校验
kubectl get all --all-namespaces

```

### 2\.2 离线镜像前置准备（离线集群核心）

离线环境无法在线拉取镜像，需提前在外网机器拉取新版本镜像，打包上传至内网Harbor私有仓库，保证升级过程镜像100%可用。

```bash
# 查看升级所需镜像列表
kubeadm config images list --kubernetes-version=目标版本

# 规范：所有k8s官方镜像统一上传至 harbor.local.com/k8s 项目
# 升级前确认Harbor镜像完整：kube-apiserver、kube-controller-manager、kube-scheduler、etcd、coredns、pause

```

### 2\.3 版本规范约束

- 集群所有组件版本必须**高度一致**（kubeadm/kubelet/kubectl/集群镜像版本统一）

- Calico网络插件版本、CSI存储插件版本需兼容目标K8s版本

- 禁止集群内出现多版本混杂节点，避免调度异常、API兼容报错

### 2\.4 集群全量备份（升级必做）

```bash
# 1. 备份k8s全部资源清单
kubectl get all -o yaml --all-namespaces > k8s-all-resources-$(date +%Y%m%d).yaml

# 2. 备份master证书与配置
cp -r /etc/kubernetes /etc/kubernetes-bak-$(date +%Y%m%d)

# 3. 备份kubelet配置
cp -r /var/lib/kubelet /var/lib/kubelet-bak-$(date +%Y%m%d)

```

## 3\. 离线版本包升级准备

适配纯离线Ubuntu22\.04环境，依托内网离线APT源或本地Deb包升级组件。

### 3\.1 统一版本锁定规则

升级前解锁版本，升级完成重新锁定，杜绝自动版本漂移。

```bash
# 解锁版本
apt-mark unhold kubelet kubeadm kubectl

# 离线升级至目标版本（示例升级至v1.32.13）
apt install -y kubelet=1.32.13-00 kubeadm=1.32.13-00 kubectl=1.32.13-00

# 重新锁定版本
apt-mark hold kubelet kubeadm kubectl

```

## 4\. 控制面（Master）升级流程

高可用集群需**逐台Master升级**，单台升级完成、状态正常后再升级下一台，单Master节点直接执行升级。

### 4\.1 查看集群当前版本

```bash
kubeadm version
kubectl version
```

### 4\.2 执行kubeadm集群升级

```bash
# 离线指定Harbor私有镜像仓库升级，不使用外网源
kubeadm upgrade apply v1.32.13 \
--image-repository harbor.local.com/k8s

```

执行过程确认升级方案，输入 y 确认升级，自动完成apiserver、controller、scheduler、etcd、coredns组件镜像更新。

### 4\.3 刷新Master节点kubelet配置

```bash
systemctl daemon-reload
systemctl restart kubelet

```

### 4\.4 控制面升级验收

```bash
# 查看集群版本统一
kubectl version
# 查看控制面组件运行状态
kubectl get pods -n kube-system | grep -E "kube-apiserver|kube-controller|kube-scheduler|etcd"
# 查看节点版本
kubectl get nodes

```

验收标准：控制面组件全部Running、版本统一、无重启异常、无报错日志。

## 5\. Worker节点滚动升级流程（核心灰度流程）

严格遵循 **封锁→驱逐→升级→重启→恢复调度** 标准流程，单台逐次升级，杜绝批量操作，完全复用node\-maintenance\.md运维规范。

### 5\.1 节点封锁，禁止新调度

```bash
kubectl cordon <node-name>

```

### 5\.2 平滑驱逐业务Pod

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

```

### 5\.3 节点本地组件升级

```bash
# 离线升级kubeadm/kubelet/kubectl
apt install -y kubelet=1.32.13-00 kubeadm=1.32.13-00 kubectl=1.32.13-00
apt-mark hold kubelet kubeadm kubectl

# 刷新配置重启kubelet
systemctl daemon-reload
systemctl restart kubelet

```

### 5\.4 节点恢复调度

```bash
kubectl uncordon <node-name>

```

### 5\.5 单节点升级验收

确认节点状态Ready、版本同步、Pod正常重建、无业务异常，再进行下一台Worker节点升级。

## 6\. 配套组件版本适配升级

### 6\.1 Calico网络插件升级

K8s小版本迭代后，需保证Calico版本兼容，离线环境需提前替换YAML镜像为内网Harbor地址。

```bash
# 预处理离线Calico YAML（替换外网镜像为Harbor私有镜像）
sed -i 's/registry.k8s.io\/calico/harbor.local.com\/k8s/g' calico-offline.yaml

# 滚动更新网络插件
kubectl apply -f calico-offline.yaml

```

### 6\.2 CoreDNS/CSI组件校验

升级完成后校验DNS解析、存储挂载功能，确保组件适配新版本集群API。

## 7\. 全集群升级最终验收标准

### 7\.1 集群层验收

- 所有Master、Worker节点版本**完全统一**，无版本混杂

- 所有节点状态Ready，无NotReady、SchedulingDisabled异常

- kube\-system所有组件Pod全部Running，无重启、崩溃、报错

- 集群API访问正常，资源增删改查无异常

### 7\.2 业务层验收

- 所有业务Pod正常运行、无批量重启、无CrashLoop异常

- 业务接口QPS、错误率、延迟平稳无波动

- 日志无连接异常、API版本不兼容、权限报错

- 网络连通、存储挂载、域名解析完全正常

## 8\. 升级故障回滚方案

### 8\.1 紧急回滚原则

升级出现组件异常、业务中断、版本不兼容时，立即停止迭代，执行版本回滚、配置还原。

### 8\.2 版本回滚操作

```bash
# 降级至原稳定版本
apt-mark unhold kubelet kubeadm kubectl
apt install -y 旧版本号
apt-mark hold kubelet kubeadm kubectl

# 还原备份证书与配置
cp -r /etc/kubernetes-bak-*/* /etc/kubernetes/
systemctl daemon-reload
systemctl restart kubelet

```

### 8\.3 资源回滚恢复

集群资源异常时，导入升级前备份的全量资源清单，恢复集群业务状态。

## 9\. 离线升级常见问题与排错

- **镜像拉取失败**：Harbor无对应新版本镜像、镜像地址不匹配，提前补传完整镜像

- **版本不兼容报错**：大版本跳跃升级导致API不匹配，严格遵守小版本迭代规则

- **节点升级后NotReady**：kubelet未重启、配置未刷新、cgroup参数异常，重读配置重启组件

- **CoreDNS启动失败**：镜像版本不兼容、网络插件未同步升级，统一配套组件版本

- **业务Pod调度异常**：节点版本混杂，等待所有节点升级完成统一版本

## 10\. 生产升级红线规范

- 禁止生产集群跨大版本跳跃升级，必须逐小版本迭代

- 禁止离线环境未提前上传新版本镜像直接执行升级

- 禁止多台Worker节点同时升级，击穿集群容错能力

- 禁止集群异常、业务高峰期执行版本升级操作

- 禁止升级前不备份证书、配置、资源清单，无回滚兜底

- 禁止升级后未完成全维度验收直接交付业务

## 11\. 关联文档

- 节点入网扩容：`node-join.md`

- 节点下线缩容：`node-remove.md`

- 节点在线维护：`node-maintenance.md`

- 节点日常管理：`worker-node-management.md`

