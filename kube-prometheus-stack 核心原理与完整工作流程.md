# kube-prometheus-stack 核心原理与完整工作流程

## 核心思想

**通过 Helm 安装 Prometheus Operator，依托 CRD + 自定义资源对象 声明式构建监控体系**。

区别于传统直接编写、维护 Prometheus 配置文件的方式，该方案通过创建一系列 Kubernetes 自定义资源，由 Operator 自动聚合、组装、生成配置，实现监控全生命周期自动化管理。

## 整体工作流程

```Plain Text
Helm install kube-prometheus-stack
              |
              v
创建监控相关 CRD
              |
              v
部署 Prometheus Operator
              |
              v
创建各类监控自定义资源
              |
     +--------+---------+
     |                  |
     v                  v
Prometheus 实例      Alertmanager 实例
     |
     |
动态读取资源：
ServiceMonitor / PodMonitor / PrometheusRule
     |
     v
自动生成 prometheus.yaml 配置
     |
     v
启动指标采集 + 告警检测
```

---

# 一、Helm 安装阶段

通过 Helm 命令一键部署完整监控套件，自动创建所有核心组件资源。

### 安装命令

```Plain Text
helm install monitoring 
prometheus-community/kube-prometheus-stack 
-n monitoring
```

### 查看部署资源

```Plain Text
kubectl get all -n monitoring
```

### 默认部署核心组件

- prometheus-operator：监控控制器核心

- prometheus：指标采集服务实例

- alertmanager：告警管理服务实例

- grafana：可视化监控面板

- node-exporter：节点指标采集器

- kube-state-metrics：K8s 资源状态指标采集器

# 二、安装 CRD（K8s 资源扩展）

Helm 部署第一步会自动安装 Prometheus 监控体系所需的全部 CRD，为后续自定义资源提供资源定义支撑。

### 查看监控类 CRD

```Plain Text
kubectl get crd | grep monitoring
```

### 核心监控 CRD 列表

- `alertmanagerconfigs.monitoring.coreos.com`：Alertmanager 配置自定义资源

- `alertmanagers.monitoring.coreos.com`：Alertmanager 实例自定义资源

- `podmonitors.monitoring.coreos.com`：Pod 指标监控自定义资源

- `prometheuses.monitoring.coreos.com`：Prometheus 实例自定义资源

- `prometheusrules.monitoring.coreos.com`：Prometheus 告警规则自定义资源

- `servicemonitors.monitoring.coreos.com`：Service 指标监控自定义资源

### 原生资源 vs 监控扩展资源

**原生 K8s 资源**：Pod、Service、Deployment

**Operator 扩展监控资源**：Prometheus、ServiceMonitor、PodMonitor、PrometheusRule、Alertmanager

# 三、Prometheus Operator 核心控制器

部署资源：`Deployment/prometheus-operator`

核心作用：类似 K8s 原生控制器，持续监听监控类自定义资源的变化，自动生成、更新 Prometheus 配置和告警规则。

### 监听资源对象

- Prometheus（实例配置）

- ServiceMonitor（服务监控规则）

- PodMonitor（Pod 监控规则）

- PrometheusRule（告警规则）

- Alertmanager（告警实例配置）

### 控制器类比

```Plain Text
原生 Deployment Controller
        |
        监听 Deployment 变化 → 自动创建/管理 Pod

Prometheus Operator
        |
        监听监控 CR 变化 → 自动生成/更新 Prometheus 配置
```

# 四、Prometheus 自定义资源（CR）

安装完成后会自动创建 Prometheus 类型 CR，用于定义 Prometheus 服务实例的全局配置，**并非原生 Deployment 资源**。

### 查看 Prometheus CR

```Plain Text
kubectl get prometheus -n monitoring
```

### 核心 YAML 示例

```Plain Text
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
spec:
  replicas: 2                  # Prometheus 副本数
  serviceMonitorSelector:     # 筛选生效的 ServiceMonitor
    matchLabels:
      release: monitoring
  # 可配置存储、资源限制、持久化、外部标签等

```

### 核心配置作用

- 定义 Prometheus 实例副本数量

- 配置数据存储、资源配额、持久化策略

- 通过标签筛选，绑定需要生效的 ServiceMonitor/PodMonitor

# 五、ServiceMonitor 服务监控规则

kube-prometheus-stack 默认预置大量 ServiceMonitor 资源，用于定义需要监控的 K8s 服务，告知 Prometheus 采集目标。

### 查看所有 ServiceMonitor

```Plain Text
kubectl get servicemonitor -n monitoring
```

### 默认核心监控对象

- kubelet 监控

- apiserver 监控

- coredns 监控

- kube-state-metrics 监控等

### ServiceMonitor 工作链路

```Plain Text
创建 ServiceMonitor 资源
        |
        匹配目标 Service
        |
        解析 Service 关联的 Endpoints
        |
        自动访问节点/容器 /metrics 接口采集指标
```

# 六、ServiceMonitor 生效原理（核心）

Prometheus 实例不会加载所有 ServiceMonitor，依靠**标签选择器精准绑定**，实现监控规则按需生效。

### 关键匹配逻辑

Prometheus CR 中定义筛选规则：

```Plain Text
spec:
  serviceMonitorSelector:
    matchLabels:
      release: monitoring
```

只有携带对应标签的 ServiceMonitor 才会被加载：

```Plain Text
metadata:
  labels:
    release: monitoring
```

### 完整生效链路

```Plain Text
带匹配标签的 ServiceMonitor
        |
Prometheus 筛选匹配资源
        |
Operator 动态生成 scrape 采集配置
        |
Prometheus 自动加载配置并开始采集
```

# 七、PrometheusRule 告警规则

用于自定义、存储 Prometheus 告警规则，实现指标阈值监控与告警触发。

### 查看所有 PrometheusRule

```Plain Text
kubectl get prometheusrule -n monitoring
```

### 告警规则 YAML 示例

```Plain Text
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
spec:
  groups:
  - name: node.rules
    rules:
    - alert: NodeCPUHigh        # 告警名称
      expr: cpu_usage > 90     # 告警阈值表达式
      for: 5m                  # 持续5分钟触发
      labels:
        severity: critical

```

示例含义：节点 CPU 使用率超过 90%，且持续 5 分钟，触发严重级别告警。

# 八、PrometheusRule 完整工作流程

```Plain Text
编写/创建 PrometheusRule 资源
        |
Prometheus Operator 监听规则变化
        |
自动生成 rules.yaml 告警配置文件
        |
Prometheus 动态加载告警规则
        |
持续计算指标、匹配告警阈值
        |
产生告警事件 → 推送至 Alertmanager
```

# 九、Alertmanager 告警管理组件

通过 Alertmanager 自定义资源部署，统一处理 Prometheus 产生的所有告警事件。

### 查看 Alertmanager 资源

```Plain Text
kubectl get alertmanager -n monitoring
```

### 核心功能

- 告警分组、去重、抑制

- 告警静默、延时发送

- 多渠道通知（钉钉、企业微信、邮件、短信等）

# 十、Grafana 可视化面板

以 Deployment 形式部署，依托 Sidecar 组件自动加载 ConfigMap 中预置的监控大盘。

### 工作链路

```Plain Text
预置 Grafana Dashboard ConfigMap
        |
Grafana Sidecar 监听配置变更
        |
自动加载、更新监控大盘
        |
用户可视化查看监控指标
```

# 十一、完整资源关系总流程图

```Plain Text
Helm
                  |
                  v
          kube-prometheus-stack
                  |
        +---------+----------+
        |                    |
        v                    v
     安装CRD           部署Operator Deployment
        |
        |
        +----------------+
        |                |
        v                v
 Prometheus CR       Alertmanager CR
        |
        |
        v
Prometheus Operator（核心调度）
        |
        |
读取三类核心资源
+----------------+
| ServiceMonitor |
| PodMonitor     |
| PrometheusRule |
+----------------+
        |
        |
自动生成配置
prometheus.yaml + rules.yaml
        |
        v
Prometheus Server 执行采集与规则校验
        |
        |
推送告警事件
        |
        v
Alertmanager 处理告警并发送通知

```

---

# 面试高频重点总结

### 面试题：kube-prometheus-stack 安装后，ServiceMonitor 和 PrometheusRule 是怎么生效的？

**标准答案：**

kube-prometheus-stack 通过 Helm 一键部署 Prometheus Operator 及全套监控 CRD 资源，部署过程中会自动创建 Prometheus、Alertmanager 实例资源，以及默认的 ServiceMonitor、PodMonitor、PrometheusRule 监控规则资源。

核心生效逻辑为：Prometheus Operator 持续监听监控类自定义资源的变更，根据 Prometheus CR 中定义的标签选择器，精准匹配并加载对应 ServiceMonitor 和 PrometheusRule，动态生成 Prometheus 采集配置与告警规则配置，无需手动修改配置文件，最终让 Prometheus 自动加载新配置，实现监控目标发现、指标采集和告警规则的**声明式、自动化管理**。

该知识点为 CKA、SRE、Kubernetes 运维岗位**高频面试考点**，核心考察 K8s 声明式监控、Operator 工作机制、CRD 资源联动逻辑。

> （注：部分内容可能由 AI 生成）
