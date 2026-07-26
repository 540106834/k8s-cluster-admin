# replace-worker-node.md
# Kubernetes 故障 Worker 节点下线、替换、恢复完整运维手册
## 一、文档定位
本文针对 Worker 节点硬件故障、系统损坏、内核异常、磁盘故障、安全漏洞等场景，提供**节点驱逐 → 下线隔离 → 销毁故障节点 → 新增替换节点 → 业务回迁 → 全量健康校验**标准化闭环操作流程；适配 kubeadm 自建企业集群，配套集群交付、扩容、ETCD 备份、集群健康校验文档，是生产节点故障应急处置SOP。  
前置依赖：build-kubernetes-cluster.md、expand-worker-nodes.md、validate-cluster-health.md、backup-etcd-cluster.md  
下游关联：validate-cluster-health.md

## 二、前置判断与风险评估
### 2.1 节点替换适用场景
满足以下任意场景，执行节点替换流程：
1. 硬件故障：硬盘坏道、内存报错、网卡硬件损坏，无法短期修复
2. 系统级故障：内核panic、容器运行时反复崩溃、磁盘只读挂载无法修复
3. 安全风险：节点被入侵、高危漏洞无法批量修复，需重装系统
4. 资源报废：老旧服务器硬件退役、机型统一迭代升级
5. 无法恢复的网络异常：网卡驱动永久故障，CNI无法正常运行

### 2.2 禁止直接操作风险说明
1. 严禁直接关机故障节点不执行驱逐：Pod 无调度缓冲时间，业务大规模中断
2. 严禁未排空节点直接删除节点资源：残留 Volume、Endpoint、iptables 规则引发集群异常
3. 有状态应用（MySQL/Redis/Elasticsearch）必须提前确认 PV 存储共享能力，避免数据丢失
4. 替换操作窗口期建议选择业务低峰，预留 30~60 分钟操作缓冲时间

### 2.3 操作前置检查项
1. 集群整体状态：所有 Master 节点 Ready、ETCD 集群 healthy，无告警
2. 备份校验：已完成 ETCD 全量快照备份，备份文件可正常恢复
3. 存储校验：CSI 存储集群正常，PV 支持跨节点挂载
4. 资源配额：集群剩余节点资源可承载故障节点全部业务 Pod（CPU/内存预留20%缓冲）
5. 监控告警：提前屏蔽该节点告警，操作完成后恢复

## 三、阶段1：故障节点标记隔离，禁止新Pod调度
### 3.1 节点污点封锁调度，阻止新业务调度至故障节点
```bash
# 节点名称 NODE_BAD=故障节点主机名
export NODE_BAD=worker-03

# 添加不可调度污点，拒绝所有新Pod调度
kubectl taint nodes $NODE_BAD node-disabled=true:NoSchedule
```

### 3.2 确认节点状态，统计节点上所有业务资源
```bash
# 查看节点当前状态（大概率 NotReady）
kubectl get node $NODE_BAD

# 统计节点上所有Pod（区分有状态/无状态）
kubectl get pods --all-namespaces -o wide | grep $NODE_BAD

# 统计节点绑定PV，后续验证跨节点挂载
kubectl get pv | grep $NODE_BAD
```

### 3.3 特殊资源前置处理（有状态组件）
1. StatefulSet：确认副本数≥2，允许驱逐后自动重建
2. 本地存储PV（hostPath/local PV）：**无法跨节点迁移**，需手动备份数据后重建
3. 中间件集群（ES/MongoDB/Redis集群）：确认集群副本机制，单节点下线不丢失数据

## 四、阶段2：平滑驱逐节点上全部Pod（核心业务无中断）
### 4.1 执行节点排空驱逐（kubectl drain）
```bash
# 强制驱逐，忽略DaemonSet（CNI/监控Agent后续手动清理）
# --ignore-daemonsets：calico-node/cilium/node-exporter等DaemonSet不参与驱逐
# --delete-emptydir-data：清空临时本地存储emptyDir
kubectl drain $NODE_BAD --ignore-daemonsets --delete-emptydir-data --timeout=300s
```
参数说明：
- timeout：驱逐超时时间，大型业务集群建议300秒
- 不添加`--force`：优先优雅驱逐，等待容器正常终止；仅完全无响应节点追加--force

### 4.2 驱逐进度监控
```bash
# 实时查看节点剩余Pod，直至除DaemonSet外全部清空
watch kubectl get pods --all-namespaces -o wide | grep $NODE_BAD

# 查看事件，排查驱逐失败Pod（资源不足、污点容忍、本地存储）
kubectl get events --all-namespaces --field-selector involvedObject.name=$NODE_BAD
```

### 4.3 驱逐失败故障处理
1. 集群资源不足：临时扩容其他节点资源，或临时调整应用资源requests
2. Pod容忍节点不可调度污点：修改Pod容忍策略，重新执行drain
3. 使用local hostPath无共享存储：手动备份数据，删除Pod重建

## 五、阶段3：从集群中删除故障节点资源
### 5.1 删除集群节点对象
所有业务Pod驱逐完成后，在管理节点执行删除：
```bash
kubectl delete node $NODE_BAD
```

### 5.2 登录故障节点清理集群残留配置（可选，重装系统可跳过）
若服务器仅临时下线、后续重装复用主机名，需清理 k8s 组件残留：
```bash
# 重置节点kubeadm配置
kubeadm reset -f

# 清理容器残留镜像与容器
crictl rm -a ; crictl rmi -a

# 删除网络、证书、kubelet配置目录
rm -rf /var/lib/kubelet /etc/kubernetes /var/lib/cni /opt/cni
```

### 5.3 底层资产下线
1. 机房服务器：下架硬件、停机断电、移除硬盘
2. 云主机：销毁云服务器实例，释放弹性IP、磁盘
3. 负载均衡/安全组：移除该节点后端注册

## 六、阶段4：新增替换Worker节点（流程同节点扩容 expand-worker-nodes.md）
### 6.1 新节点系统初始化
1. 操作系统版本、内核、容器运行时版本与存量节点统一
2. 内核调优、网络参数、chronyd时间同步、磁盘分区标准化配置
3. 预装依赖：containerd、kubeadm/kubelet/kubectl、CNI依赖工具
4. 关闭防火墙/放行集群通信端口，安全组放通隧道、apiserver端口

### 6.2 节点加入集群
1. Master节点生成节点加入令牌
```bash
# 创建永久有效加入令牌
kubeadm token create --print-join-command --ttl 0
```
2. 新Worker节点执行join命令加入集群
```bash
kubeadm join apiserver-lb:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxxx
```

### 6.3 节点基础标准化配置
1. 统一节点标签、业务污点、资源预留
```bash
# 新增业务标签，和原有故障节点保持一致
kubectl label node new-worker-03 node-role.kubernetes.io/worker=
# 移除默认NoSchedule污点，允许调度业务
kubectl taint nodes new-worker-03 node-role.kubernetes.io/control-plane-
```
2. 内核网络、TCP、conntrack参数同步集群调优标准
3. 确认kubelet正常启动，节点状态变为Ready

### 6.4 CNI网络组件就绪校验
```bash
# 查看CNI Pod正常调度至新节点
kubectl get ds -n kube-system | grep cni
# 验证网桥、隧道设备正常UP
ip link show cni0
```

## 七、阶段5：业务Pod自动/手动回迁验证
### 7.1 无状态应用（Deployment）
集群调度器自动将驱逐的Pod调度至新节点，无需手动干预：
```bash
# 监控Deployment副本就绪状态
kubectl get deploy --all-namespaces | grep -v 1/1
```

### 7.2 有状态应用（StatefulSet）
自动重建Pod，校验PV跨节点正常挂载：
```bash
# 进入Pod验证数据完整性
kubectl exec -it statefulset-db-0 -- cat /data/test.file
```

### 7.3 DaemonSet组件回迁
CNI、监控、日志组件DaemonSet自动创建Pod至新节点，校验日志无报错：
```bash
kubectl logs -n kube-system daemonset/calico-node node=new-worker-03
```

## 八、阶段6：全维度集群健康验收（复用validate-cluster-health.md标准）
分层校验，全部通过判定节点替换完成：
1. 基础设施层：新节点CPU/内存/磁盘/网卡无硬件报错，软中断均衡
2. 节点调度层：所有节点Ready，资源分配水位正常，无调度失败事件
3. 网络层：同/跨节点Pod互通、Service访问、外网访问全部正常
4. 存储层：所有PV正常绑定，读写数据无丢失
5. 业务层：所有Deployment/StatefulSet副本就绪，接口访问正常无报错
6. 控制平面：ETCD健康、无告警、组件日志无异常

## 九、阶段7：运维收尾工作
1. 监控恢复：取消该节点告警屏蔽，新增节点接入监控大盘
2. 归档记录：记录故障节点ID、替换时间、故障原因、操作人
3. 备份复核：再次执行一次ETCD全量备份，留存节点替换完成快照
4. 资源清理：故障服务器磁盘数据销毁、资产台账更新

## 十、高频故障与应急处理
### 1. kubectl drain驱逐大量Pod失败，提示资源不足
根因：剩余集群CPU/内存无法承载全部业务负载
处理：临时扩容其他节点，或分批驱逐业务，分批次迁移

### 2. 本地hostPath存储应用驱逐后数据丢失
根因：本地磁盘无法跨节点迁移
处理：替换前手动备份本地目录，新节点重建后恢复数据；长期改造为共享CSI存储

### 3. 新节点加入集群后状态NotReady，CNI启动失败
根因：安全组未放行隧道端口、内核ip_forward未开启、系统参数不匹配
处理：核对节点初始化标准配置，放行UDP8472/6081隧道端口

### 4. 替换后StatefulSet Pod无法挂载原有PV
根因：存储节点亲和性绑定旧故障节点
处理：删除PV中nodeAffinity绑定字段，允许跨节点挂载

### 5. 故障节点删除后集群iptables残留规则导致访问异常
根因：CNI/kube-proxy未清理旧节点规则
处理：重启对应DaemonSet（calico-node/kube-proxy）自动刷新规则

## 十一、生产运维规范
1. 故障节点必须先drain排空业务，禁止直接关机删除节点
2. 有状态本地存储业务替换前强制手动备份数据，避免数据丢失
3. 新节点硬件、系统、内核、配置必须与集群存量节点标准化统一
4. 节点替换完成后严格执行全套集群健康验收，确认业务无异常
5. 重大业务集群节点替换操作留存操作日志、时间戳、验收记录归档
6. 定期硬件巡检，提前预判故障节点，低峰窗口主动替换，规避突发故障业务冲击

## 十二、关联文档索引
build-kubernetes-cluster.md 集群初始化、节点join流程
expand-worker-nodes.md 常规节点扩容标准化步骤
validate-cluster-health.md 集群全维度健康验收标准
backup-etcd-cluster.md 操作前ETCD备份规范
03-network-data-path.md 新节点网络连通校验标准
06-network-debug.md 节点网络故障排查工具流程