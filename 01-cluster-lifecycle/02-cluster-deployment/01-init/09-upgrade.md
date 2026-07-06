# 09-upgrade.md
## 一、文档基础信息
- 适用集群：单Master K8s v1.32.13
- 系统：Ubuntu 22.04 LTS
- 组件安装方式：kubeadm/kubelet/kubectl APT DEB安装
- 容器运行时：containerd 2.1.5-1（离线deb）
- 网络插件：Calico v3.30.4
- 镜像仓库：`harbor.jinshaoyong.com/k8s`
- 升级逻辑：控制面优先升级 → 逐台Worker升级，版本只能小版本递增，不跨大版本
- 前置要求：升级前执行 `08-post-install.md` etcd 快照备份

## 二、集群信息
| 主机名 | IP | 角色 |
|--------|----|------|
| k8s-master-01 | 192.168.11.161 | 单控制面 |
| k8s-worker-01 | 192.168.11.162 | 工作节点 |
| k8s-worker-02 | 192.168.11.163 | 工作节点 |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库 |

## 三、升级前置校验（Master节点执行）
```bash
# 1. 当前集群版本确认
kubectl version
kubeadm version

# 2. 所有节点Ready，无异常Pod
kubectl get nodes
kubectl get pods -n kube-system

# 3. 完整etcd快照备份（必须）
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save /usr/local/src/etcd-pre-upgrade-$(date +%Y%m%d).db

# 4. 确认内网Harbor已预上传新版本全套控制平面镜像
curl -k http://harbor.jinshaoyong.com/k8s/v2/_catalog

# 5. 确认APT源存在目标新版本（使用kubernetes-new v1.XX源）
apt-cache madison kubeadm
```

## 四、升级流程总顺序
1. Master节点：更新kubeadm → kubeadm upgrade plan → kubeadm upgrade apply
2. Master节点：升级kubelet、kubectl，重启kubelet
3. 逐台Worker节点：驱逐Pod → 升级kubeadm/kubelet/kubectl → 重启kubelet
4. 更新Calico镜像/清单版本
5. 集群验证、资源指标验证

## 五、步骤1 Master节点升级kubeadm（DEB）
```bash
# 1. 取消版本锁定
apt-mark unhold kubeadm kubelet kubectl

# 2. 安装目标版本（示例v1.32.XX，替换为实际目标版本）
TARGET_VER=1.32.XX-1.1
apt install -y kubeadm=${TARGET_VER}

# 3. 重新锁定kubeadm，防止自动升级
apt-mark hold kubeadm

# 校验kubeadm新版本
kubeadm version
```

## 六、步骤2 查看升级规划，确认可升级
```bash
kubeadm upgrade plan --image-repository harbor.jinshaoyong.com/k8s
```
输出重点确认：
- 目标版本匹配预期
- 镜像仓库为内网harbor.jinshaoyong.com/k8s
- 无严重预检报错

## 七、步骤3 执行控制平面升级（Master）
```bash
kubeadm upgrade apply v1.32.XX \
--image-repository harbor.jinshaoyong.com/k8s \
--yes
```
升级完成后，apiserver/controller/scheduler/etcd/coredns会滚动更新镜像。

## 八、步骤4 Master节点升级kubelet & kubectl
```bash
# 升级kubelet、kubectl至同版本
apt install -y kubelet=${TARGET_VER} kubectl=${TARGET_VER}
# 锁定全部组件
apt-mark hold kubeadm kubelet kubectl

# 重启kubelet生效
systemctl daemon-reload
systemctl restart kubelet

# 验证版本
kubelet --version
kubectl version
```

## 九、步骤5 Worker节点逐台升级（两台依次操作，不可同时）
### 9.1 Master操作：驱逐节点业务Pod
```bash
# 驱逐worker-01，业务Pod调度至其他节点
kubectl drain k8s-worker-01 --delete-emptydir-data --force --ignore-daemonsets
```

### 9.2 Worker节点内部升级
```bash
# 解锁
apt-mark unhold kubeadm kubelet kubectl
# 安装目标版本
TARGET_VER=1.32.XX-1.1
apt install -y kubeadm=${TARGET_VER} kubelet=${TARGET_VER} kubectl=${TARGET_VER}
# 锁定版本
apt-mark hold kubeadm kubelet kubectl

# 重载并重启kubelet
systemctl daemon-reload
systemctl restart kubelet
```

### 9.3 Master恢复节点调度
```bash
kubectl uncordon k8s-worker-01
kubectl get nodes
```
重复流程升级 `k8s-worker-02`。

## 十、步骤6 更新Calico网络组件（对应新版本v3.XX.X）
```bash
cd /usr/local/src
# 下载对应新版本calico.yaml
wget https://docs.projectcalico.org/v3.XX/manifests/calico.yaml
# 替换镜像仓库
sed -i 's|docker.io/calico|harbor.jinshaoyong.com/k8s|g' calico.yaml
# 替换Pod网段
sed -i 's|10.244.0.0/16|10.32.0.0/16|g' calico.yaml
# 滚动升级Calico
kubectl apply -f calico.yaml

# 等待calico-node全部重建Running
kubectl get pods -n kube-system -w | grep calico
```

## 十一、升级后全集群验证
```bash
# 1. 所有节点版本统一为目标版本
kubectl get nodes

# 2. 所有系统Pod Running
kubectl get pods -n kube-system

# 3. 资源指标正常
kubectl top nodes
kubectl top pods -A

# 4. Pod跨节点通信正常
kubectl run test-upgrade --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 1800
kubectl exec test-upgrade -- ping -c 4 10.32.x.x
kubectl delete pod test-upgrade

# 5. 控制平面组件健康
kubectl get cs
```

## 十二、回滚方案（升级异常故障）
### 12.1 回滚kubeadm/kubelet/kubectl旧版本
```bash
apt-mark unhold kubeadm kubelet kubectl
apt install -y kubeadm=1.32.13-1.1 kubelet=1.32.13-1.1 kubectl=1.32.13-1.1
apt-mark hold kubeadm kubelet kubectl
systemctl restart kubelet
```
### 12.2 控制平面回滚（etcd快照恢复，严重故障）
1. 停止kube-apiserver/controller/scheduler
2. 使用升级前etcd快照恢复数据
3. 重新执行旧版本kubeadm upgrade apply
### 12.3 Calico回滚
重新部署升级前旧版本calico.yaml

## 十三、升级规范与注意事项
1. **版本规则**：仅支持小版本递增（1.32.13 → 1.32.XX），禁止跨大版本（1.32→1.33）
2. **镜像前置**：升级前必须将新版本所有k8s/calico/metrics-server镜像上传Harbor `k8s`项目
3. **滚动升级**：Worker单台依次升级，不可同时驱逐多台节点
4. **业务影响**：drain会驱逐普通Pod，DaemonSet（calico-node）不受影响
5. **锁定版本**：升级完成务必执行`apt-mark hold`，避免系统自动更新
6. **断网适配**：外网无法下载新版本deb，使用离线deb包上传安装

## 十四、常见故障排查
1. **kubeadm upgrade 镜像拉取404**
   检查Harbor `k8s`项目是否存在目标版本控制平面镜像
2. **节点升级后NotReady**
   检查calico Pod状态、kubelet日志、cgroup驱动是否systemd
3. **升级后kubectl top无数据**
   同步升级metrics-server镜像至对应兼容版本
4. **etcd升级崩溃**
   使用升级前快照恢复，回滚至旧版本集群
5. **apt找不到目标版本**
   确认使用`kubernetes-new`分版本源，清理旧kubernetes.list重新配置

## 十五、上下游文档关联
- 上游：08-post-install.md 集群验收&etcd备份策略
- 依赖仓库：04-harbor.md 镜像上传维护
- 运行时：02-containerd.md 镜像仓库tls配置
- 故障汇总：10-troubleshooting.md 集群升级失败回滚章节