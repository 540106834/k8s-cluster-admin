# 03-worker-node-management/07-scheduling-control.md
## 节点调度全量控制：标签、污点、亲和与驱逐约束
### 一、调度核心对象总览
调度控制依托 Node 与 Pod 两端元数据实现流量分发隔离，四大核心机制：Label 节点分组、Taint/Toleration 排斥调度、NodeAffinity 定向调度、PodAffinity/AntiAffinity 业务同/反亲和。
1. Label：节点分组标识，用于批量筛选、环境/机房/机型分区
2. Taint：节点排斥规则，不具备容忍的 Pod 禁止调度
3. NodeSelector：简易定向调度，仅匹配固定标签节点
4. NodeAffinity：高级节点亲和，支持多条件权重、软硬策略
5. PodAffinity：同业务Pod聚集部署
6. PodAntiAffinity：副本打散、高可用隔离

### 二、Label 节点标签管理
#### 2.1 标签标准规范
统一标签体系，生产固定前缀：
- `env: prod/test/dev` 环境区分
- `machine: highcpu/highmem/gpu` 机型资源分类
- `region: sh/bj/gz` 机房地域
- `node-type: business/log/db` 业务用途
- `arch: amd64/arm64` CPU架构

#### 2.2 标签运维命令
```bash
# 给节点打标签
kubectl label node node-01 env=prod --overwrite
# 删除标签
kubectl label node node-01 env-
# 批量查看所有节点标签
kubectl get nodes --show-labels
# 筛选匹配标签节点
kubectl get nodes -l env=prod
```

#### 2.3 Pod 使用 NodeSelector 绑定节点
```yaml
spec:
  nodeSelector:
    env: prod
    machine: highmem
```
缺点：仅精确匹配，无备选策略，匹配节点不足会调度失败。

### 三、Taint & Toleration 污点容忍（节点隔离核心）
#### 3.1 污点三要素
`key=value:effect`
- effect 三种策略：
  1. NoSchedule：新Pod禁止调度，已存在Pod不受影响（日常维护首选）
  2. PreferNoSchedule：尽量不调度，无匹配节点时允许妥协调度
  3. NoExecute：不仅拒绝新Pod，立刻驱逐当前无容忍Pod（故障隔离专用）

#### 3.2 节点污点操作
```bash
# 添加污点，禁止无容忍Pod调度
kubectl taint node node-01 node-type=db:NoSchedule
# 删除污点
kubectl taint node node-01 node-type=db:NoSchedule-
# 查看节点污点
kubectl describe node node-01 | grep Taints
```

#### 3.3 Pod 容忍配置示例
```yaml
tolerations:
- key: "node-type"
  operator: "Equal"
  value: "db"
  effect: "NoSchedule"
# 匹配任意key污点
- key: "node.kubernetes.io/unreachable"
  operator: "Exists"
  tolerationSeconds: 300
```
tolerationSeconds：节点失联后延迟驱逐时长，适配故障缓冲。

#### 3.4 生产典型污点场景
1. 数据库节点：`node-type=db:NoSchedule`，仅DB应用容忍
2. GPU节点：`hardware=gpu:NoSchedule`
3. 故障隔离节点：`fault=true:NoExecute`，自动驱逐普通业务
4. 维护中节点：drain 自动添加 `node.kubernetes.io/unschedulable:NoSchedule`

### 四、NodeAffinity 高级节点亲和
区分 `requiredDuringSchedulingIgnoredDuringExecution` 硬策略（必须满足，否则无法调度）、`preferredDuringSchedulingIgnoredDuringExecution` 软策略（优先匹配，无满足节点则降级）。
#### 4.1 硬亲和示例
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: env
            operator: In
            values: ["prod"]
```
#### 4.2 软亲和权重调度
```yaml
preferredDuringSchedulingIgnoredDuringExecution:
- weight: 80
  preference:
    matchExpressions:
    - key: machine
      operator: In
      values: ["highmem"]
```
weight 取值1-100，调度器优先选择高分节点。

### 五、Pod 亲和与反亲和（业务高可用）
#### 5.1 PodAffinity：同业务聚集
同一应用多Pod尽量部署在同一节点/机房，降低网络延迟。
#### 5.2 PodAntiAffinity：副本打散（高可用必备）
强制同应用副本分散至不同节点，避免单机故障全量宕机：
```yaml
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        app: order-service
    topologyKey: "kubernetes.io/hostname"
```
topologyKey：打散维度，hostname按节点、region按机房。

### 六、调度优先级实战场景
1. 数据库专属节点：Taint隔离 + NodeAffinity定向调度
2. 多机房异地部署：region标签 + PodAntiAffinity跨机房打散
3. GPU任务调度：machine=gpu标签 + 污点限制普通Pod
4. 业务维护隔离：cordon自动添加unschedulable污点
5. 节点故障缓冲：配置unreachable污点容忍时长

### 七、调度排错标准化流程
1. 查看Pod调度失败事件：`kubectl describe pod xxx | grep Events`
2. 核对节点Label、Taint：`kubectl describe node $NODE`
3. 校验Pod亲和/容忍YAML语法
4. 检查集群剩余匹配节点资源是否充足
5. 调整软硬亲和权重、补充节点容忍规则

### 八、关联文档跳转
- 节点基础标签查看：01-node-basics.md
- 节点排空维护污点：03-node-drain.md
- 节点资源压力驱逐：08-resource-pressure.md
- 节点故障隔离处理：05-node-troubleshooting.md