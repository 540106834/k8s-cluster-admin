# etcd-restore.md
## 一、文档基础信息
- 适用集群：自建单Master K8s v1.32.13
- 前置文档：`etcd-backup.md`（必须有有效etcd v3快照文件）
- 前置条件：
  1. 集群完全停机，控制平面静态Pod停止
  2. 快照文件与当前etcd/K8s Minor版本完全一致
  3. 拥有etcd ca、server证书、私钥
- 作用：完整覆盖etcd快照恢复全流程、单节点集群恢复、异常校验、回退补救、云集群恢复说明
- 关联文档：`cluster-upgrade-theory-guide.md`、`10-troubleshooting.md`

## 二、etcd恢复底层理论约束（核心红线）
1. **版本强匹配**
   etcd快照仅能在**同Minor版本**集群恢复；跨大版本（1.32快照恢复到1.33）会数据格式不兼容，etcd启动失败。
2. **恢复为离线操作**
   snapshot restore 是离线工具，**etcd进程必须完全停止**，不能在线执行恢复。
3. **数据目录覆盖**
   恢复会重建整个/var/lib/etcd目录，原有数据必须提前备份迁移，不可直接覆盖。
4. **集群身份变更**
   单节点kubeadm集群恢复后集群ID会重置，无需额外配置；多Master高可用集群恢复后需重新初始化etcd集群。
5. **快照完整性前提**
   执行 `etcdctl snapshot status xxx.db` 无报错才能用于恢复，损坏快照直接丢弃。

## 三、恢复前置检查清单（必须全部通过）
```bash
# 1. 验证快照有效
export ETCDCTL_API=3
SNAP=/usr/local/src/etcd-backup/manual/etcd-snapshot-20260706.db
etcdctl snapshot status ${SNAP}

# 2. 确认etcd证书文件存在
ls /etc/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/server.crt /etc/kubernetes/pki/etcd/server.key

# 3. 停止kubelet，关闭所有控制平面静态Pod
systemctl stop kubelet
mkdir -p /etc/kubernetes/manifests/bak
mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests/bak/

# 4. 确认apiserver/etcd/controller已全部停止
crictl ps
```

## 四、步骤1 迁移原有损坏etcd数据目录（保留兜底）
```bash
# 重命名旧数据目录，作为故障兜底
mv /var/lib/etcd /var/lib/etcd-broken-$(date +%Y%m%d_%H%M)
# 新建空目录用于恢复数据
mkdir -p /var/lib/etcd
```

## 五、步骤2 执行离线快照恢复
```bash
export ETCDCTL_API=3
SNAP_FILE=/usr/local/src/etcd-backup/manual/etcd-snapshot-20260706.db
DATA_DIR=/var/lib/etcd

etcdctl snapshot restore ${SNAP_FILE} \
  --data-dir=${DATA_DIR}
```
执行成功输出示例：
```
2026-07-06 10:00:00 INFO  snapshot/v3: restored snapshot ...
```

## 六、步骤3 修正etcd目录权限（关键，否则kubelet启动失败）
etcd容器运行身份为root，目录权限错乱会导致etcd无法读写：
```bash
chmod -R 700 /var/lib/etcd
chown -R root:root /var/lib/etcd
```

## 七、步骤4 恢复控制平面静态Pod，重启集群
```bash
# 还原kubeadm静态manifest
mv /etc/kubernetes/manifests/bak/*.yaml /etc/kubernetes/manifests/
# 启动kubelet，自动拉起apiserver、etcd、controller-manager、scheduler
systemctl start kubelet
systemctl status kubelet
```

## 八、步骤5 恢复后集群完整性校验
等待3~5分钟控制平面完全启动，依次执行校验：
```bash
# 1. 控制平面组件健康
kubectl get cs

# 2. 所有节点正常识别
kubectl get nodes

# 3. 全部命名空间资源恢复
kubectl get all -A

# 4. 网络连通测试
kubectl run recover-test --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 3600
kubectl exec recover-test -- ping -c 4 10.32.0.10
kubectl delete pod recover-test

# 5. 核对etcd数据版本
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
version
```

## 九、升级失败回滚完整流程（业务高频场景）
场景：Minor大版本升级异常，使用升级前etcd快照回退集群
1. 执行前置停机：停止kubelet、迁移manifests清单
2. 降级kubeadm/kubelet/kubectl至原稳定版本
```bash
apt-mark unhold kubeadm kubelet kubectl
apt install -y kubeadm=1.32.13-1.1 kubelet=1.32.13-1.1 kubectl=1.32.13-1.1
apt-mark hold kubeadm kubelet kubectl
```
3. 清空/var/lib/etcd，执行快照恢复
4. 恢复静态Pod，启动kubelet
5. 执行旧版本kubeadm upgrade apply修复集群配置
```bash
kubeadm upgrade apply v1.32.13 --image-repository harbor.jinshaoyong.com/k8s --yes
```
6. 全集群校验资源、节点、网络、指标

## 十、云托管K8s etcd恢复说明
1. ACK/EKS/GKE/AKS用户无etcdctl操作权限，无法执行本地snapshot restore；
2. 云集群数据恢复两种方案：
   - 方案1：控制台选择平台自动备份快照一键回滚控制平面；
   - 方案2：通过预导出的全命名空间yaml重建所有业务资源；
3. 云集群恢复风险：仅能回滚至同Minor版本备份，跨版本备份不可用。

## 十一、恢复常见故障与修复
### 1. snapshot restore 报错 snapshot mismatch
快照版本与当前etcd版本不一致，更换同Minor版本快照。
### 2. kubelet启动后etcd容器反复Crash
- /var/lib/etcd权限非700；
- 快照文件损坏，重新备份；
- 磁盘空间不足，清理磁盘再恢复。
### 3. apiserver启动失败，连接etcd拒绝
检查etcd证书路径、etcd进程是否正常监听2379。
### 4. 恢复后部分资源丢失
快照生成时间早于新增业务，选择时间更近的快照文件重新恢复。
### 5. 恢复后节点长期NotReady
集群数据回退至旧版本，Calico/metrics-server资源被重置，重新应用对应yaml。

## 十二、运维规范
1. 恢复操作必须业务低峰执行，提前通知业务；
2. 恢复完成后留存旧etcd数据目录7天，确认业务稳定再删除；
3. 每季度执行一次快照恢复演练，验证备份可用性；
4. 恢复完成后立即重新生成一份全新etcd快照；
5. 快照文件统一权限600，禁止非管理员读取。

## 十三、关联文档
1. 前置：`etcd-backup.md` 快照生成规范
2. 升级场景：`cluster-upgrade-theory-guide.md` 升级回滚依赖
3. 故障排查：`10-troubleshooting.md` etccd数据丢失故障处理