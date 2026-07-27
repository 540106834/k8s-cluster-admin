# configure-application-autoscaling.md
# 应用 HPA 自动弹性伸缩配置与运维手册
## 一、文档定位
本文针对企业K8s业务微服务，标准化配置 **HPA（Horizontal Pod Autoscaler）** 水平Pod弹性伸缩；支持CPU/内存基础指标、自定义业务QPS指标双模式，覆盖**自动扩容、缩容冷却窗口、最小/最大副本约束、定时扩容、故障排查、生产压测适配**；适配DEV/UAT/PROD多环境，配套Java应用部署、监控平台文档，是线上流量波动业务必备治理能力。
前置依赖：
deploy-java-application.md｜业务Deployment正常部署
build-monitoring-platform.md｜Prometheus + Prometheus Adapter 就绪
publish-application-release.md｜业务发布流程
下游关联：scale-down-application.md｜人工临时缩容操作手册

## 二、核心基础原理
### 2.1 HPA 工作机制
1. 控制平面控制器周期性（默认15s）从Prometheus拉取指标
2. 根据目标阈值计算所需副本数：`目标副本 = 当前副本 * 当前指标使用率 / 目标阈值`
3. 触发Deployment扩容/缩容，遵循冷却窗口避免频繁抖动
4. 两种指标体系：
   - 资源指标：容器CPU、内存使用率（原生内置，无需额外组件）
   - 自定义业务指标：HTTP QPS、接口并发量（依赖prometheus-adapter）

### 2.2 关键冷却窗口（生产必配，防抖动）
```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300 # 缩容冷却5分钟，流量回落稳定后再缩容
  scaleUp:
    stabilizationWindowSeconds: 60  # 扩容冷却1分钟，突发流量快速扩容
```
作用：瞬时流量毛刺不会频繁触发扩缩容，避免Pod反复创建销毁引发业务波动。

### 2.3 环境差异化副本边界
| 环境 | minReplicas 最小副本 | maxReplicas 最大副本 | 缩容冷却 |
|------|---------------------|---------------------|----------|
| DEV  | 1                   | 5                   | 60s      |
| UAT  | 2                   | 10                  | 180s     |
| PROD | 3                   | 30（可调整）        | 300s     |

## 三、前置环境校验
1. Prometheus正常采集容器CPU/内存、业务/metrics指标
2. prometheus-adapter已部署，自定义指标可被HPA识别
3. 集群节点资源充足，达到max副本上限仍有CPU/内存缓冲
4. 业务Deployment配置完整resources.requests（HPA计算指标依赖requests）
5. 网络策略允许Prometheus采集Pod监控端口

## 四、方案一：基于CPU/内存资源使用率弹性（通用基础方案）
适用于绝大多数Java微服务，无需额外组件，原生K8s支持。
### 4.1 标准HPA YAML模板（PROD生产）
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
  namespace: prod-business
spec:
  # 绑定目标Deployment
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: app-api
  # 副本上下限
  minReplicas: 3
  maxReplicas: 30
  # 资源阈值：CPU 70%、内存80%触发扩容
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  # 扩缩容防抖冷却配置
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      # 突发流量一次性最多扩容100%
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      # 单次最多缩容50%，避免大量Pod同时销毁
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
```

### 4.2 DEV简化模板
```yaml
spec:
  minReplicas: 1
  maxReplicas: 5
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

### 4.3 部署与校验
```bash
# 创建HPA资源
kubectl apply -f hpa-resource.yaml -n prod-business
# 查看HPA实时指标、当前副本数
kubectl get hpa -n prod-business -w
# 查看HPA事件（扩容/缩容记录）
kubectl describe hpa api-hpa -n prod-business
```

## 五、方案二：基于业务QPS自定义指标弹性（高并发网关/接口服务）
适用于网关、秒杀、高并发API，按每秒请求数自动扩容，依赖prometheus-adapter。
### 5.1 前置要求
业务暴露Prometheus指标：`http_server_requests_seconds_count`
prometheus-adapter配置映射自定义指标为API资源。

### 5.2 QPS HPA模板
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: gateway-hpa
  namespace: prod-business
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: gateway
  minReplicas: 3
  maxReplicas: 30
  metrics:
  # 自定义HTTP QPS指标：单Pod每秒100请求触发扩容
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: 100m # 100m = 100 QPS per pod
  # 同时叠加内存保护
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300
```

## 六、步骤3：HPA全功能验收测试
### 6.1 扩容模拟压测
使用压测工具（ab/hey）持续打流量，观察：
1. HPA指标CPU/使用率持续上涨
2. 达到阈值后自动新增副本，1分钟冷却窗口内逐步扩容
3. QPS分摊至多个Pod，单Pod使用率回落

### 6.2 缩容模拟：停止压测
1. 流量下降后，等待5分钟缩容冷却窗口
2. 逐步减少副本至minReplicas，不会瞬间全部缩容

### 6.3 边界校验
1. 流量峰值持续冲高，副本达到maxReplicas后停止扩容，HPA事件提示上限
2. 流量长期低位，副本稳定维持minReplicas，不会缩容至0

## 七、定时弹性扩展（可选：早晚高峰固定扩容）
针对早晚流量潮汐业务，搭配KEDA定时触发器，非工作时间降低副本节省资源：
1. 早8点自动扩容至10副本
2. 晚22点自动缩容至3副本

## 八、高频故障与排查方案
### 故障1：HPA显示unknown，无法获取CPU/内存指标
根因：cAdvisor采集异常、Prometheus无法抓取kubelet指标、Deployment未配置requests
修复：补充容器resources.requests，检查node-exporter/cAdvisor状态

### 故障2：流量很高，但HPA不扩容
根因：阈值设置过高、maxReplicas达到上限、冷却窗口未结束、自定义指标adapter异常
排查：`kubectl describe hpa` 查看事件提示；核对prometheus-adapter自定义指标

### 故障3：流量下降后长时间不缩容
根因：scaleDown stabilizationWindowSeconds冷却时间设置过长（生产300s为规范）
说明：属于防抖设计，如需快速缩容可调低测试环境窗口

### 故障4：扩缩容频繁抖动，Pod反复创建销毁
根因：冷却窗口stabilizationWindowSeconds设置过小，无防抖
修复：生产缩容窗口固定300s，扩容60s

### 故障5：自定义QPS指标HPA报错：metric not found
根因：prometheus-adapter未配置指标映射、业务未暴露/metrics接口
排查：curl PodIP/metrics确认指标存在，检查adapter配置

## 九、DEV / UAT / PROD 环境标准化规范
1. **DEV开发环境**
   min=1，max=5，缩容冷却60s，仅CPU基础弹性，无自定义QPS指标
2. **UAT测试环境**
   min=2，max=10，冷却180s，可开启QPS指标模拟生产
3. **PROD生产环境**
   min≥3，max根据业务峰值评估；缩容冷却固定300s；同时开启CPU+内存双指标保护；高并发网关叠加QPS自定义弹性

## 十、生产运维落地规范
1. 所有线上流量波动微服务必须配置HPA，杜绝人工频繁扩缩容
2. 生产强制配置长缩容冷却窗口300s，防止流量毛刺引发抖动
3. 资源指标同时配置CPU+内存双重阈值，单一资源耗尽自动扩容
4. 高并发网关、秒杀接口额外配置QPS自定义指标弹性，精准应对流量
5. 设置合理maxReplicas上限，防止突发流量无限扩容耗尽集群资源
6. 监控大盘接入HPA指标：副本数、扩容事件、指标使用率，触发副本超限告警
7. 业务上线验收必做压测弹性验证，纳入validate-project-environment.md
8. 定期调整max/min副本阈值，随业务流量增长迭代更新

## 十一、关联文档索引
deploy-java-application.md Java应用Deployment资源requests配置规范
build-monitoring-platform.md Prometheus、prometheus-adapter部署文档
publish-application-release.md 新版本发布HPA副本自动调度适配
scale-down-application.md 人工临时手动缩容操作手册
validate-project-environment.md HPA弹性能力交付验收标准
06-network-debug.md HPA指标采集失败故障排查流程