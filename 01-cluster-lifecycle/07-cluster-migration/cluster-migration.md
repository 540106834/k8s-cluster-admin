# cluster-migration.md
## 一、文档基础信息
- 适用场景：自建K8s集群迁移、自建↔云托管K8s跨集群迁移、同架构集群整机迁移
- 当前基准集群：v1.32.13 单Master Ubuntu22.04，Calico v3.30.4，内网Harbor镜像仓库
- 前置依赖：`etcd-backup.md`、`05-kubeconfig-management/`、`cluster-upgrade-theory-guide.md`
- 核心定位：集群迁移完整理论、三种迁移方案、分步实操、校验、回滚、云集群迁移差异
- 核心目标：业务零停机/低停机，完整迁移集群资源、存储、配置、权限、镜像

## 二、集群迁移底层理论与分类
### 2.1 迁移核心定义
集群迁移指将一套K8s集群**全部业务资源、持久化数据、集群配置**完整迁移至另一套全新集群，分为同架构迁移、跨架构、自建转云托管三类。
底层核心约束：
1. 两套集群K8s Minor版本尽量保持一致，最大允许相差1个Minor；
2. 镜像仓库必须互通，或全量导出镜像tar迁移至目标Harbor；
3. 存储PV/PVC依赖底层存储驱动，跨节点/跨机房存储无法直接复用；
4. RBAC、ServiceAccount、CRD、Ingress等集群级资源必须同步迁移。

### 2.2 三大迁移方案对比
| 迁移方案 | 适用场景 | 停机时长 | 优点 | 缺点 |
|--------|--------|--------|------|------|
| 资源导出导入迁移（标准方案） | 新建同版本集群、自建迁移云集群 | 短（分钟级） | 可控、风险低、支持灰度切换 | 需要重新调度Pod，PV需迁移数据 |
| etcd快照整体迁移（同硬件同版本） | 机房搬迁、服务器整机替换、同配置单Master | 中（10~30分钟） | 集群ID、资源完全不变，无需重建资源 | 两套集群硬件、网段、K8s版本必须完全一致，跨网段网络失效 |
| 双集群灰度流量迁移（生产高可用） | 核心业务不能停机，自建转ACK/EKS | 0停机 | 业务无中断，可灰度切流、失败回滚 | 双集群同时运行，双倍资源成本，操作复杂 |

### 2.3 迁移前置硬性约束
1. 版本约束：目标集群K8s版本 ≥ 源集群版本，禁止目标版本低于源集群；
2. 网段约束：两套集群Pod CIDR、Service CIDR不能冲突，否则Calico路由异常；
3. 镜像约束：源集群所有业务/系统镜像必须同步至目标内网Harbor；
4. 存储约束：本地存储PV无法跨集群复用，需提前备份业务数据；
5. 权限约束：目标集群提前创建相同ServiceAccount、ClusterRole、命名空间。

## 三、方案一：资源导出导入迁移（通用推荐，自建/云集群通用）
### 3.1 迁移前置准备（源集群执行）
1. 全集群资源备份导出
```bash
mkdir -p /usr/local/src/cluster-migration/source-backup
# 导出所有命名空间内业务资源
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}');do
kubectl get deploy,svc,ingress,pvc,configmap,secret,statefulset,daemonset -n ${ns} -o yaml > /usr/local/src/cluster-migration/source-backup/ns-${ns}.yaml
done
# 导出集群级资源（CRD、RBAC、StorageClass）
kubectl get crd,clusterrole,clusterrolebinding,storageclass -o yaml > /usr/local/src/cluster-migration/source-backup/cluster-wide.yaml
```
2. 全量镜像导出/同步至目标Harbor
```bash
# 导出集群所有镜像名称清单
crictl images --quiet | awk '{print $1":"$2}' > /usr/local/src/cluster-migration/image-list.txt
# 批量拉取、打包、推送至目标harbor.jinshaoyong.com/k8s
```
3. 源集群etcd快照兜底备份（`etcd-backup.md`）

### 3.2 目标集群环境预准备
1. 目标集群完成初始化，Calico、metrics-server正常运行，节点全部Ready；
2. 目标Harbor上传全部系统镜像、业务镜像；
3. 提前创建所有业务命名空间：
```bash
# 从源集群导出ns清单，目标集群批量创建
for ns in $(cat ns-list.txt);do kubectl create ns ${ns};done
```
4. 目标集群内核、网段、containerd配置与源对齐；
5. 拷贝目标集群kubeconfig用于切换操作。

### 3.3 资源导入顺序（不可逆，顺序错误会创建失败）
1. 集群级资源：CRD → StorageClass → ClusterRole → ClusterRoleBinding
```bash
kubectl apply -f cluster-wide.yaml
```
2. 命名空间内部资源：ConfigMap/Secret → PVC → Service → Deployment/StatefulSet/Ingress
```bash
kubectl apply -f ns-business.yaml
```
### 3.4 PV数据迁移补充
- 云存储（CSI）：同存储池可迁移PV；跨机房需快照复制磁盘；
- 本地存储：业务停机，tar打包数据目录，拷贝至目标节点对应路径。

### 3.5 迁移后校验
```bash
# 1. 所有资源正常创建无报错
kubectl get all -A
# 2. Pod全部Running
kubectl get pods -A
# 3. Service、Ingress访问正常
# 4. 业务数据完整性校验
# 5. 网络跨Pod互通
kubectl run migrate-test --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 3600
kubectl exec migrate-test -- ping 10.32.0.10
```

## 四、方案二：etcd快照整机迁移（仅同网段同版本单Master）
适用场景：服务器硬件更换、机房内机器替换，IP、网段、主机名完全不变
### 4.1 源集群操作
1. 停止业务写入，停止kubelet，关停所有静态Pod；
2. 生成完整etcd快照；
3. 拷贝 `/etc/kubernetes/pki/` 全套证书、etcd快照、kubeconfig至新Master；
4. 拷贝Harbor镜像tar包至目标机器导入。

### 4.2 目标新Master操作
1. 系统初始化、containerd部署完成，hosts、网段与源完全一致；
2. 覆盖 `/etc/kubernetes/pki/` 证书目录；
3. 执行 `etcd-restore.md` 快照恢复流程；
4. 启动kubelet拉起控制平面；
5. Worker节点kubeadm join重新加入集群。

### 4.3 限制
1. 目标机器IP、主机名必须与源一致；
2. Pod/Service网段不能修改；
3. 跨网段、跨云环境无法使用此方案。

## 五、方案三：双集群灰度零停机迁移（高可用核心业务）
1. 新建目标集群，同步全部镜像、资源yaml；
2. 双集群同时运行相同业务副本；
3. 域名DNS权重切少量流量至新集群，观察日志、监控；
4. 逐步切流，全量切换后排空旧集群Pod；
5. 稳定运行7天，下线旧集群。

## 六、自建集群迁移至云托管K8s（ACK/EKS/GKE/AKS）特殊流程
### 6.1 云集群差异点
1. 云控制平面由厂商托管，无法使用etcd快照迁移；只能用资源导出导入方案；
2. 存储层替换为云CSI存储，本地PV无法迁移，需数据备份恢复；
3. 网络插件替换为云厂商CNI，Pod网段重新规划；
4. 镜像仓库：可使用云镜像仓库，或打通内网访问原有Harbor。

### 6.2 自建转云迁移步骤
1. 自建集群导出全量资源yaml；
2. 适配云集群变更：
   - 修改StorageClass为云CSI存储类；
   - Ingress替换为云负载均衡Ingress；
   - 节点亲和、污点适配云节点池；
3. 镜像批量推送至云容器镜像仓库；
4. 导入资源至云K8s，灰度切换流量；
5. 业务验证完成下线自建集群。

## 七、迁移回滚方案
### 7.1 资源导入迁移回滚
目标集群直接删除对应命名空间/集群资源，切回旧集群流量。
### 7.2 etcd整机迁移故障回滚
使用源集群原始etcd快照恢复原服务器，切回旧集群。
### 7.3 灰度双集群回滚
DNS切回全部流量至源集群，停止新集群业务。

## 八、迁移风险清单
1. **镜像拉取失败**：目标Harbor缺失镜像，迁移前全量同步；
2. **PV数据丢失**：本地存储未打包备份，迁移前停机备份数据；
3. **网段冲突**：新旧Pod/Service网段重叠导致网络不通，提前规划隔离网段；
4. **CRD/Operator不兼容**：目标集群缺少CRD资源，导入顺序前置；
5. **Secret/密钥失效**：完整导出Secret，禁止遗漏；
6. **云存储驱动不匹配**：自建本地PV无法在云集群复用，提前迁移数据；
7. **版本差异API报错**：源集群版本高于目标，先升级目标集群至匹配版本。

## 九、迁移运维规范
1. 迁移操作选择业务低峰，提前完成全量备份；
2. 正式迁移前搭建模拟集群完整演练；
3. 迁移完成保留源集群7天用于应急回滚；
4. 镜像、资源备份文件留存15天；
5. 生产核心业务优先使用灰度双集群零停机方案。

## 十、关联文档
1. 数据备份：`etcd-backup.md`、`etcd-restore.md`
2. 权限配置：`05-kubeconfig-management/` 多集群kubeconfig切换
3. 版本兼容：`cluster-upgrade-theory-guide.md`
4. 故障处理：`10-troubleshooting.md`