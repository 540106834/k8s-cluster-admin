# 03‑worker‑node‑management/04‑node‑lifecycle.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/04‑node‑lifecycle.md`
- 前置文档：
  - `00‑overview.md`、`01‑node‑basics.md`、`02‑node‑join.md`、`03‑node‑drain.md`
  - `02‑workload‑management/06‑pod‑disruption‑budget.md`
- 集群基准：Kubernetes‑1.32.13、Lease心跳机制、containerd‑2.1.5、PDB、Taint‑Toleration、CSI、Calico‑3.30.4、ipvs‑kube‑proxy，Ubuntu‑22.04、内网离线环境。
- 适用环境：DEV / FAT / UAT / PROD。
- 文档内容：节点生命周期整体阶段划分、组件分工、节点上线、日常运行、维护隔离、排空维护、退役下线全流程、区分人为维护和节点宕机两种场景、生产SOP、操作红线、故障辨析。

## 二、参与节点生命周期的核心组件分工
1. **kubelet**
    1. 每10s更新对应节点的Lease资源，完成心跳续约；
    2. 上报节点4种状态（Ready、MemoryPressure、DiskPressure、PIDPressure）；
    3. 执行容器启停、探针检查；执行kubelet本地驱逐（资源压力场景）；
    4. 接收apiserver指令，配合完成Pod退出。
2. **Node‑Controller（控制平面）**
    1. 监听Lease资源；默认 `pod‑eviction‑timeout = 5m0s`；
    2. Lease超时5分钟判定节点宕机；触发跨节点重建Pod；
    3. 更新Node对象Ready状态。
3. **kube‑scheduler**
    识别`unschedulable`污点，不再向该节点调度Pod；结合污点、亲和性完成调度决策。
4. **ReplicaSet / StatefulSet Controller**
    当Pod被drain驱逐或者节点宕机超时后，在其他可用节点新建Pod，保证副本数量。
5. **PDB控制器**
    排空期间约束最小可用副本数，防止批量排空造成业务不可用。

## 三、节点完整生命周期5个阶段
### 阶段1：初始化上线阶段（Init）
执行流程：操作系统初始化 → 内核参数配置 → 离线安装containerd、kubelet → kubeadm‑join接入集群。
1. kubelet启动后向apiserver注册Node对象；持续更新Lease资源；
2. calico‑node、csi‑node、kube‑proxy、node‑exporter DaemonSet Pod启动；
3. kubelet检查内存、磁盘、PID压力全部为false，节点状态变为`Ready=True`；
4. 运维打上标准化标签 `env、node‑role、rack、hardware‑type、os‑version`；
5. Prometheus识别新增节点，开始采集监控指标；调度器可以向节点分配Pod。

> 失败场景：时间不同步、containerd配置错误、防火墙拦截会导致节点一直NotReady。

### 阶段2：正常运行阶段（Active）
1. kubelet持续10s续约一次Lease；
2. 节点4个压力条件全部为false；
3. Scheduler根据Label、Taint、节点亲和调度Pod；
4. kubelet执行就绪探针、存活探针；containerd管理容器生命周期；
5. node‑exporter持续上报系统指标；定期清理无用镜像；
6. 若磁盘、内存、进程数过高触发Pressure，kubelet自行驱逐低优先级Pod（依据QoS）。

### 阶段3：调度隔离阶段（Cordon，维护前置）
执行命令：`kubectl cordon node‑10‑0‑10‑21`
1. 修改`node.spec.unschedulable = true`；自动添加污点 `node.kubernetes.io/unschedulable:NoSchedule`；
2. kube‑scheduler不再将新Pod调度到此节点；
3. **已经运行的Pod继续正常运行，不会被删除**；
4. 此时可以做排空前检查：dry‑run执行drain预校验。

> 取消隔离：`kubectl uncordon node‑10‑0‑10‑21`，恢复调度。

### 阶段4：节点排空与维护阶段（Drain & Maintenance）
1. 执行`kubectl drain`：内部自动先执行cordon；
2. 遵循PDB约束，控制器在其他节点启动就绪Pod之后再删除旧Pod；
3. DaemonSet组件（calico‑node、csi‑node、filebeat）保留在节点；业务Pod全部迁移；
4. 排空完毕之后执行维护工作：
    - 升级系统内核、安装安全补丁；
    - 升级containerd版本；
    - 更换内存、硬盘等硬件设备；
    - 修改sysctl内核参数。
5. 维护结束执行`kubectl uncordon`，调度器重新分配Pod到此节点。

> drain失败常见原因：PDB限制、存在裸Pod、empty‑dir未指定参数。

### 阶段5：节点退役下线阶段（Decommission）
1. 前置条件：drain排空完成，业务Pod全部迁移完毕；PVC备份和CSI快照执行完成；
2. 控制平面删除node对象：`kubectl delete node node‑10‑0‑10‑21`；
3. 节点主机停止kubelet、containerd服务；关闭服务器；
4. 清理CSI‑node残留注册信息；清理Harbor镜像缓存；
5. Prometheus移除该节点监控配置；从机房资产清单剔除服务器。

> 区分特殊场景：节点意外宕机（服务器断电、内核崩溃）
> 1. kubelet停止续约Lease；
> 2. Node‑Controller等待5分钟超时；判定节点Down；
> 3. ReplicaSet在其他节点重建Pod；
> 4. 故障节点后续开机上线：kubelet重新续约Lease，但原来的旧Pod会被控制器删除。

## 四、人为维护 vs 节点宕机处理逻辑对比
| 项目 | 人工执行kubectl drain（计划内维护） | 节点宕机（服务器故障，计划外） |
|------|------------------------------------|--------------------------------|
| Pod删除时机 | 新Pod就绪之后旧Pod才删除，业务平滑迁移 | Lease超时5分钟后才会重建Pod；故障期间服务中断 |
| PDB约束 | 严格遵守PDB minAvailable | 不受PDB限制，强制重建Pod |
| 旧节点恢复后 | uncordon之后接收新Pod | 节点上线后原有旧Pod直接被清除 |
| PVC | PVC保留，只是删除Pod | PVC依然保留 |
| 运维可控性 | 完全可控，低峰窗口执行 | 被动触发，不可控 |

## 五、节点上线标准化SOP（PROD）
1. 操作系统预处理：关闭swap、配置sysctl、chronyd时间同步；
2. 离线部署containerd‑2.1.5（cgroup驱动为systemd，镜像仓库指向内网Harbor）；
3. 离线部署kubeadm、kubelet、kubectl，版本严格1.32.13；
4. 执行kubeadm‑join接入集群；
5. 给节点打上标准化标签；
6. 核查Lease续约正常、DaemonSet组件全部就绪；
7. 部署测试Pod验证网络、DNS、PVC挂载；
8. Prometheus指标采集正常，观察30分钟指标无异常才算上线完成；
9. 填写运维工单双人复核。

## 六、节点退役下线标准SOP（PROD强制步骤）
1. 业务低峰窗口执行dry‑run预排空：
    ```bash
    kubectl drain node‑10‑0‑10‑21 --ignore-daemonsets --delete-emptydir-data --dry-run=client
    ```
2. 正式排空节点，等待Pod全部迁移完毕，观察5‑10分钟业务运行正常；
3. 确认PVC、CSI快照、数据库备份全部完成；
4. 在控制平面删除node对象；
5. 登录主机停止kubelet和containerd；
6. 关闭服务器；清理节点残留配置；
7. 移除Prometheus监控配置；更新机房资产清单；
8. 归档运维工单。

## 七、DEV/FAT/UAT/PROD差异化约束
1. DEV：节点上线标签可简化；drain可以使用`--force`强制驱逐Pod；退役无需工单。
2. FAT：sysctl、containerd版本对齐生产；drain分批执行；退役简单记录即可。
3. UAT：上线检查清单逐条核对；禁止`--force`；维护选择凌晨低峰窗口。
4. PROD生产环境（强制红线）
    1. 节点上线前内核版本、containerd版本、sysctl参数必须和现有worker节点完全一致；
    2. drain排空严禁使用`--force`；一次只排空一台节点；排空完成观察业务指标；
    3. PDB配置禁止随意修改，如需调整必须提交工单双人审批；
    4. 节点内核升级、containerd升级、退役全部选择凌晨业务低峰；避开定时备份和快照任务；
    5. 节点宕机之后严格按照runbook执行应急处置；事后进行故障复盘；
    6. 节点上线、退役操作全部被apiserver审计日志记录。

## 八、常用核心命令
```bash
# 禁止调度新Pod
kubectl cordon node‑10‑0‑10‑21

# 恢复调度
kubectl uncordon node‑10‑0‑10‑21

# 生产排空节点
kubectl drain node‑10‑0‑10‑21 --ignore-daemonsets --delete-emptydir-data

# 删除节点（退役）
kubectl delete node node‑10‑0‑10‑21

# 查看Lease续约状态
kubectl get lease -n kube-system

# 查看节点污点
kubectl describe node node‑10‑0‑10‑21 | grep Taints

# 查看节点上运行的Pod
kubectl get pods --field-selector spec.nodeName=node‑10‑0‑10‑21 -A
```

## 九、高频故障场景分析
### 场景1：执行drain长时间卡住
- 根因：PDB限制，驱逐后可用副本小于minAvailable；
- 解决方案：扩容副本数；FAT/UAT环境可临时调高maxUnavailable，PROD走工单审批。

### 场景2：节点宕机之后Pod迟迟没有重建
- 根因：node‑controller等待`pod‑eviction‑timeout=5min`；Lease还未超时；
- 排查：`kubectl get lease -n kube-system`查看最后续约时间。

### 场景3：节点cordon之后依然有Pod调度上来
- 根因：Pod yaml中硬编码`nodeName`字段，绕过调度器直接绑定节点；调度器污点规则失效；
- 解决方案：移除spec.nodeName字段，交由scheduler调度。

### 场景4：节点恢复上线后旧Pod没有自动清理
- 根因：节点刚恢复Lease续约成功，控制器延迟一段时间清理旧Pod；等待几分钟即可。

## 十、生产最佳实践
1. 严格遵守生命周期顺序：`初始化 → 正常运行 → cordon → drain → 维护 → uncordon/delete node`，禁止跳过步骤；
2. 区分计划内维护和意外宕机，计划内维护全部选择业务低峰窗口；
3. 集群所有业务必须配置PDB，保障排空期间业务可用性；
4. 上线和退役前必须校验监控指标和备份任务；
5. 定期模拟节点宕机演练，验证Pod跨节点重建逻辑；
6. 废弃节点及时执行delete node，避免集群内残留无效node对象。

## 十一、关联文档
1. `01‑node‑basics.md`：节点状态和Lease原理；
2. `03‑node‑drain.md`：drain驱逐逻辑、PDB约束；
3. `08‑resource‑pressure.md`：kubelet资源压力驱逐机制；
4. `05‑node‑troubleshooting.md`：节点Not‑Ready排障；
5. `10‑runbooks.md`：节点宕机应急处置手册；
6. `07‑monitoring‑and‑troubleshooting`：节点监控指标和USE告警模型。