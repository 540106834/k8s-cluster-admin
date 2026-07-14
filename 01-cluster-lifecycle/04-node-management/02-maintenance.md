# 01‑cluster‑lifecycle/04‑node‑management/maintenance.md
## 一、文档基础信息
- 文件路径：`01‑cluster‑lifecycle/04‑node‑management/maintenance.md`
- 前置文档：`node‑lifecycle.md`，后置文档：`scheduling.md`、`troubleshooting.md`
- 集群版本：Kubernetes‑1.32.13、Lease驱逐机制、containerd‑2.1.5、PDB（PodDisruptionBudget）
- 本文档核心：详解 `kubectl cordon / drain / uncordon` 的内部执行逻辑、参数释义、适用场景、执行顺序、dry‑run预校验、分批维护策略、失败原因分析、生产执行SOP、禁用参数说明。
> 整体执行顺序：`cordon → drain → 执行维护 → uncordon`。

## 二、命令原理区分
### 2.1 kubectl cordon（隔离调度，仅阻止新建Pod）
```bash
kubectl cordon node-10-0-10-21
```
1. 底层改动：设置 `node.spec.unschedulable: true`；自动添加污点 `node.kubernetes.io/unschedulable:NoSchedule`。
2. 效果：
   - kube‑scheduler不再将新Pod调度到此节点；
   - **节点现存Pod继续正常运行，不会被删除**；
3. 适用场景：
   - 节点维护前置准备；
   - 节点资源不足，临时禁止调度新负载；
   - 硬件隐患，提前隔离新业务。

解除隔离：
```bash
kubectl uncordon node-10-0-10-21
```
清除unschedulable状态，调度器重新分配Pod到该节点。

### 2.2 kubectl drain（排空节点，迁移现有Pod）
drain执行时内部会自动先执行`cordon`，之后开始驱逐Pod。
#### 驱逐整体逻辑
1. k8s控制器（ReplicaSet、StatefulSet）先在其他可用节点启动就绪Pod；旧Pod才会被删除；
2. 驱逐全程严格遵循PDB规则，如果删除Pod后就绪副本低于`minAvailable`，drain会卡住暂停执行；
3. DaemonSet资源（calico‑node、csi‑node、kube‑proxy、filebeat）默认不会被drain删除；
4. emptyDir为节点本地存储，默认会阻止drain执行；PVC只是删除Pod，PV/PVC资源保留不受影响。

#### 生产标准执行命令
```bash
# 正式执行排空
kubectl drain node-10-0-10-21 --ignore-daemonsets --delete-emptydir-data
```
##### 参数解析
1. `--ignore-daemonsets`
    - 跳过DaemonSet管理的Pod；不加此参数drain会直接报错退出；
2. `--delete-emptydir-data`
    - emptyDir数据存于当前节点磁盘，删除Pod后数据丢失；
    - 明确确认接受临时目录数据丢失，drain才可以执行；PVC持久卷不受此参数影响。

##### 生产禁止使用的参数（PROD红线）
1. `--force`
    - 作用：强制删除没有控制器管理的裸Pod（手动创建Pod、静态Pod）；
    - 生产严禁使用，裸Pod代表业务没有高可用设计，强制删除会直接造成业务中断；只有DEV环境可临时使用。
2. `--grace-period-seconds`
    - 缩短容器优雅终止时间；容易导致业务异常、事务中断，不建议手动修改。

### 2.3 dry‑run预执行（变更前必做）
```bash
kubectl drain node-10-0-10-21 --ignore-daemonsets --delete-emptydir-data --dry-run=client
```
- dry‑run仅输出将要被驱逐的Pod列表，不会真正执行删除；提前发现PDB约束、裸Pod等问题。

## 三、Pod驱逐顺序与控制器处理逻辑
1. Deployment / ReplicaSet / Job / CronJob
    - 控制器在其他节点Pod就绪后，才删除旧Pod；实现平滑迁移；
2. StatefulSet
    - 按照Pod编号由大到小依次删除；受`partition`分区策略控制；
3. DaemonSet
    - drain不会删除DaemonSet Pod；升级DaemonSet依靠控制器滚动更新；
4. kube‑system系统Pod：默认跳过排空操作。

> 驱逐优先级：当kubelet因资源压力驱逐Pod时按照QoS：`Best‑Effort > Burstable > Guaranteed`；
> drain计划内排空不会参考QoS，只受PDB约束。

## 四、PDB对drain的约束（最常见排空失败原因）
### 4.1 PDB示例
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: order-pdb
  namespace: prod
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: order-api
```
- 如果驱逐之后就绪Pod数量小于`minAvailable`，drain会直接卡住，不会继续驱逐。
### 4.2 问题处理方案
1. 优先方案：扩容Deployment副本数，提高集群冗余之后再执行drain；（PROD推荐）
2. 备选方案：FAT/UAT环境业务低峰期临时调高`maxUnavailable`；
3. PROD环境修改PDB必须提交运维工单双人审批，禁止随意改动。

## 五、节点维护完整SOP（生产标准流程）
### 5.1 单节点维护步骤
1. 预检查
    ```bash
    # 1.查看当前节点运行的Pod
    kubectl get pods --field-selector spec.nodeName=node-10-0-10-21 -A
    # 2.dry‑run预校验排空
    kubectl drain node-10-0-10-21 --ignore-daemonsets --delete-emptydir-data --dry-run=client
    ```
2. 正式排空节点
    ```bash
    kubectl drain node-10-0-10-21 --ignore-daemonsets --delete-emptydir-data
    ```
3. 验证：节点仅剩余DaemonSet组件Pod（calico‑node、csi‑node、kube‑proxy）。
4. 执行维护操作：
    - 升级内核、系统安全补丁；
    - 更新containerd、kubelet版本；
    - 更换故障硬件；
    - 调整sysctl内核参数。
5. 维护完毕恢复调度
    ```bash
    kubectl uncordon node-10-0-10-21
    ```
6. 后续验证：
    - 新Pod可以正常调度到此节点；
    - 查看Prometheus监控指标，CPU、内存、磁盘负载正常；
    - 业务接口访问正常。

### 5.2 集群多节点分批维护（PROD强制）
> 生产环境禁止一次性同时drain多个节点，避免集群大规模故障。
1. 对第1台节点执行dry‑run → drain；
2. 等待Pod全部迁移完成，观察5‑10分钟业务指标正常；
3. 完成维护执行uncordon；
4. 再处理下一台节点，依次循环。

## 六、drain执行失败的典型场景与解决方案
### 场景1：提示存在不受控制器管理的裸Pod
报错：`cannot delete Pods not managed by ReplicationController, ReplicaSet, Job, DaemonSet or StatefulSet`
- 原因：存在手动创建的Pod，没有控制器；
- 处理方式：确认业务下线之后手动删除该Pod；生产禁止用`--force`。

### 场景2：提示empty‑dir问题
报错：`Pod uses emptyDir`
- 解决：增加参数 `--delete-emptydir-data`。

### 场景3：drain长时间卡住不动
- 原因：PDB minAvailable限制；或者新Pod在其他节点启动失败；
1. 排查新Pod启动失败原因：镜像拉取失败、准入Webhook拒绝、PVC挂载失败、资源不足；
2. 问题修复完毕之后drain会继续执行；
3. PDB问题优先扩容副本。

### 场景4：DaemonSet阻止drain执行
- 解决：添加`--ignore‑daemonsets`参数。

## 七、区分：人为drain排空 vs 节点宕机驱逐
| 项目 | kubectl‑drain（计划内维护） | 节点意外宕机（硬件故障） |
|---|---|---|
| Pod删除时机 | 新Pod就绪之后旧Pod才删除 | Lease超时5min之后才重建Pod，故障期间业务中断 |
| 是否受PDB约束 | 严格遵守PDB | 不受PDB约束，强制重建Pod |
| 节点恢复之后 | uncordon后接收新Pod | 原有旧Pod被控制器自动清理 |
| PVC | PVC保留，仅删除Pod | PVC依旧保留 |

## 八、DEV/FAT/UAT/PROD环境差异化标准
1. DEV环境：
    - 可使用`--force`强制删除Pod；可以一次性排空多个节点；无需遵守PDB；
2. FAT测试环境：
    - drain参数和生产保持一致；必要时工作时段临时调整PDB；可同时排空2台节点；
3. UAT预生产环境：
    - 禁用`--force`；维护放在凌晨低峰窗口；排空之后观察监控指标；
4. PROD生产环境强制约束：
    1. drain前必须执行dry‑run预校验，禁止使用`--force`；
    2. 同一时间只能排空一台节点，排空完成观察5‑10分钟业务指标；
    3. PDB配置禁止随意修改，如需调整必须走工单双人审批；
    4. 维护窗口避开定时备份、CSI‑snapshot快照任务，防止IO打满；
    5. 内核升级、containerd升级完成后观察30分钟监控；
    6. 所有操作会被apiserver审计日志记录留存。

## 九、日常高频命令汇总
```bash
# 禁止调度新Pod
kubectl cordon node-10-0-10-21
# 恢复调度
kubectl uncordon node-10-0-10-21

# 预排空
kubectl drain node-10-0-10-21 --ignore-daemonsets --delete-emptydir-data --dry-run=client
# 正式排空
kubectl drain node-10-0-10-21 --ignore-daemonsets --delete-emptydir-data

# 查看节点污点
kubectl describe node node-10-0-10-21 | grep -A 10 Taints
# 查看节点上运行的Pod
kubectl get pods --field-selector spec.nodeName=node-10-0-10-21 -A
```

## 十、生产最佳实践总结
1. 严格执行顺序：`cordon → drain → 维护 → uncordon`，禁止跳过步骤；
2. 业务必须配置PDB，保障排空期间业务可用性；
3. empty‑dir尽量替换为PVC持久存储，降低drain操作顾虑；
4. 集群版本升级时采用分批`drain‑升级‑uncordon`，实现滚动升级；
5. drain失败优先排查PDB和Pod启动失败问题，禁止粗暴使用`--force`；
6. 废弃节点执行完drain之后再执行`kubectl delete node`。

## 十一、关联文档
1. `node‑lifecycle.md`：节点整体生命周期；
2. `scheduling.md`：污点、标签、亲和调度；
3. `troubleshooting.md`：节点Not‑Ready故障排查；
4. `authorization.md`：RBAC权限；
5. `08‑resource‑pressure.md`：kubelet资源压力驱逐原理。