# build-storage-platform.md
# K8s NFS 共享存储平台部署 & CSI 完整运维手册
## 一、文档定位
本文面向自建机房/私有云企业集群，搭建**NFS 共享存储服务端 + K8s NFS CSI 客户端**整套持久化存储平台；包含 NFS 服务端部署、权限优化、K8s CSI 驱动安装、StorageClass 动态供给、PV/PVC 生命周期、快照扩容、故障排查、生产安全规范。
前置依赖：
build-kubernetes-cluster.md 集群基础环境就绪
validate-cluster-health.md 集群交付存储验收标准
backup-etcd-cluster.md 集群数据备份规范
下游关联：replace-worker-node.md、06-network-debug.md

## 二、整体架构说明
### 2.1 分层架构
1. **底层存储层**：物理磁盘/RAID/云硬盘，挂载至NFS服务端服务器
2. **NFS服务层**：独立NFS存储服务器，输出共享目录，支持多K8s集群挂载
3. **网络层**：集群所有节点内网互通，放行NFS 2049端口
4. **K8s CSI控制平面**：nfs-csi-controller（动态创建PV、快照、扩容）
5. **K8s CSI数据平面**：nfs-csi-node DaemonSet（所有Worker节点，挂载/卸载NFS共享）
6. **应用层**：Deployment/StatefulSet 通过 PVC 绑定动态PV持久化数据

### 2.2 NFS存储适用&不适用场景
✅ 适用
- 静态文件服务、附件上传、日志持久化、配置文件共享
- 小规模有状态服务（测试环境MySQL、Redis临时存储）
- 多Pod共享同一存储目录场景
❌ 不推荐生产核心数据库
- MySQL、PostgreSQL等强一致性数据库，NFS无块设备锁，易出现数据错乱、IO延迟高；建议使用块存储CSI（RBD/LocalPV）

## 三、前置环境准备
### 3.1 NFS服务端服务器规划
独立存储服务器（推荐2台做NFS高可用，本文先单机基础部署）
1. 操作系统：CentOS Stream 8 / Ubuntu 22.04
2. 内网IP：`192.168.122.1`
3. 存储数据目录：`/sdb/nfs`
4. 集群内网网段：`192.168.122.0/24`（仅允许集群节点挂载NFS）
5. 硬件：多块磁盘做RAID5/RAID10，避免单盘损坏丢失数据

### 3.2 K8s集群节点前置依赖（所有Master/Worker）
```bash
# CentOS
yum install -y nfs-utils rpcbind
# Ubuntu
apt install -y nfs-common rpcbind
```
### 3.3 网络放行规则
1. 内网防火墙/安全组放行端口：TCP/UDP 2049(NFS)、111(rpcbind)
2. 集群节点可正常ping通NFS服务端IP
3. 禁用节点防火墙拦截内网存储流量

## 四、第一部分：NFS 服务端部署配置（独立存储服务器）
### 4.1 安装NFS服务
```bash
# CentOS
dnf install -y nfs-utils rpcbind
systemctl enable --now rpcbind nfs-server

# Ubuntu
apt install -y nfs-kernel-server rpcbind
systemctl enable --now rpcbind nfs-kernel-server
```

### 4.2 创建共享数据目录
```bash
# 创建存储根目录
mkdir -p /data/k8s-nfs-share
# 权限优化：K8s Pod运行用户适配，放开读写
chmod -R 777 /data/k8s-nfs-share
# 如需严格权限可后续结合securityContext调整UID/GID
```

### 4.3 配置NFS导出配置 /etc/exports
```ini
# 格式：共享目录 允许网段(权限参数)
/sdb/k8s-nfs 192.168.122.0/24(rw,sync,no_subtree_check,no_root_squash)
```
参数说明：
1. `rw`：读写权限（只读场景替换为ro）
2. `sync`：同步写入，数据落盘后返回，防止断电丢失
3. `no_subtree_check`：关闭子树校验，提升性能
4. `no_root_squash`：Pod内root用户保留权限（生产多Pod写文件必备）

### 4.4 重载NFS导出配置，验证共享
```bash
# 重载配置
exportfs -r
# 查看当前导出共享目录
exportfs -v
# 本地测试挂载验证
mkdir -p /tmp/test-nfs
mount -t nfs 192.168.1.200:/data/k8s-nfs-share /tmp/test-nfs
# 读写测试
echo "nfs test" > /tmp/test-nfs/test.txt
cat /tmp/test-nfs/test.txt
# 卸载
umount /tmp/test-nfs
```

### 4.5 服务端开机自启&防火墙放行
```bash
# 放行NFS端口
firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --reload
# 确认服务运行状态
systemctl status nfs-server rpcbind
```

## 五、第二部分：K8s 集群部署 NFS CSI 驱动
原生静态NFS PV存在痛点：需要管理员手动创建PV，无法自动扩容、快照、回收；**nfs-csi 官方驱动实现动态供给StorageClass**。

### 5.1 添加CSI helm仓库
```bash
helm repo add csi-driver-nfs https://kubernetes-csi.github.io/charts
helm repo update
# 创建专用命名空间
kubectl create ns kube-csi-nfs
```

### 5.2 自定义values-nfs-csi.yaml
```yaml
storageClass:
  # 自动创建StorageClass资源
  create: true
  name: nfs-sc
  # 设置为集群默认存储类
  defaultClass: true
  parameters:
    # NFS服务端IP
    server: "192.168.1.200"
    # NFS共享根目录
    share: "/data/k8s-nfs-share"
    # 子目录隔离，每个PVC自动创建独立子文件夹
    subDir: "k8s-${pvc-namespace}-${pvc-name}"
  reclaimPolicy: Retain # 删除PVC后保留数据（生产推荐，避免误删丢失）
  volumeBindingMode: Immediate

controller:
  replicas: 2 # 控制平面双副本高可用

node:
  # 全节点部署挂载代理
  daemonSet:
    enable: true

# 开启快照、扩容功能
featureGates:
  Snapshot: true
  ExpandPVC: true
```

### 5.3 Helm 安装 CSI 驱动
```bash
helm install nfs-csi csi-driver-nfs/csi-driver-nfs \
-n kube-csi-nfs \
-f values-nfs-csi.yaml
```

### 5.4 部署校验
```bash
# 查看控制器、node DaemonSet全部就绪
kubectl get pods -n kube-csi-nfs
# 查看自动生成StorageClass
kubectl get storageclasses.storage.k8s.io
# 查看CSI驱动注册信息
kubectl get csidrivers
```

## 六、第三部分：存储资源使用标准示例
### 6.1 动态PVC自动创建NFS PV（业务标准写法）
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: biz-data-pvc
  namespace: biz
spec:
  storageClassName: nfs-sc
  accessModes:
    - ReadWriteMany # NFS核心特性：多节点多Pod同时读写
  resources:
    requests:
      storage: 10Gi
```
执行创建：
```bash
kubectl apply -f pvc.yaml
# 自动生成对应PV
kubectl get pv,pvc -n biz
```

### 6.2 Deployment 挂载PVC
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: file-server
  namespace: biz
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: app
        image: harbor.example.com/library/nginx:1.24
        volumeMounts:
        - name: data-storage
          mountPath: /usr/share/nginx/html/upload
      volumes:
      - name: data-storage
        persistentVolumeClaim:
          claimName: biz-data-pvc
```

### 6.3 PVC在线扩容（无需重建Pod）
编辑PVC，修改存储请求大小：
```yaml
resources:
  requests:
    storage: 30Gi
```
保存后CSI控制器自动扩容NFS子目录，Pod无需重启即可识别新容量。

### 6.4 静态NFS PV（兼容老业务，不推荐新项目）
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: static-nfs-pv
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: 192.168.1.200
    path: /data/k8s-nfs-share/static-biz
```

## 七、NFS 高可用扩展（生产机房必备）
单机NFS存在单点故障，企业生产部署**双机NFS+Keepalived虚拟VIP**：
1. 两台NFS服务器，后端共享存储（磁盘阵列/分布式块存储）
2. Keepalived配置虚拟VIP 192.168.1.200，故障自动漂移
3. 两台服务器同步导出相同共享目录
4. CSI StorageClass server字段填写虚拟VIP，故障切换业务无感知

## 八、权限、性能生产优化配置
### 8.1 Pod权限适配（解决文件权限denied）
在Pod中配置安全上下文统一UID/GID：
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
```
同步NFS服务端目录修改归属：
```bash
chown -R 1000:1000 /data/k8s-nfs-share
```

### 8.2 NFS 挂载性能优化参数
CSI StorageClass追加挂载参数，提升IO性能：
```yaml
storageClass:
  parameters:
    mountOptions: "vers=4.2,hard,rsize=65536,wsize=65536"
```
- vers=4.2：使用NFS4.2新版本，支持更好锁机制、扩容
- hard：硬挂载，服务端失联持续重试，避免应用直接崩溃

### 8.3 存储数据备份规范
1. NFS服务端定时快照：LVM快照/rsync同步至异地备份服务器
2. 配合ETCD集群备份，业务数据与集群元数据双备份
3. 禁止仅依赖NFS单盘存储，必须异地副本

## 九、监控、告警与验收标准
### 9.1 监控指标
1. NFS服务端磁盘使用率、IO等待、读写延迟
2. CSI控制器Pod运行状态、PVC创建/扩容失败事件
3. 节点NFS挂载点掉线、rpc调用超时计数

### 9.2 告警规则
1. NFS服务端磁盘使用率>85%触发扩容告警
2. CSI Pod CrashLoopBackOff、PVC无法绑定
3. 节点NFS挂载断开，应用读写超时

### 9.3 集群交付验收项（纳入validate-cluster-health.md）
1. 动态PVC可正常创建、绑定、读写文件
2. PVC在线扩容生效，无需重启Pod
3. 多Pod多节点同时读写同一RWX存储无报错
4. 删除PVC后PV按回收策略保留/清理目录
5. 节点重启后NFS自动重挂载，业务无异常

## 十、高频故障排查
### 故障1：Pod挂载NFS报错：permission denied
根因：NFS目录权限不足、no_root_squash未开启、Pod fsGroup不匹配
修复：调整共享目录权限，修改exports配置重载NFS，配置Pod安全上下文

### 故障2：创建PVC一直Pending，无法生成PV
根因：CSI控制器异常、NFS服务端不可达、StorageClass参数server/share填写错误
排查：`kubectl describe pvc xxx` 查看事件；查看nfs-csi-controller日志

### 故障3：节点重启后Pod无法启动，NFS挂载超时
根因：节点未安装nfs-utils、防火墙拦截2049、NFS服务宕机
修复：所有节点预装NFS客户端，检查服务端运行状态、内网连通性

### 故障4：PVC扩容后df查看容量不变
根因：未开启ExpandPVC特性；NFS4以下版本不支持在线扩容
修复：开启CSI featureGates，统一使用NFS4.2挂载参数

### 故障5：多Pod同时写入文件出现数据错乱
根因：应用无文件锁机制，NFS适合文件存储，不适合数据库随机读写
优化：数据库业务替换RBD块存储，文件业务增加应用层锁控制

## 十一、生产落地运维规范
1. 新项目统一使用nfs-csi动态StorageClass，禁止手动创建静态PV
2. 生产环境NFS服务端必须双机高可用+虚拟VIP，杜绝单点故障
3. 数据库、中间件核心业务不使用NFS，选用块存储CSI
4. NFS共享目录按命名空间/PVC自动分层隔离，防止多业务误删互相影响
5. 定时对NFS数据目录做异地备份，磁盘使用率持续监控预警
6. 集群所有节点预装nfs-utils客户端，标准化初始化脚本统一部署
7. 交付验收必测PVC创建、读写、扩容、多Pod共享挂载四项用例

## 十二、关联文档索引
build-kubernetes-cluster.md K8s集群节点初始化配置
validate-cluster-health.md 存储交付验收标准
backup-etcd-cluster.md 集群元数据备份规范
06-network-debug.md NFS挂载、端口连通故障排查手册
replace-worker-node.md 节点替换后存储挂载校验流程