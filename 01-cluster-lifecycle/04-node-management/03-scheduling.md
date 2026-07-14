# 01‑cluster‑lifecycle/04‑node‑management/scheduling.md
## 一、文档基础信息
- 文件路径：`01‑cluster‑lifecycle/04‑node‑management/scheduling.md`
- 前置文档：`node‑lifecycle.md`、`maintenance.md`
- 集群版本：Kubernetes‑1.32.13，kube‑scheduler调度器；预选(Predicate)、优选(Priority)两大阶段；支持NodeSelector、Node‑Affinity、Taint‑Toleration、Pod‑Affinity/Anti‑Affinity、TopologySpreadConstraints。
- 文档目标：分层讲解调度策略、语法示例、优先级关系、落地场景、排障方法、生产配置规范。
- 优先级从高到低：`spec.nodeName > Taint‑Toleration > NodeSelector > Node‑Affinity > Pod‑Affinity/Anti‑Affinity > TopologySpreadConstraints`。

## 二、kube‑scheduler整体调度流程
### 2.1 两个阶段
1. **Predicate（预选，硬性过滤）**
    剔除不满足条件的节点：资源不足、污点不匹配、亲和规则不满足、端口占用、nodeName硬绑定；不达标节点直接淘汰。
2. **Priority（优选打分，软性选择）**
    对剩余可用节点进行0‑100打分，得分最高节点绑定Pod。
    默认内置打分策略：
    - `LeastRequestedPriority`：优先选择剩余资源更多节点（默认核心策略）；
    - `NodeAffinityPriority`：节点亲和权重；
    - `ImageLocalityPriority`：优先选择本地已有镜像的节点。

### 2.2 最终绑定
调度器填写`pod.spec.nodeName`；随后对应节点kubelet发现Pod并拉起容器。
> 只要预选阶段没有符合条件节点，Pod状态进入Pending状态。

## 三、第一层：NodeSelector（简单等值匹配）
### 3.1 节点提前打标签
```bash
kubectl label node node-10-0-10-21 rack=rack-01 hardware=ssd env=prod
```
### 3.2 Pod配置
```yaml
spec:
  nodeSelector:
    rack: rack-01
    hardware: ssd
```
特点：
- 仅支持严格相等匹配；只支持`=`，不支持`In、NotIn、Gt、Lt`；
- 缺点：只有匹配或者不匹配，没有偏好选项，灵活性不足；
- 适用场景：简单业务划分，生产环境优先使用Node‑Affinity。

## 四、第二层：Node‑Affinity（节点亲和，生产首选）
分为`requiredDuringSchedulingIgnoredDuringExecution（硬约束）`和`preferredDuringSchedulingIgnoredDuringExecution（软偏好）`。
### 4.1 required（硬约束）
条件不满足，Pod直接Pending。
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
operator取值：`In、NotIn、Exists、DoesNotExist、Gt、Lt`。

### 4.2 preferred（软偏好）
weight取值范围1‑100，权重越高优先级越高；没有符合条件节点依旧可以调度至其他节点。
```yaml
preferredDuringSchedulingIgnoredDuringExecution:
- weight: 80
  preference:
    matchExpressions:
    - key: hardware
      operator: In
      values: ["ssd"]
```

### 生产建议
1. 核心中间件使用`required`；普通业务采用`preferred`；
2. 尽量多用软约束，减少硬约束，避免大批量Pod进入Pending。

## 五、第三层：Taint‑Toleration（污点‑容忍，节点隔离核心机制）
### 5.1 Taint三种生效策略
1. `NoSchedule`：没有对应容忍的Pod禁止调度到此节点（最常用）；
2. `PreferNoSchedule`：尽量不调度，实在没有可用节点仍然会调度；
3. `NoExecute`：禁止新Pod调度；超过容忍时长后驱逐节点内现存Pod。

#### 5.2 系统内置污点（kubelet自动生成）
```
node.kubernetes.io/unschedulable:NoSchedule       # kubectl cordon自动添加
node.kubernetes.io/disk-pressure:NoExecute
node.kubernetes.io/memory-pressure:NoExecute
node.kubernetes.io/pid-pressure:NoExecute
```
当节点触发Pressure后打上`NoExecute`污点，kubelet开始驱逐Pod。

#### 5.3 自定义污点（隔离数据库节点）
1. 设置污点
```bash
kubectl taint node node-10-0-10-21 node-role=db:NoSchedule
```
2. Pod配置容忍
```yaml
tolerations:
- key: node-role
  operator: Equal
  value: db
  effect: NoSchedule
```
3. 删除污点
```bash
kubectl taint node node-10-0-10-21 node-role=db:NoSchedule --remove
```
#### 生产落地场景
- DB节点打上污点，只有StatefulSet数据库Pod配置容忍；普通业务Pod禁止部署到DB节点；
- 硬件故障节点打上污点，避免业务调度上来。

## 六、第四层：Pod‑Affinity & Pod‑Anti‑Affinity（Pod之间亲和反亲和）
### 6.1 Pod‑Affinity（Pod亲和）
把相关Pod部署在一起，减少网络延迟，例如redis和业务应用部署在同一个节点。
```yaml
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchExpressions:
      - key: app
        operator: In
        values: ["redis"]
    topologyKey: "kubernetes.io/hostname"
```

### 6.2 Pod‑Anti‑Affinity（Pod反亲和，生产必配）
避免同一个应用多个副本落在同一节点，防止单节点宕机导致服务整体不可用。
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
- `topologyKey: kubernetes.io/hostname`：以单个节点作为拓扑域；
- 如果设置`rack`标签，就可以实现跨机架打散副本。
> PROD环境所有Deployment必须配置Pod‑Anti‑Affinity。

## 七、第五层：TopologySpreadConstraints（拓扑域打散，k8s1.19+推荐）
相比Pod‑Anti‑Affinity更加灵活，可以基于节点、机柜、机房均衡分布副本。
```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: rack
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels:
      app: order-api
```
- `maxSkew:1`：各个rack之间副本数量相差不能超过1；
- `whenUnsatisfiable`：
  - ScheduleAnyway：实在无法均衡依旧调度；
  - DoNotSchedule：达不到均衡则Pod Pending。
生产推荐搭配rack标签实现多机柜高可用。

## 八、标签与污点日常操作命令
```bash
# 查看节点标签
kubectl get node node-10-0-10-21 --show-labels
# 添加标签
kubectl label node node-10-0-10-21 rack=rack-01
# 删除标签
kubectl label node node-10-0-10-21 rack-

# 添加污点
kubectl taint node node-10-0-10-21 node-role=db:NoSchedule
# 删除污点
kubectl taint node node-10-0-10-21 node-role=db:NoSchedule --remove
# 查看节点污点
kubectl describe node node-10-0-10-21 | grep -A 10 Taints
```

## 九、Pod Pending（调度失败）排查标准步骤
1. 查看Pod事件：`kubectl describe pod xxx -n prod`查看Predicate失败原因；
2. 逐项检查：
    1. 节点CPU内存资源不足；
    2. Node‑Selector、Node‑Affinity没有匹配节点；
    3. Taint污点没有配置对应Toleration；
    4. Pod‑Anti‑Affinity反亲和导致没有可用节点；
    5. hostPort端口冲突；
    6. 镜像拉取失败、准入Webhook拒绝（不属于调度器问题）；
3. 查看调度器日志：
```bash
kubectl logs -n kube-system deploy/kube-scheduler
```

## 十、DEV/FAT/UAT/PROD差异化标准
1. DEV：不需要配置Pod‑Anti‑Affinity；污点可以随意添加删除；
2. FAT：节点标签体系对齐生产；数据库节点配置污点隔离；反亲和可选；
3. UAT：所有Deployment开启Pod‑Anti‑Affinity；优先使用prefer软约束；
4. PROD生产强制约束：
    1. 节点强制配置五维标签：`env、node‑role、rack、hardware‑type、os‑version`；
    2. DB节点依靠Taint‑Toleration隔离普通业务；
    3. 所有Deployment配置Pod‑Anti‑Affinity或者TopologySpreadConstraints；
    4. 优先使用prefer软约束，谨慎使用required硬约束，避免大批量Pod Pending；
    5. 手动添加污点、修改节点标签必须提交工单双人审批；
    6. 监控scheduler指标，Predicate失败次数接入Prometheus告警。

## 十一、生产最佳实践总结
1. 分层规划：
    - Taint‑Toleration：划分节点用途（业务节点、DB节点）；
    - Node‑Affinity：选择机房、SSD高性能节点；
    - Pod‑Anti‑Affinity/TopologySpread：实现副本打散，提升容灾；
2. 少用`spec.nodeName`硬绑定，会绕过调度器，失去高可用；
3. 尽量多用prefer软约束，减少required硬约束；
4. 利用rack标签实现跨机柜副本分散，进一步提高容灾能力；
5. 定期分析scheduler日志，优化调度策略，降低Pending概率。

## 十二、关联文档
1. `node‑lifecycle.md`：节点生命周期；
2. `maintenance.md`：cordon自动添加unschedulable污点；
3. `troubleshooting.md`：节点Not‑Ready、Pod Pending排障；
4. `authorization.md`：RBAC权限管控；
5. `08‑resource‑pressure.md`：Pressure触发内置污点。