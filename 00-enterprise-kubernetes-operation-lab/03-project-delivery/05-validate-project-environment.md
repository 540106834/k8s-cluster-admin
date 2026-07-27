# validate-project-environment.md
# 项目Namespace交付全维度验收校验手册
## 一、文档定位
本文为企业平台项目环境交付、变更、上线前标准化验收SOP，针对`dev/uat/prod`三套命名空间，覆盖**命名空间基础基线、镜像拉取权限、资源管控、RBAC开发权限、网络连通、存储、业务调度、安全基线**八大维度校验；新建项目、扩容资源、权限变更后必须完整执行本验收流程，全部通过方可交付业务上线。
前置依赖：
create-project-workspace.md｜项目命名空间创建流程
enable-private-image-access.md｜Harbor镜像免密配置
deliver-developer-access.md｜开发人员RBAC权限交付
configure-project-resource-policy.md｜配额/容器限制/网络策略配置
下游关联：06-network-debug.md｜项目网络故障排查手册

## 二、前置校验准备
### 2.1 工具与权限
1. 管理员集群权限`cluster-admin`，可查看全命名空间所有资源
2. 预装工具：kubectl、dig、crictl、curl、ping
3. 项目开发人员kubeconfig（用于验证普通账号权限边界）
4. 集群基础设施、监控日志、存储平台全部就绪

### 2.2 校验执行顺序（自上而下分层）
1. 命名空间基础标签与基线资源校验
2. 私有镜像仓库拉取权限校验
3. 资源管控基线：LimitRange、ResourceQuota校验
4. 网络基线与全场景流量连通测试
5. 存储PVC动态供给、读写持久化校验
6. RBAC开发人员权限边界校验
7. 监控日志采集校验
8. 安全基线零信任校验

### 2.3 环境区分标准
DEV/UAT/PROD三套环境校验标准差异化：
1. DEV：宽松调度、内网全通、开发完整读写权限
2. UAT：中等资源限制、网络按需放行、开发仅有限写权限
3. PROD：严格资源配额、默认拒绝网络、开发仅只读权限、高可用强制校验

## 三、第一层：命名空间基础基线校验
### 3.1 命名空间标签完整性校验
```bash
# 查看命名空间完整标签
kubectl get ns 项目ns名称 --show-labels
kubectl describe ns 项目ns | grep Labels
```
**验收标准**
必须包含标准化标签：`env、project、department、owner`，标签值与项目规划文档一致。

### 3.2 三大基线资源存在性校验
```bash
# 校验LimitRange、ResourceQuota、默认拒绝NetworkPolicy
kubectl get limitrange,resourcequota,networkpolicy -n 项目ns
```
**验收阻断标准**
任意基线资源缺失，判定项目环境未初始化完成，禁止上线业务。

## 四、第二层：私有Harbor镜像拉取权限全量校验
### 4.1 Secret与默认ServiceAccount绑定校验
```bash
# 查看镜像拉取secret
kubectl get secret harbor-pull-secret -n 项目ns
# 校验default SA已绑定imagePullSecrets
kubectl describe sa default -n 项目ns | grep ImagePullSecrets
```

### 4.2 镜像拉取功能验证
创建临时测试Pod，拉取项目私有仓库镜像，无`ErrImagePull/401/证书报错`
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: harbor-test-pod
  namespace: 项目ns
spec:
  containers:
  - name: test
    image: harbor.example.com/环境目录/busybox:1.36
    command: ["sleep","3600"]
```
```bash
kubectl apply -f test-pod.yaml
# 状态必须为Running
kubectl get pod harbor-test-pod -n 项目ns
kubectl delete pod harbor-test-pod -n 项目ns
```

**验收标准**
1. 无x509证书不信任报错
2. 无401鉴权失败，镜像正常拉取
3. 无需手动在Deployment配置imagePullSecrets，全局自动生效

## 五、第三层：资源管控基线校验（LimitRange + ResourceQuota）
### 5.1 LimitRange容器默认资源校验
```bash
kubectl describe limitrange default-container-limit -n 项目ns
```
校验点：
1. default/defaultRequest自动填充CPU/内存参数符合环境标准
2. max单容器资源上限匹配DEV/UAT/PROD规范

### 5.2 ResourceQuota配额校验
```bash
# 查看总资源硬限制
kubectl describe resourcequota ns-resource-quota -n 项目ns
# 查看当前资源使用水位
kubectl get resourcequota ns-resource-quota -n 项目ns -o yaml
```
**验收标准**
1. CPU/内存/Pod/PVC硬配额与环境规划匹配
2. 当前资源占用未达上限，预留15%以上缓冲

### 5.3 调度测试验证
1. 创建无resources空Deployment，自动填充LimitRange默认资源
2. 创建超过max限制的Pod，调度直接失败，事件提示清晰

## 六、第四层：网络基线与全流量连通校验（核心）
### 6.1 基线默认拒绝策略校验
```bash
# 仅存在default-deny-all无其他放行规则时，所有Pod完全无法通信
kubectl get networkpolicy -n 项目ns
```

### 6.2 四类流量连通性测试（必测）
1. **同命名空间Pod互通**
   两个测试Pod互相ping，DEV默认放行；UAT/PROD需配置对应放行策略才可连通。
2. **Pod访问ClusterIP Service**
   正常解析服务域名，负载均衡转发后端Pod无502/超时。
3. **Pod访问外网/第三方服务**
   Egress放行外网CIDR才可访问，否则直接断连。
4. **Ingress域名访问（如有业务）**
   域名正常解析，HTTPS证书有效，路由匹配后端服务。

### 6.3 DNS域名解析校验
```bash
kubectl exec -n 项目ns test-pod -- nslookup kubernetes.default.svc.cluster.local
# 解析项目Service域名正常
kubectl exec -n 项目ns test-pod -- dig 业务svc.项目ns.svc.cluster.local
```

### 6.4 网络策略阻断验证
1. 未添加放行规则时，Pod之间完全无法ping通
2. 添加放行规则后流量正常连通，删除规则立即阻断

## 七、第五层：存储PVC持久化校验
### 7.1 StorageClass、动态PVC创建校验
```bash
# 集群默认存储类存在
kubectl get storageclasses
# 创建测试PVC自动绑定PV
kubectl apply -f test-pvc.yaml
kubectl get pvc test-pvc -n 项目ns
```

### 7.2 数据持久化验证
1. Pod写入测试文件，删除重建Pod后数据保留
2. PVC在线扩容功能正常（CSI支持场景）
3. 多Pod共享RWX存储无读写冲突（NFS）

## 八、第六层：RBAC开发人员权限边界校验
使用开发人员kubeconfig执行权限测试，区分三套环境权限标准：
### 8.1 DEV环境校验标准
```bash
# 允许创建/删除Pod、Deployment
kubectl --kubeconfig=dev-kubeconfig create pod test
kubectl --kubeconfig=dev-kubeconfig delete pod test
# 允许exec、logs调试容器
kubectl --kubeconfig=dev-kubeconfig exec -it test-pod -- sh
```

### 8.2 UAT环境校验标准
1. 允许查看所有资源、重启Deployment
2. **禁止删除** Deployment/StatefulSet/PVC，操作返回403

### 8.3 PROD环境校验标准
1. 仅允许get/list/watch、查看日志
2. 任何写操作（create/patch/update/delete）全部返回403 Forbidden

### 8.4 跨命名空间权限阻断校验
开发人员无法操作其他项目命名空间资源，返回403。

## 九、第七层：监控、日志采集验收
### 9.1 Prometheus指标采集
1. 项目Pod CPU/内存/QPS指标正常在Grafana大盘展示
2. ServiceMonitor自动采集业务`/metrics`指标无缺失

### 9.2 Loki日志采集
1. Pod标准输出日志可在Grafana Loki检索
2. ERROR错误日志完整捕获，支持按命名空间、应用标签过滤

## 十、第八层：生产环境PROD专属高可用校验（DEV/UAT跳过）
1. 业务Deployment副本数≥2，节点分散调度，无单节点单点
2. 节点亲和/反亲和配置正常，故障后Pod自动驱逐重建
3. 存储PVC支持跨节点挂载，节点宕机不丢失数据
4. 网络策略默认拒绝，无全局全通配放行规则

## 十一、交付阻断上线判定标准
满足任意一条，项目环境验收不通过，禁止业务上线：
1. 命名空间缺失任意基线资源（LimitRange/Quota/默认NetworkPolicy）
2. Harbor镜像拉取401/证书报错，无法创建Pod
3. 四类核心流量存在完全不通、持续丢包超时
4. PVC无法动态绑定、数据丢失、扩容失效
5. 开发人员权限超边界（PROD开发具备删除权限）
6. 监控/日志完全采集中断，无法观测业务状态
7. 生产环境业务单副本运行，无高可用调度能力

## 十二、验收交付输出物
1. 项目基础信息（命名空间、环境类型、负责人、资源配额）
2. 八大维度逐项验收结果、命令执行日志截图
3. 镜像拉取连通测试记录
4. 网络流量连通性测试记录
5. RBAC权限边界验证记录
6. 存储持久化读写测试记录
7. 验收结论：项目环境基线完整，具备业务上线条件

## 十三、高频验收故障快速处理
### 1. 基线资源缺失
返回create-project-workspace.md重新批量注入ns基线模板资源。
### 2. 镜像拉取401
参照enable-private-image-access.md重新创建secret并绑定default SA。
### 3. Pod完全无法通信
NetworkPolicy无放行规则，按需补充ingress/egress放行策略。
### 4. 开发人员权限越权
修改对应Role角色verbs，删除delete/update写权限。
### 5. PVC一直Pending无法绑定
核对StorageClass名称、CSI驱动运行状态，修复存储配置。

## 十四、生产运维标准化规范
1. 新建/扩容/变更项目命名空间必须完整执行本验收文档，留存验收记录归档；
2. 三套环境严格区分权限、资源、网络策略标准，禁止DEV配置直接复制到PROD；
3. 验收不通过的项目禁止交付业务上线，先修复缺陷再重新校验；
4. 每季度定期对存量项目命名空间执行复检，修复基线缺失、权限越权风险；
5. 所有验收测试Pod、PVC测试资源验收完成后统一清理，不占用集群资源。

## 十五、关联文档索引
create-project-workspace.md 项目命名空间基线资源初始化
enable-private-image-access.md Harbor镜像免密配置流程
deliver-developer-access.md RBAC权限创建与kubeconfig交付
configure-project-resource-policy.md 配额、容器限制、网络策略配置
03-network-data-path.md Pod四类流量连通测试底层原理
06-network-debug.md 项目网络、存储、权限故障排查流程