# kubernetes-major-upgrade.md（大版本跨代升级文档，例 v1.32 → v1.33）
## 一、文档基础信息
### 集群环境
- 当前运行版本：v1.32.13
- 目标跨代大版本：v1.33.x
- 集群架构：单Master + 2 Worker，Ubuntu 22.04 LTS
- CRI：containerd 2.1.5（大版本升级前确认兼容K8s v1.33，不兼容则同步升级containerd）
- CNI：Calico v3.30.4，升级至适配v1.33的Calico新版本
- 指标组件：metrics-server v0.7.2，同步替换兼容新版本
- 私有镜像仓库：`harbor.jinshaoyong.com/k8s`
- 安装方式：APT `kubernetes-new` 分版本源安装deb包
- 核心区别：小版本补丁升级仅滚动更新；**大版本跨代升级存在API弃用、组件兼容、CRI/CNI适配、存储数据迁移风险**，必须完整预演、全量备份

### 关联文档
前置：03-cluster-planning.md、08-post-install.md、04-harbor.md、kubernetes-upgrade.md
故障兜底：10-troubleshooting.md

## 二、大版本升级硬性约束（不可跳过）
1. **递进升级规则**
   K8s仅支持**顺序跨一个大版本**：1.32 → 1.33，禁止直接 1.32 → 1.34，需分步升级。
2. **兼容性前置校验清单**
   - containerd/runc 兼容目标K8s大版本
   - Calico、metrics-server、自研控制器支持新API组
   - 业务CRD、自定义控制器无废弃API（如已移除v1beta1资源）
3. **镜像全量预上传**
   升级前Harbor `k8s` 项目必须提前上传：
   kube-apiserver、kube-controller-manager、kube-scheduler、etcd、coredns、pause 全套v1.33镜像
4. **离线环境准备**
   提前下载v1.33全套kubeadm/kubelet/kubectl deb包、新版Calico yaml、新版metrics-server镜像tar包
5. **业务停机窗口**
   大版本升级存在静态Pod重建、API变更风险，必须选择业务低峰，预留1~2小时维护窗口
6. **完整数据备份**
   至少2份etcd快照（升级前1h、升级前5min），导出所有命名空间资源yaml做离线备份

## 三、升级前置全量检查（Master节点执行）
### 3.1 集群健康校验
```bash
# 节点全部Ready，无污点异常
kubectl get nodes
# 系统组件无CrashLoopBackOff
kubectl get pods -n kube-system
# 控制平面健康
kubectl get cs
# 无废弃API资源检测（关键，大版本极易报错）
kubectl api-resources --verbs=list --output wide | grep v1beta
# 检查集群事件，无持续报错
kubectl get events -A --sort-by='.lastTimestamp'
```

### 3.2 全量资源导出备份
```bash
mkdir -p /usr/local/src/cluster-backup-pre-major-upgrade
# 导出所有命名空间资源
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}');do
  kubectl get all -n $ns -o yaml > /usr/local/src/cluster-backup-pre-major-upgrade/${ns}-all.yaml
done
# 导出集群级资源
kubectl get crd,clusterroles,clusterrolebindings -o yaml > /usr/local/src/cluster-backup-pre-major-upgrade/cluster-resources.yaml
```

### 3.3 etcd双重快照备份
```bash
# 第一份快照
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save /usr/local/src/etcd-pre-major-upgrade-1.db

# 等待5分钟再生成第二份快照
sleep 300
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save /usr/local/src/etcd-pre-major-upgrade-2.db
```

### 3.4 APT源切换目标大版本分支
```bash
# 删除旧1.32源配置
rm -f /etc/apt/sources.list.d/kubernetes.list
mkdir -p -m 755 /etc/apt/keyrings
# 导入v1.33源密钥
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
# 写入v1.33专属源
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.33/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt clean && apt update
# 确认可安装v1.33版本
apt-cache madison kubeadm
```

### 3.5 Harbor镜像校验
```bash
# 替换为目标版本v1.33.x
TARGET_MAJOR=v1.33
curl -s http://harbor.jinshaoyong.com/v2/k8s/tags/list | grep ${TARGET_MAJOR}
```

## 四、大版本升级整体执行顺序（严格不可逆）
1. Master节点：升级kubeadm至v1.33.x → 执行upgrade plan预检大版本兼容问题
2. Master节点：kubeadm upgrade apply 升级控制平面静态Pod
3. Master节点：升级kubelet、kubectl，重启kubelet
4. 逐台Worker节点：drain驱逐业务 → 升级三件套 → 重启kubelet → uncordon恢复调度
5. 升级适配v1.33的Calico新版本
6. 升级兼容v1.33的metrics-server
7. 全集群连通性、业务、API兼容性验证
8. 留存所有备份快照7天，观察业务稳定性

## 五、步骤1 Master升级kubeadm至目标大版本
```bash
# 解除版本锁定
apt-mark unhold kubeadm kubelet kubectl
# 定义目标完整版本，示例 1.33.0-1.1
TARGET_VER=1.33.0-1.1
apt install -y kubeadm=${TARGET_VER}
# 临时锁定kubeadm
apt-mark hold kubeadm
kubeadm version
```

## 六、步骤2 大版本升级预检（关键，报错必须全部修复再继续）
```bash
kubeadm upgrade plan --image-repository harbor.jinshaoyong.com/k8s
```
重点排查：
1. API弃用警告、废弃资源提示
2. CRI/etcd版本兼容性告警
3. 证书、配置文件不兼容报错
4. 镜像仓库地址是否为内网Harbor

存在任意ERROR级报错，停止升级，修复后重新执行plan。

## 七、步骤3 执行控制平面跨代升级
```bash
kubeadm upgrade apply v1.33.0 \
--image-repository harbor.jinshaoyong.com/k8s \
--yes
```
执行过程变化：
1. apiserver/controller/scheduler/etcd/coredns静态Pod全部滚动重建
2. kubeadm自动更新 `/etc/kubernetes/` 集群配置、证书参数
3. 内部API协议、存储参数同步更新适配v1.33

## 八、步骤4 Master升级kubelet & kubectl
```bash
apt install -y kubelet=${TARGET_VER} kubectl=${TARGET_VER}
# 三件套全部锁定防止自动更新
apt-mark hold kubeadm kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
# 验证版本对齐
kubelet --version
kubectl version
```

## 九、步骤5 Worker节点分批升级（单台操作，不可并行）
### 9.1 Master端驱逐节点负载
```bash
kubectl drain k8s-worker-01 --delete-emptydir-data --force --ignore-daemonsets
```
### 9.2 Worker节点升级三件套
```bash
apt-mark unhold kubeadm kubelet kubectl
TARGET_VER=1.33.0-1.1
apt install -y kubeadm=${TARGET_VER} kubelet=${TARGET_VER} kubectl=${TARGET_VER}
apt-mark hold kubeadm kubelet kubectl
systemctl daemon-reload
systemctl restart kubelet
```
### 9.3 恢复调度
```bash
kubectl uncordon k8s-worker-01
kubectl get nodes
```
完成worker-01后，重复流程升级worker-02。

## 十、步骤6 升级适配v1.33的Calico
```bash
cd /usr/local/src
# 替换为支持v1.33的Calico版本，示例v3.31.x
CALICO_VER=v3.31
wget https://docs.projectcalico.org/${CALICO_VER}/manifests/calico.yaml
# 替换镜像仓库
sed -i 's|docker.io/calico|harbor.jinshaoyong.com/k8s|g' calico.yaml
# 替换Pod网段
sed -i 's|10.244.0.0/16|10.32.0.0/16|g' calico.yaml
# 滚动更新
kubectl apply -f calico.yaml
# 等待全部calico-node Running
kubectl get pods -n kube-system -w | grep calico
```

## 十一、步骤7 升级兼容v1.33 metrics-server
```bash
cd /usr/local/src
# 使用适配v1.33的metrics-server版本
METRICS_VER=v0.7.3
wget https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_VER}/components.yaml
sed -i 's|registry.k8s.io/metrics-server|harbor.jinshaoyong.com/k8s|g' components.yaml
# 保留跳过kubelet证书参数
sed -i '/        args:/a\        - --kubelet-insecure-tls' components.yaml
kubectl apply -f components.yaml
kubectl get pods -n kube-system | grep metrics-server
```

## 十二、大版本升级后全维度验证
```bash
# 1. 所有节点统一为v1.33.x
kubectl get nodes
# 2. 系统组件无异常Pod
kubectl get pods -n kube-system
# 3. 控制平面健康
kubectl get cs
# 4. 资源指标正常
kubectl top nodes
kubectl top pods -A
# 5. 跨节点Pod网络连通
kubectl run major-upgrade-test --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 3600
kubectl exec major-upgrade-test -- ping -c 4 10.32.0.10
kubectl delete pod major-upgrade-test
# 6. 校验废弃API资源是否仍可正常访问
kubectl get all --all-namespaces
# 7. 业务应用功能自测（核心业务流程）
```

## 十三、大版本升级回滚方案（风险远高于小版本升级）
### 13.1 轻度异常：仅降级kube组件
```bash
apt-mark unhold kubeadm kubelet kubectl
# 回退原版本v1.32.13-1.1
apt install -y kubeadm=1.32.13-1.1 kubelet=1.32.13-1.1 kubectl=1.32.13-1.1
apt-mark hold kubeadm kubelet kubectl
systemctl restart kubelet
```

### 13.2 中度异常：控制平面配置错乱
1. 降级kubeadm至v1.32.13
2. 执行旧版本 `kubeadm upgrade apply v1.32.13` 修复静态Pod配置

### 13.3 严重故障：etcd数据不兼容、API大面积失效（核心回滚）
1. 停止所有Master静态Pod（kube-apiserver/controller/scheduler/etcd）
2. 使用升级前etcd快照 `etcd-pre-major-upgrade-1.db` 完整恢复etcd数据
3. 全节点kubeadm/kubelet/kubectl降级回v1.32.13
4. 重新执行v1.32版本kubeadm upgrade apply修复集群
5. 回滚Calico、metrics-server至旧版本yaml

## 十四、大版本升级高频故障
1. **kubeadm plan 大量API弃用告警**
   提前改造业务yaml，删除废弃v1beta1 API，替换为稳定v1版本资源。
2. **镜像拉取404**
   Harbor缺少v1.33全套系统镜像，停止升级，补齐镜像后重试。
3. **升级后节点NotReady**
   containerd/runc不兼容新K8s版本，同步升级CRI；或Calico版本不匹配。
4. **etcd启动失败**
   大版本etcd存储格式变更，必须使用升级前快照完整回滚集群。
5. **kubectl top 无指标**
   metrics-server版本不兼容目标K8s大版本，更换适配版本。
6. **业务Pod无法创建，API报错不支持字段**
   大版本移除废弃字段，修改业务资源yaml删除废弃参数。

## 十五、运维特殊注意事项
1. 大版本升级后7天内禁止清理etcd备份快照、集群资源备份yaml；
2. 升级完成后同步更新所有运维工具、CI/CD、监控对接组件适配新K8s API；
3. 若集群使用自定义CRD/Operator，必须提前确认厂商兼容v1.33；
4. 离线环境需提前打包新版containerd、runc二进制，防止CRI不兼容；
5. 生产环境建议先搭建一套同配置测试集群，完整复现大版本升级流程，验证业务无异常后再操作生产集群。