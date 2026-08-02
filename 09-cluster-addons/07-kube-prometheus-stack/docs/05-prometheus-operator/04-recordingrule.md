# docs/05-prometheus-operator/04-recordingrule.md
# RecordingRule 预聚合指标专项规范手册
## 文档基础信息
- K8s 集群：v1.32
- Chart基线：kube-prometheus-stack-65.1.0
- 管控模式：GitOps + PrometheusOperator CRD（PrometheusRule内置Record分组）
- 文档等级：★★★★☆ 性能优化专项规范
- 前置阅读：05-prometheus-operator/03-prometheusrule.md
## 目录
1. RecordingRule 核心定位与价值
2. 原始指标查询痛点 vs 预聚合优势
3. 全局标准化命名规范
4. 标准完整 Record 规则模板（分层聚合）
5. 常用聚合场景标准 PromQL 模板
6. 窗口、周期、标签基数管控规范
7. 多环境差异化聚合策略
8. 调试验证、查询校验流程
9. 性能风险与禁用反模式
10. 落地最佳实践清单
11. 关联文档索引

---

# 1. RecordingRule 核心定位与价值
## 1.1 定义
Recording Rule（预聚合规则）是 PrometheusRule CRD 中 `record` 类型规则，在 Prometheus 后台按固定周期提前计算复杂 PromQL，将结果持久化为全新时序指标存入TSDB，替代Grafana前端实时计算。

## 1.2 核心价值
1. **降低查询负载**：大盘、看板、告警不再实时聚合海量原始时序，削减Prometheus CPU/内存开销；
2. **大区间查询提速**：原始指标保留周期短（7d），预聚合指标可长期留存（30d+），支撑周/月维度大盘；
3. **规避基数爆炸**：提前聚合去除无用低价值标签，减少时序总量；
4. **统一指标口径**：全平台QPS、错误率、资源使用率使用同一套预聚合指标，无计算逻辑差异。

## 1.3 执行逻辑
1. 随全局 `evaluationInterval:1m` 定时执行；
2. 计算完成生成新 `record:xxx` 时序写入存储；
3. Record指标可像普通指标一样用于Grafana绘图、Alert告警表达式。

# 2. 原始指标查询痛点 vs 预聚合优势
| 场景 | 无预聚合（直接查原始指标） | 使用RecordingRule预聚合 |
|------|----------------------------|-------------------------|
| 业务大盘刷新 | 每次前端聚合上万Pod时序，查询超时、面板转圈 | 直接读取预计算单维度指标，毫秒返回 |
| 7天以上趋势图 | 原始数据量大，查询OOM、耗时数十秒 | 低基数聚合时序，长区间无压力 |
| 多条告警复用同一计算 | 每条告警重复执行相同rate/sum逻辑 | 计算一次，所有告警共享结果 |
| 多团队口径不一致 | 各开发自行写PromQL，阈值、窗口不统一 | 全局统一预聚合指标，口径标准化 |

# 3. 全局标准化命名规范
统一格式：`层级:指标名称:聚合粒度`
## 层级分类
1. **node**：宿主机/节点资源指标
2. **container**：容器基础资源
3. **service**：业务服务流量、延迟、错误
4. **mysql/redis/kafka**：中间件专属
5. **cluster**：集群全局汇总指标

## 粒度后缀规范
- `sum`：求和（QPS、连接数、请求总量）
- `avg`：平均值（CPU使用率、延迟）
- `max`：峰值（内存峰值、最大连接）
- `p95/p99`：百分位延迟
- `count`：实例总数、错误次数

## 标准命名示例
```
node:cpu_util:avg
service:http_qps:sum
service:http_error_rate:ratio
mysql:connections:max
cluster:pod_running:count
```

## 强制标签规范
所有预聚合指标统一附加固定标签，便于筛选区分：
```yaml
labels:
  metric_type: recording
  aggregate_window: "5m"
```

# 4. 标准完整 Record 规则模板
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: business-service-recording
  namespace: business
  labels:
    platform: monitor
spec:
  groups:
    # 独立分组：仅存放Recording规则，禁止与Alert混合
    - name: business.service.recording.rules
      interval: 1m
      rules:
        # 1. 业务全量QPS 5分钟求和
        - record: service:http_qps:sum
          expr: sum(rate(http_server_requests_seconds_count[5m])) by (service_name, env, namespace)
          labels:
            metric_type: recording
            aggregate_window: "5m"

        # 2. 业务错误率（分母防除0）
        - record: service:http_error_rate:ratio
          expr: sum(rate(http_server_requests_seconds_count{status!~"2.."}[5m])) / (sum(rate(http_server_requests_seconds_count[5m])) + 0.0001)
          labels:
            metric_type: recording
            aggregate_window: "5m"

        # 3. P95请求延迟
        - record: service:http_latency:p95
          expr: histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket[5m])) by (le, service_name, env))
          labels:
            metric_type: recording
            aggregate_window: "5m"
```

## 模板强制约束
1. 单独Group存放Record规则，与Alert告警分组物理隔离；
2. rate/histogram_quantile统一使用 `[5m]` 滑动窗口；
3. 比率类指标分母增加极小值兜底，避免NaN；
4. 每条规则必须附加 `metric_type/aggregate_window` 标签；
5. by子句仅保留业务必需维度，删减Pod/Container等高基数标签。

# 5. 常用聚合场景标准 PromQL 模板
## 5.1 流量QPS求和
```yaml
- record: service:http_qps:sum
  expr: sum(rate(http_server_requests_seconds_count[5m])) by (service_name, env)
```
## 5.2 CPU使用率均值（节点维度）
```yaml
- record: node:cpu_util:avg
  expr: avg(100 - avg by (node)(irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) by (node, env)
```
## 5.3 磁盘使用率峰值
```yaml
- record: node:disk_used_percent:max
  expr: max(100 - (node_filesystem_avail_bytes / node_filesystem_size_bytes * 100)) by (node, mountpoint)
```
## 5.4 中间件活跃连接数
```yaml
- record: mysql:client_connections:sum
  expr: sum(mysql_global_status_threads_connected) by (instance, env)
```
## 5.5 集群运行Pod总数
```yaml
- record: cluster:pod_running:count
  expr: count(kube_pod_status_phase{phase="Running"}) by (namespace, env)
```

# 6. 窗口、周期、标签基数管控规范
## 6.1 评估周期 interval
1. 业务实时指标：`1m`（全局统一，与Prometheus evaluationInterval对齐）；
2. 离线/低频中间件：`5m`，减少计算开销。

## 6.2 滑动窗口统一标准
- 流量、延迟计数器：固定 `[5m]`；
- 宿主机资源瞬时指标irate：`[5m]`；
禁止混用1m/10m窗口，避免指标口径混乱。

## 6.3 标签基数管控红线
1. by() 内维度不超过4个；
2. 必须删除 `pod_name/container_name/uid` 等高基数标签；
3. 若原始指标存在无用annotation标签，使用relabel前置过滤。

## 6.4 存储分层留存策略
- 原始采集指标：保留7天，高精度；
- Recording预聚合指标：保留30~90天，支撑长期趋势大盘；
通过Prometheus storage retention配置分层。

# 7. 多环境差异化聚合策略
## 7.1 Dev环境：精简聚合，降低存储占用
```yaml
# Dev环境仅保留namespace维度，删除service_name细分
- record: service:http_qps:sum
  expr: sum(rate(http_server_requests_seconds_count[5m])) by (env, namespace)
```
## 7.2 UAT环境：关闭百分位延迟聚合（非核心需求）
单独分组区分环境，不生成p95/p99时序：
```yaml
groups:
  - name: business.service.recording.uat
    interval: 5m
    rules:
      - record: service:http_qps:sum
        expr: sum(rate(http_server_requests_seconds_count[5m])) by (service_name, env)
```
## 7.3 生产环境：完整多维度聚合，全量指标生成

# 8. 调试验证、查询校验流程
## 8.1 本地语法校验（上线前）
```bash
promtool check rules recording-rules.yaml
```
## 8.2 下发规则热更新
```bash
helm upgrade kube-monitor /opt/charts/kube-prometheus-stack -n monitoring
```
## 8.3 Prometheus UI校验
1. Status → Rules：查看record分组是否加载成功、无执行报错；
2. Graph页面直接检索预聚合指标名称（`service:http_qps:sum`），验证时序正常生成；
3. 对比原始指标与预聚合指标曲线，确认数值对齐、口径一致。

## 8.4 排查规则未生成时序
1. 检查PrometheusRule是否携带 `platform:monitor` 标签；
2. 查看Prometheus日志过滤rule执行错误：
```bash
kubectl logs -f sts/kube-monitor-prometheus-0 -n monitoring | grep "recording"
```

# 9. 性能风险与禁用反模式
## 9.1 严格禁止反模式
1. Record规则与Alert告警放置同一group，维护混乱、执行优先级冲突；
2. by()携带pod/container等高基数标签，预聚合时序爆炸，存储翻倍；
3. 不做分母判0，生成大量NaN无效时序；
4. 窗口混用1m/10m，多团队指标口径不一致；
5. 预聚合逻辑过于简单（仅复制原始指标无聚合，完全浪费计算资源）；
6. 单条规则同时sum+count+histogram_quantile多重嵌套，单次计算耗时过高；
7. Dev/UAT环境完全复用生产全维度聚合，浪费存储。

## 9.2 性能风险识别指标
出现以下现象需优化Record规则：
1. `prometheus_rule_evaluation_duration_seconds` 均值 >0.5s；
2. `prometheus_tsdb_head_series` 持续上涨；
3. Prometheus CPU占用长期高于80%。

# 10. 落地最佳实践清单
1. 按业务/中间件拆分独立PrometheusRule CR，每个CR仅存放一类组件Record规则；
2. 所有流量、资源大盘强制使用预聚合指标，禁止前端直接聚合原始时序；
3. 长期趋势（周/月）看板仅读取Recording指标；
4. 同一计算逻辑多处复用（告警+多块面板）必须抽取为预聚合；
5. 定期清理无用Record规则，删除下线业务对应的预聚合时序；
6. 新增业务时同步编写配套Record规则，纳入上线CR审核；
7. Grafana模板统一使用 `metric_type="recording"` 标签过滤预聚合指标，避免混用原始指标。

# 11. 关联文档索引
1. PrometheusRule 总规范：05-prometheus-operator/03-prometheusrule.md
2. Prometheus 存储与数据留存策略：03-storage/02-data-retention.md
3. Prometheus 全局抓取与资源调优：04-workload/01-prometheus.md
4. 监控性能故障排查手册：09-troubleshooting/02-prometheus-error.md
5. Grafana 大盘标准化规范：05-prometheus-operator/04-dashboard-standard.md