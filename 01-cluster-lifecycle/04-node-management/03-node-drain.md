# 03‑worker‑node‑management/03‑node‑drain.md

## 一、文档基础信息

- 文件路径：`03‑worker‑node‑management/03‑node‑drain.md`
- 前置文档：
  - `00‑overview.md`、`01‑node‑basics.md`、`04‑node‑lifecycle.md`
  - `02‑workload‑management/06‑pod‑disruption‑budget.md`
- 集群基准：Kubernetes‑1.32.13、Lease模式、containerd‑2.1.5、PDB、StatefulSet、Deployment、DaemonSet、CSI‑PV、Calico网络、内网离线环境。
- 适用环境：DEV / FAT / UAT / PROD。
- 文档核心：cordon、drain内部执行逻辑、驱逐优先级、PDB约束、参数详解、分批排空规范、dry‑run预检查、drain失败原因、生产标准命令、事后验证步骤。

## 二、Cordon与Drain概念区分

### 2.1 kubectl cordon（隔离调度，只禁止新建Pod）

```bash
kubectl cordon k8s-node-192-168-11-163
```

内部执行逻辑：

1. 修改`spec.unschedulable=true`；自动添加污点 `node.kubernetes.io/unschedulable:NoSchedule`；
2. kube‑scheduler不再把Pod调度到此节点；
3. **已经运行在节点上的Pod不会被删除，业务继续运行**。

取消隔离：

```bash
kubectl uncordon k8s-node-192-168-11-163
```

### 2.2 kubectl drain（排空节点，迁移现有Pod）

drain内部会自动先执行cordon，之后驱逐节点内Pod：

1. 控制器（ReplicaSet/StatefulSet）在其他可用节点新建就绪Pod；旧Pod才会被删除；
2. 驱逐过程严格遵守PDB(PodDisruptionBudget)，保证min‑available；
3. DaemonSet默认不会被drain删除；
4. emptyDir临时卷默认阻止drain执行；PVC持久卷仅删除Pod，PV/PVC本身保留。

## 三、kubectl‑drain参数详细解析（生产必记）

### 3.1 生产环境标准命令

```bash
# 生产推荐完整命令
kubectl drain k8s-node-192-168-11-163 --ignore-daemonsets --delete-emptydir-data
```

1. `--ignore‑daemonsets`
    - 跳过calico‑node、csi‑node、kube‑proxy、filebeat等DaemonSet组件；
    - 不加此参数，drain会因为DaemonSet Pod拒绝执行排空。
2. `--delete‑emptydir‑data`
    - emptyDir属于节点本地临时存储；删除Pod会丢失emptyDir里的数据；
    - 明确确认接受临时目录数据丢失，drain才会执行；
    - PVC不会受此参数影响。
3. 生产环境禁止使用的参数：
    - `--force`：强制删除不受控制器管理的裸Pod（静态Pod、手动创建Pod），生产严禁使用；
    - `--grace‑period‑seconds`：缩短优雅终止时间，可能导致业务异常。

### 3.2 预执行dry‑run（变更前必做）

```bash
kubectl drain k8s-node-192-168-11-163 --ignore-daemonsets --delete-emptydir-data --dry-run=client
```

dry‑run只输出计划要驱逐哪些Pod，不会真实执行，提前发现问题。

## 四、Pod驱逐优先级（kube‑scheduler执行顺序）

1. 优先驱逐顺序由Pod QoS等级决定：
    `Best‑Effort（尽力服务） > Burstable（突发） > Guaranteed（有保障）`
2. 资源压力驱逐（kubelet本地驱逐）和drain排空驱逐逻辑一致。
3. 资源控制器处理顺序：
    1. Deployment、ReplicaSet、Job、CronJob：先在其他节点拉起新Pod就绪后删除旧Pod；
    2. StatefulSet：按照Pod编号从大到小依次删除；受partition策略控制；
    3. DaemonSet：默认不会被drain驱逐；升级DaemonSet由控制器滚动更新；
    4. kube‑system内系统Pod默认跳过drain排空。

## 五、PDB对drain的约束（生产最常见阻塞原因）

### 5.1 PDB作用

PodDisruptionBudget定义最小可用副本数量：`minAvailable`或者`maxUnavailable`。

- 如果驱逐后就绪副本小于minAvailable → drain会暂停卡住，不会继续驱逐Pod。

### 5.2 生产环境处理方案

1. 优先方案：扩容副本数量，提高整体冗余，再执行drain排空；
2. 备选方案（仅UAT/FAT）：业务低峰期临时调高maxUnavailable，排空完成恢复PDB配置；

> PROD禁止随意修改PDB配置，必须走工单审批。

示例PDB：

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

## 六、PROD环境分批排空标准流程（强制遵守）

> 生产禁止一次性同时drain多个节点，避免集群大规模故障。

1. 步骤1：dry‑run预检查
    ```bash
    kubectl drain k8s-node-192-168-11-163 --ignore-daemonsets --delete-emptydir-data --dry-run=client
    ```
2. 步骤2：执行正式drain命令；
3. 步骤3：持续观察Pod重建状态：
    ```bash
    kubectl get pods -n prod -w
    kubectl top pods -n prod
    ```
4. 等待所有业务Pod迁移到其他节点并且就绪，观察5‑10分钟；确认业务接口、数据库访问正常；
5. 执行节点维护（内核升级、containerd升级、硬件更换）；
6. 维护完毕恢复节点调度：
    ```bash
    kubectl uncordon k8s-node-192-168-11-163
    ```
7. 再操作下一个节点。

## 七、drain完成后节点状态判断
### 7.1 drain成功标志
1. 业务Pod全部被驱逐；节点仅剩DaemonSet组件Pod；
    ```bash
    kubectl get pods --field-selector spec.nodeName=k8s-node-192-168-11-163 -A
    ```
    只剩下calico‑node、csi‑node、kube‑proxy、filebeat；
2. 节点状态依然Ready，但是unschedulable=true；
3. PVC资源不会被删除，依旧保留；

### 7.2 维护结束验证清单
1. uncordon恢复调度；
2. 新Pod可以正常调度到此节点；
3. node‑exporter指标正常上报；
4. 节点四个压力条件全部为false；
5. Prometheus监控面板查看节点CPU内存负载正常。

## 八、drain执行失败的常见原因及解决方案
### 问题1：drain长时间卡住无法继续驱逐Pod
- 原因：PDB minAvailable限制，驱逐后副本不足；
- 解决：扩容副本或者低峰期临时修改PDB。

### 问题2：提示存在独立裸Pod（静态Pod）
报错：`cannot delete Pods not managed by ReplicationController, ReplicaSet, Job, DaemonSet or StatefulSet`
- 原因：存在手动创建Pod，没有控制器管理；
- 生产处理：手动确认业务安全之后删除裸Pod，严禁使用`--force`。

### 问题3：提示empty‑dir数据风险，拒绝执行drain
- 原因：Pod挂载emptyDir，没有添加`--delete‑emptydir‑data`；
- 解决：带上该参数执行drain。

### 问题4：新Pod在其他节点启动失败导致旧Pod无法删除
排查步骤：
1. 查看events：`kubectl get events -n prod`；
2. 镜像拉取失败、准入Webhook拒绝、PVC挂载失败、资源不足；
3. 问题修复后旧Pod才会被清理。

### 问题5：DaemonSet Pod阻止drain
- 解决：增加`--ignore‑daemonsets`参数。

## 九、节点宕机后的Pod驱逐机制（区分主动drain和节点宕机）
1. 手动drain：人为排空Pod，控制器主动重建Pod；
2. 节点宕机场景：
    - kubelet停止续约Lease；
    - node‑controller等待`pod‑eviction‑timeout=5min`超时；
    - 超时后才会在其他节点重建Pod；
    - 原节点恢复上线后，旧Pod会被直接删除。

## 十、DEV/FAT/UAT/PROD差异化标准
1. DEV环境：
    - 可以使用`--force`强制删除Pod；不用遵守PDB；无需分批执行。
2. FAT测试环境：
    - drain参数和生产一致；必要时工作时段临时修改PDB；
    - 可以一次性排空2台节点，但需要提前确认。
3. UAT预生产环境：
    - 禁止`--force`；严格分批排空；
    - drain操作放在凌晨低峰窗口，操作前后观察监控指标。
4. PROD生产环境（强制约束）
    1. drain前必须执行dry‑run预校验；禁止使用`--force`参数；
    2. 一次只能排空一台节点，排空完成观察5‑10分钟业务指标；
    3. PDB配置不允许随意修改，调整PDB必须走工单双人审批；
    4. 节点维护避开定时备份、快照任务，防止IO打满；
    5. 内核升级、containerd升级完成之后必须观察30分钟；
    6. drain操作全程被apiserver审计日志记录。

## 十一、高频命令汇总
```bash
# 禁止调度新Pod
kubectl cordon k8s-node-192-168-11-163

# 恢复调度
kubectl uncordon k8s-node-192-168-11-163

# 预执行排空（dry‑run）
kubectl drain k8s-node-192-168-11-163 --ignore-daemonsets --delete-emptydir-data --dry-run=client

# 正式排空（生产标准）
kubectl drain k8s-node-192-168-11-163 --ignore-daemonsets --delete-emptydir-data

# 查看节点上运行的Pod
kubectl get pods --field-selector spec.nodeName=k8s-node-192-168-11-163 -A

# 查看节点污点
kubectl describe node k8s-node-192-168-11-163 | grep Taints
```

## 十二、生产最佳实践
1. 遵循标准顺序：`cordon → drain → 维护 → uncordon`，不要跳过步骤；
2. 业务务必配置PDB，防止排空期间业务不可用；
3. 尽量把empty‑dir临时存储替换成PVC持久存储，减少drain顾虑；
4. 生产维护窗口选凌晨低峰，错开定时备份、CSI快照任务；
5. drain失败优先排查PDB、Pod启动失败问题，不要粗暴使用--force；
6. 集群升级时采用分批drain‑升级‑uncordon，实现滚动升级。

## 十三、关联文档
1. `04‑node‑lifecycle.md`：节点完整生命周期；
2. `08‑resource‑pressure.md`：kubelet资源压力驱逐机制；
3. `02‑workload‑management/06‑pod‑disruption‑budget.md` PDB配置；
4. `05‑node‑troubleshooting.md`：节点Not‑Ready故障排查；
5. `07‑monitoring‑and‑troubleshooting`：排空期间业务指标观测；
6. `10‑runbooks.md`：节点宕机Runbook应急手册。