# 03-storageclass.md 补充：外部NFS StorageClass完整案例
## 一、前置说明
适用场景：多节点同时读写共享存储（RWX），用于静态文件、附件、离线缓存、跨Pod共享配置；
集群采用外部独立NFS服务，不依赖本地磁盘，适配FAT/UAT多环境共享文件场景；
依赖组件：`nfs-subdir-external-provisioner` CSI侧控制器，自动创建子目录隔离不同PVC。

## 二、全局参数规划示例
| 项目 | 配置值 |
|------|--------|
| NFS服务地址 | 192.168.20.10 |
| NFS共享根目录 | /data/k8s-share |
| StorageClass名称 | nfs-share-uat |
| 访问模式 | ReadWriteMany |
| 回收策略 | Retain（UAT/PROD） / Delete（FAT） |
| 在线扩容 | allowVolumeExpansion: true |

## 三、NFS Provisioner 部署yaml（离线替换镜像）
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: kube-system
  labels:
    app: nfs-client-provisioner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
      - name: provisioner
        image: harbor.jinshaoyong.com/k8s/nfs-subdir-external-provisioner:v4.0.8
        command:
        - /nfs-subdir-external-provisioner
        args:
        - -nfs-server=192.168.20.10
        - -nfs-path=/data/k8s-share
        - -nfs-mount-options=vers=4.2,noatime
        - -storage-class=nfs-share-uat
        - -reclaim-policy=Retain
        env:
        - name: PROVISIONER_NAME
          value: k8s-sigs.io/nfs-subdir-external-provisioner
        volumeMounts:
        - name: nfs-root
          mountPath: /persistentvolumes
      volumes:
      - name: nfs-root
        nfs:
          server: 192.168.20.10
          path: /data/k8s-share
```

## 四、RBAC权限配置（必须配套）
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-client-provisioner-runner
rules:
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get","list","watch","create","delete"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get","list","watch","update"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get","list","watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create","update","patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: run-nfs-client-provisioner
subjects:
- kind: ServiceAccount
  name: nfs-client-provisioner
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
```

## 五、NFS StorageClass 资源模板（UAT示例）
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-share-uat
  labels:
    env: uat
    storage: nfs-shared
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false" # 删除PVC不归档旧数据，直接清空子目录
volumeBindingMode: Immediate
reclaimPolicy: Retain
allowVolumeExpansion: true
```
### FAT测试环境NFS SC（回收策略Delete）
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-share-fat
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false"
volumeBindingMode: Immediate
reclaimPolicy: Delete
allowVolumeExpansion: true
```

## 六、PVC使用示例（挂载NFS共享存储）
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: file-share-pvc
  namespace: uat
spec:
  storageClassName: nfs-share-uat
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
```

## 七、关键配置说明
1. **reclaimPolicy**
   - FAT：Delete，删除PVC自动清空NFS子目录；
   - UAT/PROD：Retain，PVC删除后目录保留，人工清理；
2. `archiveOnDelete: "false"`
   删除PVC不创建归档备份目录，节省NFS磁盘；如需留存历史数据改为`true`；
3. `volumeBindingMode: Immediate`
   PVC创建立刻生成PV，无需等待Pod调度，共享存储无节点绑定限制；
4. NFS挂载参数 `vers=4.2` 提升稳定性，避免老旧NFS v3兼容性问题。

## 八、NFS存储运维操作
```bash
# 部署NFS provisioner、RBAC、SC
kubectl apply -f nfs-provisioner.yaml

# 查看NFS SC
kubectl get storageclasses nfs-share-uat

# 查看自动创建PV
kubectl get pv -n uat

# 查看NFS provisioner日志（PVC创建失败排错）
kubectl logs -n kube-system deploy/nfs-client-provisioner
```

## 九、NFS常见故障根因
1. PVC Pending，无法创建PV
   NFS服务111/2049端口拦截、NFS共享目录权限不足、provisioner Pod异常；
2. 多Pod同时读写文件损坏
   应用未做文件锁，RWX仅适合静态文件，不适合数据库；
3. PVC扩容不生效
   SC已开启allowVolumeExpansion，但NFS底层目录容量不足；
4. 删除PVC后数据未清理
   UAT/PROD回收策略Retain，人工登录NFS服务器删除对应子目录。

## 十、环境使用规范
1. DEV本地：不使用集群NFS，本地文件调试；
2. FAT：nfs-share-fat，Delete回收策略，用完自动清理；
3. UAT/PROD：nfs-share-uat/prod，Retain，仅用于静态附件、缓存，禁止数据库存储；
4. 数据库/Redis等有状态组件禁止使用NFS RWX，改用Local SSD RWO。