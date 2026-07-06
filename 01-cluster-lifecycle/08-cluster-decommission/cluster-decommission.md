# cluster-decommission.md
## 一、文档基础信息
- 适用场景：自建K8s下线销毁、云托管集群（ACK/EKS/GKE/AKS）释放、集群淘汰/机房下线/业务迁移完成后回收资源
- 前置依赖：`cluster-migration.md`、`etcd-backup.md`、`05-kubeconfig-management/`
- 核心目标：安全下线集群、清理业务数据、销毁证书、回收硬件/云资源、防泄露、完整审计流程
- 集群基准：v1.32.13 单Master + 2 Worker Ubuntu22.04

## 二、集群下线核心理论与约束
### 2.1 下线前置判定标准（必须全部满足）
1. 全部业务已迁移至新集群，流量100%切离旧集群；
2. 7天业务监控无告警、无访问日志流入旧集群；
3. 全量资源、密钥、etcd快照已异地备份留存；
4. 存储PV、本地持久化数据完成导出备份；
5. 无定时任务、CI/CD、监控组件继续调用旧集群API；
6. 相关域名、内网DNS、hosts解析已移除旧集群地址。

### 2.2 下线两类风险
1. **数据泄露风险**
   Secret、证书、etcd数据、业务配置、数据库PV残留，服务器回收后数据被读取；
2. **残留访问风险**
   未清理kubeconfig、自动化脚本仍请求旧APIServer，引发大量报错；
3. **资源浪费风险（云集群）**
   节点、负载均衡、存储盘、镜像仓库持续计费，未释放产生多余成本。

### 2.3 下线整体顺序（不可逆）
业务流量切离 → 业务资源清理 → 集群组件停机 → 销毁etcd/存储数据 → 清理证书配置 → 节点重置/销毁 → 镜像仓库清理 → 归档备份记录

## 三、自建kubeadm集群完整下线流程
### 3.1 阶段1：业务侧前置清理（Master执行）
1. 确认无业务流量
```bash
# 查看集群访问事件、Pod访问日志
kubectl get events -A --sort-by=.lastTimestamp
# 查看所有运行业务Pod
kubectl get pods -A | grep -v kube-system
```
2. 导出最终全量备份（最终兜底快照）
```bash
# 1. 导出全部资源yaml
mkdir -p /usr/local/src/cluster-final-backup
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}');do
kubectl get all,configmap,secret,pvc,ingress -n $ns -o yaml > /usr/local/src/cluster-final-backup/ns-${ns}.yaml
done
kubectl get crd,clusterrole,clusterrolebinding,storageclass -o yaml > /usr/local/src/cluster-final-backup/cluster-res.yaml

# 2. 生成最终etcd快照（参考 etcd-backup.md）
export ETCDCTL_API=3
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.168.11.161:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save /usr/local/src/cluster-final-backup/etcd-final.db
```
3. 删除所有业务命名空间
```bash
# 排除kube-system/kube-public/kube-node-lease系统ns
for ns in $(kubectl get ns --no-headers | grep -v kube- | awk '{print $1}');do
kubectl delete ns $ns
done
```

### 3.2 阶段2：清空集群系统负载
```bash
# 删除metrics-server、calico等附加组件
kubectl delete -f /usr/local/src/metrics-server/components.yaml
kubectl delete -f /usr/local/src/calico/calico.yaml

# 清空kube-system内自定义资源
kubectl delete all -n kube-system --all
```

### 3.3 阶段3：所有节点执行kubeadm重置清理
#### Master节点
```bash
# 重置集群，清空kubelet、etcd、静态Pod配置
kubeadm reset -f
# 删除集群证书目录
rm -rf /etc/kubernetes
# 删除etcd持久化数据
rm -rf /var/lib/etcd
# 删除CRI容器镜像数据
rm -rf /var/lib/containerd
# 删除本地kubectl配置
rm -rf ~/.kube
# 删除部署源码、kubeconfig、备份（如需彻底销毁）
rm -rf /usr/local/src/kubeconfig /usr/local/src/calico /usr/local/src/metrics-server
```

#### 所有Worker节点统一执行
```bash
kubeadm reset -f
rm -rf /etc/kubernetes /var/lib/kubelet ~/.kube
rm -rf /var/lib/containerd
```

### 3.4 阶段4：系统层面彻底清理
1. 卸载k8s三件套deb包
```bash
apt-mark unhold kubeadm kubelet kubectl
apt remove -y kubeadm kubelet kubectl
apt autoremove -y
# 删除k8s apt源
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -rf /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```
2. 清理hosts静态解析
```bash
sed -i '/k8s-master/d;/k8s-worker/d;/harbor.jinshaoyong.com/d' /etc/hosts
```
3. 关闭内核转发参数（恢复系统默认）
```bash
sed -i '/net.bridge.bridge-nf-call/d;/net.ipv4.ip_forward/d' /etc/sysctl.conf
sysctl -p
```

### 3.5 阶段5：内网Harbor配套清理（集群配套镜像仓库）
```bash
# 进入harbor部署目录执行垃圾回收，删除集群相关系统镜像
cd /usr/local/src/harbor
docker-compose down
# 执行registry垃圾回收
docker run --rm -v ./data:/var/lib/registry -v ./config/registry.yml:/etc/registry/config.yml goharbor/registry-photon:stable garbage-collect /etc/registry/config.yml
# 删除k8s项目下所有v1.32系统镜像tag
```

### 3.6 阶段6：服务器下线处置
1. 短期复用机器：重装系统Ubuntu22.04，全盘格式化；
2. 永久报废服务器：物理销毁硬盘，防止数据残留泄露；
3. 归档备份文件迁移至异地存储，保留90天。

## 四、云托管K8s集群下线流程（ACK/EKS/GKE/AKS）
### 4.1 云集群分层下线逻辑
云集群分为**节点池**与**托管控制平面**，分开清理：
1. 业务层：切流量、删除工作负载、导出备份；
2. 节点池：分批缩容删除所有节点；
3. 控制平面：控制台释放集群；
4. 配套资源：释放云磁盘、负载均衡、安全组、容器镜像仓库。

### 4.2 分步操作
1. 业务迁移确认，导出全集群资源yaml备份；
2. 删除所有命名空间业务资源、Ingress、Service、CRD；
3. 节点池缩容至0台，释放ECS/虚拟机；
4. 控制台提交删除集群，厂商自动销毁托管Master/etcd；
5. 释放关联云资源：云硬盘、SLB、镜像仓库实例、域名解析；
6. 清理本地电脑所有对应集群kubeconfig context。

### 4.3 云集群特殊风险
- 云磁盘不会随集群删除自动销毁，需手动释放，持续扣费；
- 私有镜像仓库独立计费，需单独删除实例或清理镜像；
- 负载均衡、公网IP若未解绑会持续产生费用。

## 五、下线后残留清理（本地运维机器）
```bash
# 删除旧集群context、cluster、user配置
kubectl config delete-context kubernetes-admin@kubernetes
kubectl config delete-cluster kubernetes
kubectl config delete-user kubernetes-admin
# 删除离线kubeconfig文件
rm -rf /usr/local/src/kubeconfig
# 删除本地离线镜像tar包
rm -rf /usr/local/src/k8s-images
```

## 六、下线回退补救（未完全销毁前）
1. 仅删除业务资源、未执行kubeadm reset：
   使用前置etcd快照 `etcd-final.db` 执行 `etcd-restore.md` 恢复集群；
2. 已执行kubeadm reset但未格式化服务器：
   重新执行 `kubeadm init`，导入备份yaml重建业务；
3. 云集群仅删除节点池、未删除控制平面：
   重新新建节点池，kubelet加入原有控制平面恢复业务。

## 七、安全下线规范
1. 所有Secret、证书、etcd数据必须彻底删除，禁止留存裸机；
2. 对外分发的kubeconfig全部回收删除；
3. 下线备份文件加密归档，设置访问权限600；
4. 生产集群下线必须双人复核，留存下线操作审计日志；
5. 内网Harbor废弃系统镜像全部垃圾回收，减少存储占用。

## 八、常见下线故障
1. **删除namespace卡死**
   存在Finalizer阻塞资源，编辑资源移除finalizer字段后再删除；
2. **kubeadm reset 端口占用**
   停止containerd、kubelet后重新执行重置；
3. **云集群删除失败，提示资源绑定**
   检查是否存在未释放PV、SLB、域名绑定，先解绑再删除集群；
4. **服务器重装后仍有旧集群残留配置**
   全盘格式化系统盘，彻底清除/var/lib/containerd、/var/lib/etcd数据。

## 九、关联文档
1. 数据备份兜底：`etcd-backup.md`
2. 集群迁移前置：`cluster-migration.md`
3. kubeconfig清理：`05-kubeconfig-management/15-troubleshooting.md`
4. 故障处理：`10-troubleshooting.md`