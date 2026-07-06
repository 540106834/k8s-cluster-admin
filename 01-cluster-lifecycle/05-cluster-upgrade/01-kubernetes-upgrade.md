# kubernetes-upgrade.md
## 一、文档基础信息
### 集群环境
- 集群版本：当前 v1.32.13
- 目标：同小版本迭代升级（v1.32.x），不跨大版本（禁止直接升到 v1.33）
- 集群架构：单 Master + 2 Worker，Ubuntu 22.04
- CRI：containerd 2.1.5
- CNI：Calico v3.30.4
- 镜像仓库：`harbor.jinshaoyong.com/k8s`
- 安装方式：APT deb 包固定版本安装
- 前置要求：升级前完成完整 etcd 快照备份（参考 08-post-install.md）

### 关联文档
前置：03-cluster-planning.md、08-post-install.md、04-harbor.md
故障兜底：10-troubleshooting.md、09-upgrade.md

## 二、升级约束规范
1. **版本升级顺序**：仅支持补丁版本递增（1.32.13 → 1.32.xx），跨大版本需单独评估
2. **镜像前置**：升级前必须将新版本全套控制平面镜像上传 Harbor `k8s` 项目
3. **滚动原则**：Worker 节点单台依次升级，不可同时驱逐多台业务节点
4. **版本锁定**：升级完成必须执行 `apt-mark hold`，避免系统自动更新
5. **离线环境**：无法访问外网APT源时，提前下载对应deb离线包部署
6. **组件对齐**：kubeadm / kubelet / kubectl 三者版本必须完全一致

## 三、升级前置校验（Master节点执行）
```bash
# 1. 确认当前集群版本
kubectl version
kubeadm version

# 2. 集群健康检查
kubectl get nodes
kubectl get pods -n kube-system
kubectl get cs

# 3. 执行etcd全量快照备份（必做）
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save /usr/local/src/etcd-pre-upgrade-$(date +%Y%m%d).db

# 4. 检查APT源是否存在目标版本
apt-cache madison kubeadm

# 5. 校验Harbor是否存在新版本镜像
curl -s http://harbor.jinshaoyong.com/v2/k8s/tags/list | grep v1.32.XX

# 6. 确认Calico、metrics-server对应兼容镜像已上传Harbor
```

## 四、整体升级流程
1. Master：更新kubeadm → 预览升级计划 → 执行控制平面升级
2. Master：升级kubelet、kubectl，重启kubelet
3. 逐台Worker：驱逐Pod → 升级三件套 → 重启kubelet → 恢复调度
4. 升级Calico网络插件
5. 同步升级metrics-server
6. 全集群验证连通性、资源指标、业务可用性

## 五、步骤1 Master节点升级 kubeadm
```bash
# 1. 解除版本锁定
apt-mark unhold kubeadm kubelet kubectl

# 2. 定义目标版本（替换为实际目标版本，例 1.32.14-1.1）
TARGET_VER=1.32.XX-1.1
apt install -y kubeadm=${TARGET_VER}

# 3. 重新锁定kubeadm防止自动更新
apt-mark hold kubeadm

# 校验版本
kubeadm version
```

## 六、步骤2 预览升级规划
```bash
kubeadm upgrade plan --image-repository harbor.jinshaoyong.com/k8s
```
校验要点：
1. 输出目标版本与预期一致
2. 镜像仓库地址为内网Harbor
3. 无严重预检失败报错

## 七、步骤3 执行控制平面升级
```bash
kubeadm upgrade apply v1.32.XX \
--image-repository harbor.jinshaoyong.com/k8s \
--yes
```
执行后apiserver、controller-manager、scheduler、etcd、coredns Pod会滚动重建。

## 八、步骤4 Master节点升级kubelet & kubectl
```bash
# 升级剩余两个组件
apt install -y kubelet=${TARGET_VER} kubectl=${TARGET_VER}
# 全部锁定
apt-mark hold kubeadm kubelet kubectl

# 重载systemd并重启kubelet
systemctl daemon-reload
systemctl restart kubelet

# 验证版本
kubelet --version
kubectl version --client
```

## 九、步骤5 Worker节点分批升级（两台依次操作）
### 9.1 Master端：驱逐节点业务Pod
```bash
kubectl drain k8s-worker-01 --delete-emptydir-data --force --ignore-daemonsets
```
### 9.2 Worker节点内部执行升级
```bash
# 解锁
apt-mark unhold kubeadm kubelet kubectl
TARGET_VER=1.32.XX-1.1
apt install -y kubeadm=${TARGET_VER} kubelet=${TARGET_VER} kubectl=${TARGET_VER}
# 锁定版本
apt-mark hold kubeadm kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet
```
### 9.3 Master端恢复节点调度
```bash
kubectl uncordon k8s-worker-01
kubectl get nodes
```
完成一台后重复流程升级 `k8s-worker-02`。

## 十、步骤6 升级Calico网络插件
```bash
cd /usr/local/src
# 下载对应Calico版本yaml
wget https://docs.projectcalico.org/v3.30/manifests/calico.yaml

# 替换镜像仓库为内网Harbor
sed -i 's|docker.io/calico|harbor.jinshaoyong.com/k8s|g' calico.yaml
# 替换Pod网段匹配集群10.32.0.0/16
sed -i 's|10.244.0.0/16|10.32.0.0/16|g' calico.yaml

# 滚动更新Calico
kubectl apply -f calico.yaml

# 等待calico-node全部Running
kubectl get pods -n kube-system -w | grep calico
```

## 十一、步骤7 同步升级 metrics-server
```bash
cd /usr/local/src
wget https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
sed -i 's|registry.k8s.io/metrics-server|harbor.jinshaoyong.com/k8s|g' components.yaml
kubectl apply -f components.yaml

# 等待Pod就绪
kubectl get pods -n kube-system | grep metrics-server
```

## 十二、升级后全集群验证
```bash
# 1. 所有节点版本统一
kubectl get nodes

# 2. 系统组件全部Running
kubectl get pods -n kube-system

# 3. 资源指标正常
kubectl top nodes
kubectl top pods -A

# 4. Pod跨节点网络连通测试
kubectl run upgrade-test --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 3600
kubectl exec upgrade-test -- ping -c 4 10.32.0.10
kubectl delete pod upgrade-test

# 5. 控制平面组件健康
kubectl get cs
```

## 十三、故障回滚方案
### 13.1 组件版本降级（小故障）
```bash
# 解锁三件套
apt-mark unhold kubeadm kubelet kubectl
# 降级回原版本 1.32.13-1.1
apt install -y kubeadm=1.32.13-1.1 kubelet=1.32.13-1.1 kubectl=1.32.13-1.1
apt-mark hold kubeadm kubelet kubectl
systemctl restart kubelet
```

### 13.2 集群数据完全回滚（升级严重异常）
1. 停止kube-apiserver、controller-manager、scheduler静态Pod
2. 使用升级前etcd快照执行数据恢复
3. 降级kubeadm/kubelet/kubectl至旧版本
4. 重新执行旧版本 `kubeadm upgrade apply`

### 13.3 Calico回滚
替换为升级前旧版本calico.yaml执行 `kubectl apply -f`

## 十四、常见故障排查
1. **kubeadm upgrade 镜像拉取404**
   Harbor k8s项目缺失目标版本镜像，提前上传全套控制平面镜像。
2. **节点升级后状态 NotReady**
   查看kubelet日志、calico Pod状态，确认cgroup驱动为systemd。
3. **升级后 kubectl top 无指标**
   metrics-server镜像版本不兼容，同步升级对应版本。
4. **apt找不到目标升级版本**
   删除旧kubernetes/apt源，使用kubernetes-new分版本源。
5. **etcd升级后崩溃**
   使用升级前etcd快照恢复，整体回滚集群版本。

## 十五、运维注意事项
1. 升级操作建议业务低峰期执行，规避流量高峰。
2. 升级前确认Harbor镜像磁盘空间充足，避免镜像拉取失败。
3. 升级过程中禁止删除etcd备份快照。
4. 多Worker场景分批升级，避免业务全部驱逐导致服务不可用。
5. 离线环境提前下载所有deb包、yaml清单、镜像tar包。