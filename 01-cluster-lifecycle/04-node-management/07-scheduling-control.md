# 03‑worker‑node‑management/07‑scheduling‑control.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/07‑scheduling‑control.md`
- 前置文档：
  `00‑overview.md`、`01‑node‑basics.md`、`04‑node‑lifecycle.md`、`02‑workload‑management`工作负载文档
- 集群基准：Kubernetes‑1.32.13，kube‑scheduler、Lease机制，Taint‑Toleration、Node‑Affinity、Pod‑Affinity/Anti‑Affinity，Node‑Selector、标准化节点Label，Calico‑3.30.4，离线内网环境。
- 适用环境：DEV / FAT / UAT / PROD
- 文档内容：调度整体流程、Node‑Selector、Node亲和与反亲和、污点容忍、Pod亲和反亲和、内置污点、自定义污点、调度失败常见原因、生产落地示例、调度排障命令。

## 二、Kube‑Scheduler整体调度原理
### 2.1 调度两大阶段
1. **Predicate（预选）**：过滤掉不满足条件的节点；资源不足、污点不匹配、节点亲和不满足、端口冲突、Node‑Name硬绑定直接淘汰；
2. **Priority（优选打分）**：对剩余可用节点打分，分数最高节点最终绑定Pod；
   - `LeastRequestedPriority`：优先选择剩余资源更多节点（默认核心策略）；
   - `NodeAffinityPriority`：节点亲和权重打分；
   - `ImageLocalityPriority`：优先选择本地已经存在镜像的节点。
> 调度结果写入Pod的`spec.nodeName`字段；之后kubelet发现Pod分配到本节点，拉起容器。

### 2.2 调度约束四层优先级（优先级从高到低）
1. `spec.nodeName`：硬绑定节点名称，绕过调度器直接指定节点，优先级最高；
2. Taint‑Toleration（污点‑容忍）：NoSchedule > PreferNoSchedule > NoExecute；
3. Node‑Affinity / Node‑Selector：节点选择；
4. Pod‑Affinity / Pod‑Anti‑Affinity：Pod之间亲和反亲和。

## 三、第一层：Node‑Selector（最简单节点选择）
### 3.1 用法：基于标签精准匹配节点
节点提前打上标签：
```bash
kubectl label node node‑10‑0‑10‑21 rack=rack‑01 hardware‑type=ssd
```
Pod配置：
```yaml
spec:
  nodeSelector:
    rack: rack-01
    hardware-type: ssd
```
- 只有同时拥有这两个标签的节点才可以运行该Pod；
- 缺点：只有完全匹配或者不匹配，没有偏好选项；只能等值匹配，不支持`In、NotIn、Exists`。

## 四、第二层：Node‑Affinity（节点亲和，生产首选）
分为`requiredDuringSchedulingIgnoredDuringExecution`（硬约束）和`preferredDuringSchedulingIgnoredDuringExecution`（软偏好）。
### 4.1 required（硬约束，不满足就调度失败，Pod进入Pending）
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: rack
            operator: In
            values: ["rack-01","rack-02"]
```
operator可选值：`In、NotIn、Exists、DoesNotExist、Gt、Lt`。

### 4.2 preferred（软偏好，优先调度，没有合适节点依然可以调度到其他节点）
```yaml
preferredDuringSchedulingIgnoredDuringExecution:
- weight: 80
  preference:
    matchExpressions:
    - key: hardware-type
      operator: In
      values: ["ssd"]
```
weight取值范围1‑100，数值越大优先级越高。

> 生产最佳实践：核心业务使用required，普通业务使用preferred。

## 五、第三层：Taint‑Toleration（污点与容忍，隔离节点核心机制）
### 5.1 三种污点效果（Taint Effect）
1. `NoSchedule`：没有对应容忍的Pod禁止调度到此节点（最常用）；
2. `PreferNoSchedule`：尽量不调度，实在没有节点仍然会调度；
3. `NoExecute`：不仅禁止新Pod调度；超过容忍时间之后驱逐节点内现有Pod（节点宕机、硬件故障场景）。

### 5.2 Kubernetes内置系统污点（自动生成）
1. `node.kubernetes.io/unschedulable:NoSchedule`：执行`kubectl cordon`自动添加；
2. `node.kubernetes.io/out‑of‑disk:NoExecute`；
3. `node.kubernetes.io/memory‑pressure:NoExecute`；
4. `node.kubernetes.io/disk‑pressure:NoExecute`；
5. `node.kubernetes.io/pid‑pressure:NoExecute`。
当出现Pressure后打上NoExecute污点，kubelet驱逐Pod。

### 5.3 自定义污点（生产用来隔离节点）
1. 设置污点：
```bash
# 给节点打上污点，只有配置容忍的Pod才能部署
kubectl taint node node‑10‑0‑10‑21 node‑role=db:NoSchedule
```
2. Pod配置Toleration容忍：
```yaml
tolerations:
- key: "node-role"
  operator: "Equal"
  value: "db"
  effect: "NoSchedule"
```
3. 删除污点：
```bash
kubectl taint node node‑10‑0‑10‑21 node‑role=db:NoSchedule --remove
```
4. NoExecute示例：设置5分钟之后驱逐Pod
```yaml
tolerations:
- key: node.kubernetes.io/out-of-disk
  operator: Exists
  effect: NoExecute
  tolerationSeconds: 300
```

### 生产落地场景
1. 数据库节点打上污点，只有StatefulSet数据库Pod可以部署；普通业务Pod不能调度；
2. 退役维护节点：cordon自动添加unschedulable污点；
3. 故障节点：硬件异常打上自定义污点避免业务调度上去。

## 六、第四层：Pod‑Affinity & Pod‑Anti‑Affinity（Pod之间亲和和反亲和）
### 6.1 Pod‑Affinity（Pod亲和：同一区域的Pod尽量部署在一起）
适用场景：缓存和业务Pod部署在同一节点降低网络延迟。
```yaml
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchExpressions:
      - key: app
        operator: In
        values: ["redis"]
    topologyKey: "kubernetes.io/hostname" # 同一主机
```

### 6.2 Pod‑Anti‑Affinity（Pod反亲和：同一个应用副本分散到不同节点，生产必配）
核心目的：避免同一个Deployment副本全部落在同一个节点，节点宕机导致服务全部不可用。
```yaml
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchExpressions:
      - key: app
        operator: In
        values: ["order-api"]
    topologyKey: "kubernetes.io/hostname"
```
- `topologyKey: kubernetes.io/hostname`：以单个节点为拓扑域；
- 也可以使用`rack`标签实现跨机架打散。
> PROD所有Deployment必须配置Pod‑Anti‑Affinity。

## 七、节点污点和标签日常操作命令
```bash
# 查看节点标签
kubectl get node node‑10‑0‑10‑21 --show-labels

# 新增标签
kubectl label node node‑10‑0‑10‑21 rack=rack‑01

# 删除标签
kubectl label node node‑10‑0‑10‑21 rack-

# 添加污点
kubectl taint node node‑10‑0‑10‑21 node‑role=db:NoSchedule

# 删除污点
kubectl taint node node‑10‑0‑10‑21 node‑role=db:NoSchedule --remove

# 查看节点污点
kubectl describe node node‑10‑0‑10‑21 | grep -A 10 Taints
```

## 八、调度失败（Pod Pending）排查步骤（标准流程）
1. 查看Pod事件：`kubectl describe pod xxx -n prod`，查看Predicate预选失败原因；
2. 依次检查下面条件：
    1. 节点CPU、内存资源不足；
    2. Node‑Selector、Node‑Affinity没有匹配节点；
    3. Taint污点不匹配，缺少Toleration；
    4. Pod‑Anti‑Affinity反亲和导致没有可用节点；
    5. 端口冲突（hostPort占用）；
    6. 镜像拉取失败、准入Webhook拒绝；
3. 查看调度器日志：
```bash
kubectl logs -n kube-system deploy/kube-scheduler
```

## 九、DEV / FAT / UAT / PROD差异化标准
1. DEV环境：不用配置Pod‑Anti‑Affinity；污点可以随意添加删除；
2. FAT环境：节点标签体系对齐生产；数据库节点配置污点；反亲和可选；
3. UAT：所有Deployment配置Pod‑Anti‑Affinity；污点策略复用生产；
4. PROD生产环境强制约束：
    1. 节点强制五维标签 `env,node‑role,rack,hardware‑type,os‑version`；
    2. DB节点通过Taint‑Toleration隔离普通业务；
    3. 所有Deployment开启Pod‑Anti‑Affinity，副本分散在不同节点；
    4. 优先使用prefer软约束减少调度失败概率；required硬约束谨慎使用；
    5. 手动添加自定义污点、修改标签需要提交工单双人审批；
    6. 调度器开启监控，记录Predicate失败次数纳入Prometheus告警。

## 十、生产最佳实践总结
1. 标签规划先行：提前规划rack、硬件类型标签，为亲和调度做准备；
2. 分层调度策略：
    - Taint‑Toleration用于节点环境隔离；
    - Node‑Affinity用于选择机房、SSD高性能节点；
    - Pod‑Anti‑Affinity实现副本打散，提升容灾能力；
3. 尽量多用prefer软约束，少用required硬约束，避免大量Pod进入Pending；
4. 禁止手动配置`spec.nodeName`绕过调度器；
5. 查看scheduler日志定期分析调度失败原因，优化调度策略。

## 十一、关联文档
1. `01‑node‑basics.md`：节点标准化标签；
2. `08‑resource‑pressure.md`：压力触发内置污点；
3. `05‑node‑troubleshooting.md`：节点Not‑Ready排障；
4. `02‑workload‑management`：Deployment配置Pod‑Anti‑Affinity；
5. `07‑monitoring‑and‑troubleshooting`：scheduler‑metrics调度成功率指标。