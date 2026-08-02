# docs/05-prometheus-operator/03-prometheusrule.md
# PrometheusRule 预计算与告警规则标准化规范手册
## 文档基础信息
- K8s 集群：v1.32
- Chart基线：kube-prometheus-stack-65.1.0
- 管控模式：GitOps + Helm + Prometheus Operator CRD
- 文档等级：★★★★★ 监控告警核心规范
- 前置阅读：04-workload/01-prometheus.md、04-workload/02-alertmanager.md
## 目录
1. PrometheusRule 工作原理与两类规则
2. Prometheus 全局规则筛选匹配配置
3. 标准完整 PrometheusRule YAML 模板
4. Record 预聚合规则编写规范
5. Alert 告警规则标准化规范（阈值、持续时间、标签注解）
6. 告警路由分组、抑制、静默配套约束
7. 多环境差异化规则控制
8. 规则调试、校验、热更新流程
9. 最佳实践与禁止反模式
10. 关联文档索引

---

# 1. PrometheusRule 工作原理与两类规则
## 1.1 数据流
```
Prometheus Operator 监听集群 PrometheusRule CRD
    ↓ 根据 prometheusRuleSelector 筛选合规规则资源
        ↓ 自动生成 rules 配置注入Prometheus实例
            ↓ 按 evaluationInterval 周期循环执行
                ├─ Record规则：预计算指标存入TSDB
                └─ Alert规则：条件成立生成告警推送Alertmanager
```
## 1.2 两种规则区分
### Record 预聚合规则
1. 作用：提前聚合高基数指标，减少Grafana查询计算压力、降低查询耗时；
2. 适用：QPS聚合、资源均值/峰值、多维度求和；
3. 生命周期：数据随TSDB留存策略自动清理。

### Alert 告警规则
1. 作用：指标异常触发告警，推送至Alertmanager做分发、抑制、降噪；
2. 组成：expr阈值表达式、for持续时长、labels路由标签、annotations描述信息；
3. 状态流转：Inactive → Pending（等待for时长）→ Firing（触发告警）→ Resolved（恢复）。

## 1.3 核心优势
1. CRD声明式管理，无需手动修改Prometheus配置；
2. 规则热加载，helm upgrade无停机生效；
3. 统一标签体系，与Alertmanager路由完美联动；
4. 按业务/集群分层存放，Git版本管控可追溯。

# 2. Prometheus 全局规则筛选匹配配置（values固化）
```yaml
prometheus:
  prometheusSpec:
    # 仅加载带平台标签的PrometheusRule
    prometheusRuleSelector:
      matchLabels:
        platform: monitor
    # 仅读取开启监控的命名空间规则
    prometheusRuleNamespaceSelector:
      matchLabels:
        monitor-enabled: "true"
    # 全局排除系统命名空间
    prometheusRuleNamespaceSelectorMatchExpressions:
      - key: kubernetes.io/metadata.name
        operator: NotIn
        values: [kube-system, kube-public]
    # 规则评估周期，全局统一1分钟
    evaluationInterval: "1m"
```
约束：Namespace必须打标`monitor-enabled: "true"`，规则CR必须携带`platform: monitor`标签，否则规则不会加载。

# 3. 标准完整 PrometheusRule YAML 模板
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: business-api-rule
  namespace: business
  labels:
    platform: monitor # 强制匹配prometheusRuleSelector
    app: business-api
spec:
  groups:
    - name: business-api.record.rules # 分组：预聚合规则
      interval: 1m
      rules:
        - record: business_api:qps:sum
          expr: sum(rate(http_server_requests_seconds_count[5m])) by (service_name, env)
          labels:
            metric_type: aggregate

    - name: business-api.alert.rules # 分组：业务告警规则
      interval: 1m
      rules:
        - alert: BusinessApiHighErrorRate
          expr: sum(rate(http_server_requests_seconds_count{status!~"2.."}[5m])) / sum(rate(http_server_requests_seconds_count[5m])) > 0.05
          for: 5m
          labels:
            severity: critical
            alert_group: business-api
            env: prod
          annotations:
            summary: "业务API错误率超过5%"
            description: "服务 {{service_name}} 错误率：{{ $value | humanizePercentage }}，持续5分钟"
            runbook_url: "https://wiki.internal/monitor/alert/api-error"
```
## 强制字段约束
1. metadata.labels 必须包含`platform: monitor`；
2. spec.groups分层拆分record/alert，禁止混合；
3. alert规则必须配置`for`持续时间，避免瞬时抖动告警；
4. 告警统一携带`severity/alert_group/env`三类路由标签；
5. annotations必须包含summary、description、故障处理文档链接。

# 4. Record 预聚合规则编写规范
## 4.1 指标命名规范（统一格式）
`业务/组件:指标名:聚合维度`
示例：
- node:cpu_util:avg
- business_api:qps:sum
- mysql:connections:max

## 4.2 标准使用模板
```yaml
rules:
  - record: node:cpu_util:avg
    expr: avg(100 - (avg by (node) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100))
    labels:
      metric_type: aggregate
```
## 4.3 最佳约束
1. 聚合窗口统一5m，平衡实时性与平滑度；
2. 仅保留业务/排查必需维度，减少基数；
3. 所有record规则统一打`metric_type: aggregate`标签，便于过滤查询；
4. 高频查询大盘对应的指标必须预聚合，禁止Grafana实时大区间计算原始指标。

## 4.4 禁用反模式
1. record规则无聚合，完全复制原始指标；
2. 单条规则携带10个以上标签维度，造成TSDB基数爆炸；
3. 聚合窗口混用1m/10m，规则不统一。

# 5. Alert 告警规则标准化规范
## 5.1 severity 分级标准（全局统一三级）
- critical：核心业务中断、集群故障、服务不可用，即时电话/钉钉紧急群；
- warning：资源水位偏高、轻微异常，钉钉业务群；
- info：日志少量报错、临时波动，仅归档不推送。

## 5.2 for 持续时长规范（杜绝抖动告警）
- 资源水位类（CPU/内存/磁盘）：5m
- 业务错误率、延迟类：3m~5m
- Pod失联、服务Down：2m
- 瞬时指标、脉冲流量：10m

## 5.3 expr表达式编写约束
1. 统一使用rate/irate计算增量，避免计数器突跳；
2. 分母必须做判0保护，防止`NaN`告警；
   ```promql
   # 错误写法：分母可能为0
   sum(rate(error_count[5m])) / sum(rate(request_count[5m]))
   # 正确写法：分母+极小值兜底
   sum(rate(error_count[5m])) / (sum(rate(request_count[5m])) + 0.0001)
   ```
3. 阈值预留缓冲，不设置临界值100%；磁盘使用率预警80%，严重90%。

## 5.4 标签与注解强制规范
### 固定labels（用于Alertmanager路由分组）
```yaml
labels:
  severity: critical/warning/info
  alert_group: 业务/组件分组名
  env: prod/uat/dev
```
### 固定annotations（用于告警展示、排查）
```yaml
annotations:
  summary: 一句话精简告警标题
  description: 详细故障信息，插值展示指标值、实例
  runbook_url: 故障处理wiki链接
  dashboard_url: 对应Grafana大盘地址
```

# 6. 告警路由分组、抑制、静默配套约束
1. alert_group标签与Alertmanager路由分组一一对应，同一业务告警合并推送；
2. 节点整机故障时，抑制该节点下所有Pod资源告警，规则中统一携带`node_name`标签用于抑制匹配；
3. 变更窗口、维护期使用Alertmanager静态静默，不修改PrometheusRule阈值。

# 7. 多环境差异化规则控制
## 7.1 Dev/UAT环境降低告警敏感度
```yaml
- alert: BusinessApiHighErrorRate
  expr: xxx > 0.1 # 测试环境阈值放宽至10%
  for: 10m # 延长等待时间
  labels:
    severity: warning # 不触发紧急通知
```
## 7.2 开发环境关闭部分高危告警
通过relabel过滤dev命名空间告警，在Prometheus顶层配置：
```yaml
prometheus:
  prometheusSpec:
    ruleRelabelConfigs:
      - sourceLabels: [env]
        regex: dev
        action: drop
```

# 8. 规则调试、校验、热更新流程
## 8.1 语法校验（部署前本地校验）
```bash
# 本地校验promql语法
promtool check rules rules.yaml
```
## 8.2 下发更新规则
```bash
helm upgrade kube-monitor /opt/charts/kube-prometheus-stack -n monitoring -f values-prod.yaml
```
Operator自动热加载规则，无需重启Prometheus。

## 8.3 Prometheus UI校验规则状态
访问 UI → Status → Rules：
1. OK：规则加载正常；
2. Err：PromQL语法错误，展示报错详情；
3. 可查看每条规则最新计算值、告警状态。

## 8.4 实时告警调试
UI → Alerts：查看Pending/Firing/Inactive告警；
过滤标签`alert_group=business-api`定位业务告警。

## 8.5 日志排查规则执行异常
```bash
kubectl logs -f sts/kube-monitor-prometheus-0 -n monitoring | grep rule
```

# 9. 最佳实践与禁止反模式
## 9.1 强制最佳实践
1. 按业务/组件拆分独立PrometheusRule资源，禁止单CR存放上百条规则；
2. Record与Alert规则分组隔离，命名清晰；
3. 告警统一三级severity、标准化标签与注解；
4. 所有rate增量计算使用5m窗口，分母判0防NaN；
5. 全部告警配置合理`for`时长，消除瞬时抖动；
6. 每条告警配套故障处理文档runbook_url。

## 9.2 严格禁止反模式
1. PrometheusRule缺失`platform: monitor`标签，规则无法加载；
2. 告警不配置for，瞬时波动大量垃圾告警；
3. PromQL分母无兜底，产生NaN无效告警；
4. 单条规则匹配上万时序，造成Prometheus CPU飙升；
5. 混合Record与Alert在同一个group下，难以维护；
6. 硬编码区分集群环境，不使用标签做环境路由。

# 10. 关联文档索引
1. Prometheus 核心全局配置：04-workload/01-prometheus.md
2. Alertmanager告警分发、抑制、路由：04-workload/02-alertmanager.md
3. ServiceMonitor/PodMonitor采集规范：05-prometheus-operator/01-servicemonitor.md、05-prometheus-operator/02-podmonitor.md
4. 监控故障排查手册：09-troubleshooting/02-prometheus-error.md
5. 企业告警渠道配置规范：10-best-practice/alert-channel.md