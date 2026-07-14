# 01‑cluster‑lifecycle/04‑node‑management/node‑lifecycle.md
## 一、文档基础信息
- 文件路径：`01‑cluster‑lifecycle/04‑node‑management/node‑lifecycle.md`
- 前置文档：集群初始化文档、kubelet‑runtime.md、certificate‑management.md
- 集群版本：Kubernetes‑1.32.13，Lease心跳机制、kubeadm部署、containerd‑2.1.5，Ubuntu‑22.04
- 配套文档：maintenance.md、scheduling.md、troubleshooting.md
- 文档核心：定义Worker‑Node完整生命周期阶段、参与组件、新增节点、节点替换、节点退役、故障节点下线、生产执行SOP、区分计划内维护与意外宕机。

## 二、参与节点生命周期的核心组件
1. **kubelet（节点侧）**
    1. 向apiserver注册Node对象，每10s更新Lease资源维持心跳；
    2. 上报节点4种Condition：Ready、MemoryPressure、DiskPressure、PIDPressure；
    3. 调用containerd管理容器生命周期；执行驱逐逻辑；接收apiserver指令；
2. **Node‑Controller（控制平面）**
    - 监听`kube‑system`命名空间下Lease资源；默认`pod‑eviction‑timeout=5m`；
    - Lease超时5分钟判定节点故障，触发Pod驱逐，由ReplicaSet在其它节点重建Pod；
3. **kube‑scheduler**
    根据节点污点、标签、亲和性策略决定Pod是否调度到此节点；识别`unschedulable`污点拒绝新建Pod；
4. **ReplicaSet / StatefulSet Controller**
    节点排空或者宕机之后，在可用节点拉起新Pod保证副本数；
5. **PDB控制器**
    计划内drain排空期间，遵循PodDisruptionBudget约束，保障最小可用副本。

## 三、Node完整生命周期划分（5个阶段）
### 阶段1：Provisioning 节点初始化接入阶段
1. 操作系统标准化初始化：关闭swap、sysctl内核参数、chronyd时间同步、ufw防火墙；
2. 离线部署containerd‑2.1.5，cgroup‑driver设置为`systemd`，镜像仓库指向内网Harbor；
3. 安装kubeadm、kubelet、kubectl，版本与控制平面严格一致；
4. worker节点执行`kubeadm join`接入集群；kubelet完成向apiserver注册Node；
5. DaemonSet组件（calico‑node、csi‑node、kube‑proxy、node‑exporter）启动；
6. kubelet校验磁盘、内存、PID压力全部为false，节点状态变为`Ready=True`；
7. 运维给节点打上标准化标签 `env、node‑role、rack、hardware‑type、os‑version`；
8. Prometheus开始采集节点指标，节点进入可用状态。

> 失败诱因：时间偏差过大、containerd配置错误、防火墙拦截6443/10250端口、inode耗尽，会导致节点一直处于NotReady。

### 阶段2：Active 正常运行阶段
1. kubelet每10s更新Lease资源；持续上报节点状态；
2. scheduler依据Label、Taint‑Toleration、Pod反亲和将Pod调度到本节点；
3. kubelet执行startupProbe、livenessProbe、readinessProbe探针；
4. 当内存、磁盘、进程数达到evictionHard阈值，kubelet按QoS优先级驱逐Pod；
5. node‑exporter采集系统指标；containerd执行镜像GC清理无用镜像；
6. 若配置自定义污点，仅具备对应容忍的Pod可以部署在此节点。

### 阶段3：Scheduling‑Disabled 调度隔离阶段（Cordon）
执行命令：`kubectl cordon node‑xxx`
1. 修改`node.spec.unschedulable=true`；自动添加污点 `node.kubernetes.io/unschedulable:NoSchedule`；
2. kube‑scheduler不再将新Pod调度至该节点；
3. **已经运行在节点上的Pod不会被删除，业务正常运行**；
4. 此时可以执行`kubectl drain --dry‑run=client`做排空预校验。

解除隔离：`kubectl uncordon node‑xxx`，调度器重新分配Pod到此节点。

### 阶段4：Drain & Maintenance 排空维护阶段
1. 执行`kubectl drain`内部自动执行cordon；
2. 驱逐逻辑：控制器在其它节点启动就绪Pod之后，才删除本节点旧Pod；严格遵守PDB约束；
    - Deployment：副本平滑迁移；
    - StatefulSet：Pod编号由大到小依次删除；
    - DaemonSet（calico‑node、csi‑node）默认不会被drain删除；
3. 排空完成后节点仅剩DaemonSet Pod；执行维护工作：
    - 升级系统内核、安装安全补丁；
    - 更新containerd、kubelet版本；
    - 更换内存、硬盘等硬件故障配件；
    - 修改sysctl内核参数；
4. 维护结束执行`kubectl uncordon`恢复调度。

> 注意：PROD环境禁止使用`--force`强制删除裸Pod。

### 阶段5：Decommission 节点退役下线阶段
#### 场景A：计划内退役（硬件淘汰、缩容）
1. 业务低峰期执行dry‑run预校验；
2. 执行drain排空节点，等待Pod迁移完成，观察5‑10分钟业务指标正常；
3. 确认CSI快照、数据库定时备份执行完毕；
4. 在Master节点删除Node对象：`kubectl delete node node‑xxx`；
5. 登录主机停止kubelet、containerd服务，关闭服务器；
6. 清理CSI‑node残留注册信息、Harbor镜像缓存；移除Prometheus监控配置；更新资产清单。

#### 场景B：意外宕机（硬件故障、内核panic、断电）
1. kubelet停止续约Lease；
2. Node‑Controller等待5分钟超时判定节点宕机；ReplicaSet在其它节点重建Pod；
3. 故障机器修复后重新开机：kubelet重新续约Lease，但原有旧Pod会被控制器清理；
4. 如果硬件彻底损坏，执行上面退役步骤。

## 四、计划内维护 vs 意外宕机对比
|对比项|kubectl‑drain计划内维护|节点意外宕机|
|---|---|---|
|Pod删除时机|新Pod就绪之后旧Pod才删除，业务平滑过渡|Lease超时5分钟后才重建Pod，期间服务中断|
|PDB约束|严格遵守minAvailable，防止副本不足|不受PDB约束，强制重建Pod|
|节点恢复之后|uncordon后接收新Pod|原有Pod被控制器清理|
|PVC状态|仅删除Pod，PVC保留|PVC依然保留|
|可控程度|运维在低峰窗口执行，完全可控|被动触发，不可控|

## 五、节点替换完整SOP（更换故障服务器）
1. 故障节点执行dry‑run预排空：
```bash
kubectl drain node‑old --ignore-daemonsets --delete-emptydir-data --dry-run=client
```
2. 正式排空旧节点，确认Pod全部迁移完成；
3. 删除旧节点对象：`kubectl delete node node‑old`；关闭旧服务器；
4. 新机器执行01‑os‑init系统初始化、安装containerd、kubelet；
5. 执行kubeadm‑join加入集群，打上原有标签和污点；
6. 核查DaemonSet组件就绪，测试Pod调度正常；
7. Prometheus识别新节点，业务运行正常；完成节点替换。

## 六、DEV / FAT / UAT / PROD 差异化约束
1. DEV环境：
    - 节点标签可以简化；drain可以使用`--force`；节点退役无需工单；
2. FAT测试环境：
    - 节点初始化脚本对齐生产；分批排空节点；退役简单记录即可；
3. UAT预生产环境：
    - 禁止使用`--force`；维护选择凌晨低峰窗口；上线退役逐项核对检查清单；
4. PROD生产环境（强制红线）
    1. 新增节点内核版本、containerd版本、sysctl参数必须和现有worker节点保持一致；
    2. drain排空严禁使用`--force`；一次只排空一台节点，排空结束观察5‑10分钟业务指标；
    3. PDB配置禁止随意修改，如需调整必须提交运维工单双人审批；
    4. 节点内核升级、containerd升级、退役全部避开定时备份和CSI快照任务；
    5. 节点宕机之后按照troubleshooting.md执行应急处置，事后输出故障复盘文档；
    6. 节点上线、退役操作全程被apiserver审计日志记录。

## 七、高频故障问题
### 问题1：drain长时间卡住无法驱逐Pod
根因：PDB minAvailable限制，驱逐后副本低于最小值；
解决方案：扩容副本；FAT/UAT可临时调高maxUnavailable；PROD需要工单审批。

### 问题2：节点宕机后Pod迟迟没有重建
根因：Node‑Controller等待`pod‑eviction‑timeout=5min`，Lease未到期；
排查命令：`kubectl get lease -n kube-system`查看最后续约时间。

### 问题3：执行cordon之后依然有Pod调度上来
根因：Pod yaml中硬编码`spec.nodeName`绕过调度器；
解决：移除`nodeName`字段交由scheduler调度。

### 问题4：节点恢复上线之后旧Pod没有清理
根因：节点刚恢复Lease续约成功，控制器延迟清理旧Pod，等待几分钟即可。

## 八、核心运维命令汇总
```bash
# 禁止调度新Pod
kubectl cordon node‑10‑0‑10‑21
# 恢复调度
kubectl uncordon node‑10‑0‑10‑21
# 预排空
kubectl drain node‑10‑0‑10‑21 --ignore-daemonsets --delete-emptydir-data --dry-run=client
# 正式排空
kubectl drain node‑10‑0‑10‑21 --ignore-daemonsets --delete-emptydir-data
# 删除节点（退役）
kubectl delete node node‑10‑0‑10‑21
# 查看Lease续约状态
kubectl get lease -n kube-system
# 查看节点污点
kubectl describe node node‑10‑0‑10‑21 | grep -A 10 Taints
# 查看节点上运行的Pod
kubectl get pods --field-selector spec.nodeName=node‑10‑0‑10‑21 -A
```

## 九、最佳实践总结
1. 严格遵守生命周期顺序：`初始化 → 正常运行 → cordon → drain → 维护 → uncordon/delete node`，禁止跳过步骤；
2. 所有业务必须配置PDB，保障排空期间业务可用性；
3. 计划内维护全部选择凌晨业务低峰窗口；
4. 定期做节点宕机演练，验证Pod跨节点重建逻辑；
5. 废弃节点及时delete node，避免集群残留无效Node对象；
6. node‑exporter开启USE模型告警，提前发现磁盘、内存隐患。

## 十、关联文档
1. maintenance.md：cordon/drain详细参数；
2. scheduling.md：Label、Taint‑Toleration、亲和调度；
3. troubleshooting.md：节点NotReady故障排查；
4. 03‑worker‑node‑management：kubelet驱逐原理、PLEG问题；
5. certificate‑management.md：kubelet证书生命周期。