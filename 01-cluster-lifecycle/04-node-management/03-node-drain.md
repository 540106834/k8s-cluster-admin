# 03-node-drain.md

## 文档元信息

归属模块：Worker 节点管理
前置依赖：00-overview.md、01-node-basics.md
关联文档：04-node-lifecycle.md、05-node-troubleshooting.md、10-runbooks.md
适用场景：节点停机维护、内核升级、硬件更换、节点退役、故障隔离、集群缩容
核心目标：标准化安全排空节点，保障业务不中断、数据不丢失

# 一、核心概念区分

## 1.1 cordon 封锁节点

```bash
kubectl cordon <node-name>
```
作用：标记节点 `spec.unschedulable=true`，**禁止新Pod调度到该节点**，已运行Pod保持正常运行，不驱逐。
适用：提前锁定节点，预留时间做排空准备。

## 1.2 drain 排空节点
```bash
kubectl drain <node-name> [参数]
```
作用：在cordon基础上，**驱逐节点上所有常规Pod**，不驱逐DaemonSet；
驱逐流程：优雅终止Pod（默认30s宽限期）→ 调度器在其他可用节点重建Pod。
适用：需要关机、重启、下线节点的标准操作。

## 1.3 uncordon 解除封锁
```bash
kubectl uncordon <node-name>
```
作用：取消 `unschedulable` 标记，恢复节点调度能力。
适用：节点维护完成、重新投入业务。

# 二、标准安全 drain 完整命令（生产强制模板）
## 2.1 通用生产标准命令
```bash
kubectl drain $NODE_NAME \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=300s \
  --grace-period=30
```
### 参数释义
1. `--ignore-daemonsets`
DaemonSet（calico、kube-proxy、node-exporter等）不驱逐，每节点必须常驻，不加会报错阻断drain。
2. `--delete-emptydir-data`
删除使用 emptyDir 本地临时存储的Pod；不加时存在emptyDir Pod会直接失败，无法排空。
> 风险提示：emptyDir数据随Pod销毁丢失，业务持久化数据必须使用PVC。
3. `--grace-period=30`
Pod优雅退出等待时间，超过后强制kill；有状态应用可调高至60~120s。
4. `--timeout=300s`
整体排空操作超时阈值，大规模节点Pod多时延长。

## 2.2 有状态业务增强版（数据库、中间件）
```bash
kubectl drain $NODE_NAME \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=120 \
  --timeout=600s
```

## 2.3 强制排空（紧急故障隔离，谨慎使用）
仅节点卡死、无法等待优雅退出时使用，会直接切断业务：
```bash
kubectl drain $NODE_NAME \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force
```
`--force`：无视孤立Pod（无控制器管理的裸Pod）强制驱逐，极易丢失数据。

# 三、完整操作流程（标准运维步骤）
## 步骤1：预先封锁节点，阻止新Pod调度
```bash
kubectl cordon $NODE_NAME
# 校验：节点状态显示 SchedulingDisabled
kubectl get nodes
```

## 步骤2：查看节点现有业务Pod（评估影响）
```bash
# 列出节点上所有Pod
kubectl get pods -A --field-selector spec.nodeName=$NODE_NAME
# 过滤业务Pod，排除kube-system组件
kubectl get pods -A --field-selector spec.nodeName=$NODE_NAME | grep -v kube-system
```

## 步骤3：执行安全drain排空
使用上文标准drain命令，实时观察Pod驱逐重建进度。

## 步骤4：校验排空完成
无业务Pod残留即代表排空成功：
```bash
kubectl get pods -A --field-selector spec.nodeName=$NODE_NAME | grep -v DaemonSet
# 无输出 = 排空完成
```

## 步骤5：执行节点维护/关机/重装/下线
内核升级、硬件更换、重启、关机、删除节点等操作。

## 步骤6：节点恢复后解除封锁
```bash
kubectl uncordon $NODE_NAME
# 校验调度恢复
kubectl get nodes
```

# 四、drain 常见报错与修复方案
## 报错1：error: cannot drain node, DaemonSet-managed pods exist
根因：未加 `--ignore-daemonsets`
修复：命令追加 `--ignore-daemonsets`

## 报错2：error: cannot drain node, pods with local storage exist
根因：节点存在使用 emptyDir 的Pod，未加删除参数
修复：追加 `--delete-emptydir-data`，提前确认本地临时数据可丢弃

## 报错3：error: pod has no controller, use --force to override
根因：存在裸Pod（直接kubectl run创建，无deployment/statefulset控制器）
修复：
1. 优先删除无用裸Pod `kubectl delete pod <pod-name> -n <ns>`
2. 紧急场景使用 `--force` 参数强制排空

## 报错4：drain 长时间卡住，Pod无法驱逐
排查方向：
1. Pod preStop钩子执行阻塞，检查容器日志
2. PV/PVC存储绑定异常，无法解绑
3. 其他节点资源不足，无节点可调度重建Pod
处理：扩容集群节点、临时释放资源、调高grace-period超时时间

# 五、特殊场景处理规范
## 5.1 StatefulSet 有状态应用 drain
1. 提前确认PVC存储为远程存储（块存储/对象存储），非本地盘
2. 拉长优雅退出时间 `--grace-period=120`
3. 排空完成后观察Pod有序重建，确认数据正常挂载

## 5.2 单副本关键业务节点排空
1. 提前扩容副本数至2，避免业务中断
2. 执行drain，等待新Pod就绪后再操作原节点
3. 维护完成后可按需缩容回原副本数

## 5.3 故障失联节点（Unknown状态）无法登录执行drain
节点网络中断、关机无法ssh，无法正常排空：
1. 先确认业务Pod已自动漂移至其他节点
2. 强制删除失效Node对象
```bash
kubectl delete node $NODE_NAME
```
3. 修复主机后重新执行节点接入（02-node-join.md）

## 5.4 批量多节点滚动维护规范
禁止同时drain多个承载核心业务的节点，滚动流程：
1. 单次仅操作1台worker节点
2. drain完成，确认所有业务Pod就绪
3. 维护完成uncordon恢复调度
4. 再操作下一台节点

# 六、风险管控清单（操作前必查）
1. 确认集群剩余节点资源充足，可承载被驱逐Pod
2. 核心业务副本数≥2，避免单副本业务断流
3. 确认emptyDir临时数据无持久化需求
4. 有状态应用提前核对PVC存储可用性
5. 避开业务高峰时段执行排空操作
6. 记录操作时间、节点名称，便于故障回溯

# 七、关联文档跳转
- 节点全生命周期上线/维护/退役：04-node-lifecycle.md
- 节点故障隔离与应急处理：05-node-troubleshooting.md
- 新增节点接入集群：02-node-join.md
- 线上事故标准化处理流程：10-runbooks.md