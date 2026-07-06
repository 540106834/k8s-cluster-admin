# etcd-backup.md
## 一、文档基础信息
- 适用集群：Kubernetes v1.32.13 单Master自建集群
- 所属流程：集群部署后置、升级前置强制操作
- 核心定位：etcd 原理、快照备份、定时自动备份、快照恢复、清理、故障校验全套操作手册
- 前置依赖：`05-kubeadm-init.md` 集群初始化完成，Master存在etcd证书目录 `/etc/kubernetes/pki/etcd/`
- 关联文档：`08-post-install.md`、`kubernetes-upgrade-theory-guide.md`、`10-troubleshooting.md`

## 二、etcd 备份底层理论认知
### 2.1 etcd 作用
etcd 是K8s唯一持久化存储，集群所有资源（Node/Pod/Service/RBAC/CRD/配置/密钥）全部持久化存储在etcd，一旦损坏集群所有数据丢失，无法恢复业务。

### 2.2 快照备份原理
etcd v3 提供 `snapshot save` 快照机制：
1. 读取当前etcd完整数据落盘生成独立db文件；
2. 快照文件为完整全量数据，可在同版本etcd环境完整恢复集群；
3. 快照**跨K8s Minor大版本不兼容**，升级前快照仅能回退至原集群版本；
4. 快照不依赖运行中集群，离线也可完成数据还原。

### 2.3 备份核心约束
1. 仅支持 `ETCDCTL_API=3`，v2 API已废弃不可使用；
2. 必须使用集群签发的etcd专用CA、server证书、server私钥鉴权；
3. 备份存储目录与系统盘分离，防止系统盘占满丢失备份；
4. 大版本升级前必须生成**双份间隔快照**，避免单份快照损坏；
5. 快照文件定期清理，防止备份磁盘溢出。

## 三、标准化备份目录规划
```
/usr/local/src/etcd-backup/
├── manual/        # 手动快照（升级/重大操作前置）
├── cron/          # 定时任务自动快照
└── recover/       # 待恢复快照存放目录
```

## 四、手动单次快照备份（升级/变更前必执行）
### 4.1 标准备份命令
```bash
# 定义备份路径
BACKUP_DIR=/usr/local/src/etcd-backup/manual
mkdir -p ${BACKUP_DIR}
SNAP_FILE=${BACKUP_DIR}/etcd-snapshot-$(date +%Y%m%d_%H%M).db

# 执行快照保存
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save ${SNAP_FILE}

# 校验快照文件生成
ls -lh ${SNAP_FILE}
```

### 4.2 快照完整性校验
```bash
ETCDCTL_API=3 etcdctl snapshot status ${SNAP_FILE}
```
输出包含总key数量、版本号，无报错即快照有效。

## 五、定时自动备份（crontab 长期运维）
### 5.1 定时备份脚本
```bash
# /usr/local/src/etcd-backup/etcd-auto-backup.sh
#!/bin/bash
export ETCDCTL_API=3
BACKUP_DIR=/usr/local/src/etcd-backup/cron
mkdir -p ${BACKUP_DIR}
SNAP=${BACKUP_DIR}/etcd-cron-$(date +%Y%m%d).db

# 快照生成
etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save ${SNAP}

# 自动清理7天前快照
find ${BACKUP_DIR} -name "etcd-cron-*.db" -mtime +7 -delete
```
### 5.2 赋予执行权限
```bash
chmod +x /usr/local/src/etcd-backup/etcd-auto-backup.sh
```
### 5.3 配置定时任务（每日凌晨2点执行）
```bash
echo "0 2 * * * root /usr/local/src/etcd-backup/etcd-auto-backup.sh >> /var/log/etcd-backup.log 2>&1" >> /etc/crontab
# 重载crontab生效
systemctl restart cron
```

## 六、etcd快照完整恢复流程（集群灾难性故障）
### 6.1 前置停机操作（单Master集群）
1. 停止控制平面静态Pod
```bash
mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests/bak/
systemctl stop kubelet
# 确认apiserver/etcd/controller全部停止
```
2. 清空原有etcd数据目录
```bash
mv /var/lib/etcd /var/lib/etcd-bak-$(date +%Y%m%d)
mkdir /var/lib/etcd
```

### 6.2 执行快照恢复
```bash
SNAP_RECOVER=/usr/local/src/etcd-backup/manual/etcd-snapshot-xxx.db
ETCDCTL_API=3 etcdctl \
--data-dir=/var/lib/etcd \
snapshot restore ${SNAP_RECOVER}
```

### 6.3 恢复控制平面并重启集群
```bash
# 恢复静态Pod清单
mv /etc/kubernetes/manifests/bak/*.yaml /etc/kubernetes/manifests/
# 启动kubelet重建控制平面
systemctl start kubelet
# 等待apiserver就绪，验证集群数据
kubectl get nodes
kubectl get all -A
```

## 七、云托管K8s etcd备份补充说明
1. 云厂商ACK/EKS/GKE/AKS控制平面etcd由厂商三副本高可用托管，自动定时快照；
2. 用户无权限直接执行etcdctl操作云集群Master；
3. 云集群备份方案：
   - 平台控制台开启自动备份；
   - 定期导出全集群资源yaml作为业务层兜底备份；
   - 集群升级前手动触发平台快照备份。

## 八、备份运维规范
1. 集群重大变更（升级、CRD批量导入、清理大量资源）必须手动生成双份间隔快照；
2. 快照文件权限 600，禁止其他用户读取；
3. 备份目录独立挂载磁盘，避免系统盘写满；
4. 大版本升级快照至少留存7天，补丁升级快照留存3天；
5. 每月执行一次快照恢复演练，验证备份可用性。

## 九、常见故障排查
1. **snapshot save 连接etcd失败**
   检查127.0.0.1:2379端口监听、etcd服务正常、证书路径无误；
2. **快照status校验失败**
   备份过程中断，快照损坏，重新执行备份；
3. **快照恢复后etcd无法启动**
   快照版本与当前K8s Minor版本不匹配，使用原版本快照回滚；
4. **定时备份无文件生成**
   检查脚本执行权限、crontab日志、etcd证书读取权限。

## 十、关联文档
1. 前置：`08-post-install.md` 集群交付备份规范
2. 升级依赖：`cluster-upgrade-theory-guide.md` 升级前置备份要求
3. 故障处理：`10-troubleshooting.md` etcd数据丢失恢复方案