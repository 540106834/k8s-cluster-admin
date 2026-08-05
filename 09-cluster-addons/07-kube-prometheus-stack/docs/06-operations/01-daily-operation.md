# docs/09-operation/01-daily-operation.md
# K8s监控平台日常运维操作手册
## 文档基础信息
- 集群版本：K8s 1.32.0
- 监控组件：kube-prometheus-stack 65.1.0
- 管控模式：GitOps + ArgoCD 统一交付
- 适用人员：SRE/运维工程师、平台管理员
- 文档等级：★★★★★ 生产必守操作规范
- 前置文档：04-workload/01-prometheus.md、04-workload/02-grafana.md、05-prometheus-operator全规范

## 目录
1. 每日巡检标准化清单（早班/中班/夜班）
2. Prometheus 日常运维操作（启停、扩容、存储、规则）
3. Grafana 日常运维操作（账号、面板、插件、备份）
4. Alertmanager 告警运维（路由、抑制、静默、渠道）
5. CR采集资源运维（ServiceMonitor/PodMonitor/PrometheusRule）
6. 存储NFS/NFS-Subdir持久卷运维
7. 日志排查标准命令集
8. 版本升级标准化流程
9. 日常变更发布规范（GitOps流程）
10. 应急基础操作（组件异常、存储满、采集雪崩）
11. 权限与安全日常检查项
12. 周/月定期维护任务

---

# 1. 每日巡检标准化清单
## 1.1 早班开机巡检（09:00，10分钟）
### 集群Pod状态
```bash
# 监控命名空间Pod全量健康检查
kubectl get pods -n monitoring -o wide
# 检查重启次数 >0 的异常Pod
kubectl get pods -n monitoring | awk '$3!="Running" || $4>0'
```
检查项：
1. Prometheus StatefulSet 副本数正常，无 CrashLoopBackOff
2. Grafana Deployment 正常运行，无OOM重启
3. Alertmanager 副本存活
4. node-exporter/cadvisor DaemonSet 全节点就绪
5. kube-state-metrics 无频繁重启

### 存储与磁盘水位
1. 监控PVC挂载磁盘使用率 <80%
2. NFS存储服务器磁盘总占用 <85%
3. Prometheus TSDB 无磁盘满、写入阻塞

### 告警总览
1. Grafana 监控大盘查看平台自身告警（Prometheus Down、采集失败、存储高水位）
2. 钉钉监控群无持续刷屏Critical告警
3. 确认夜间故障已全部恢复、无遗留Firing告警

## 1.2 中班业务巡检（14:00，5分钟）
1. 业务ServiceMonitor/PodMonitor无大量Dropped采集目标
2. Prometheus rule执行无报错（Status-Rules页面无Err）
3. 业务错误率、延迟无全局突增
4. 告警渠道（钉钉/企微）推送正常，无渠道失联

## 1.3 夜班收尾巡检（21:00，5分钟）
1. 清理当日临时静默规则、临时调整阈值
2. 确认所有Critical告警恢复，未恢复需登记值班台账
3. 校验Prometheus写入速率，无突降（采集雪崩）
4. 检查NFS备份定时任务执行记录

# 2. Prometheus 日常运维操作
## 2.1 副本弹性扩缩容（StatefulSet）
```bash
# 扩容Prometheus副本
kubectl scale statefulset kube-monitor-prometheus -n monitoring --replicas=2
# 缩容
kubectl scale statefulset kube-monitor-prometheus -n monitoring --replicas=1
```
约束：生产至少2副本实现高可用，缩容前确认存储共享就绪。

## 2.2 TSDB存储基础操作
### 查看当前数据保留时长
```bash
kubectl get cm kube-monitor-prometheus-config -n monitoring -o yaml | grep retention
```
### 手动清理老旧数据（磁盘爆满应急）
```bash
# 进入Prometheus容器
kubectl exec -it kube-monitor-prometheus-0 -n monitoring -- sh
# 压缩删除超过30天块数据
promtool tsdb delete --min-time=$(date -d "30 days ago" +%s) /prometheus
```
### 校验TSDB完整性
```bash
promtool tsdb check /prometheus
```

## 2.3 规则重载（无需重启Pod）
Git提交规则变更后ArgoCD自动同步；手动强制重载API：
```bash
curl -X POST http://kube-monitor-prometheus.monitoring.svc.cluster.local:9090/-/reload
```

## 2.4 采集限流/临时屏蔽业务
临时屏蔽某命名空间所有采集目标，Prometheus顶层ruleRelabel：
```yaml
prometheus:
  prometheusSpec:
    ruleRelabelConfigs:
      - sourceLabels: [namespace]
        regex: test-temp
        action: drop
```
提交Git自动生效，无需重启组件。

## 2.5 日志查看标准
```bash
# 实时日志
kubectl logs -f sts/kube-monitor-prometheus -n monitoring
# 查看近1000行错误日志
kubectl logs --tail=1000 sts/kube-monitor-prometheus -n monitoring | grep -i error
# 历史崩溃日志
kubectl logs --previous kube-monitor-prometheus-0 -n monitoring
```

# 3. Grafana 日常运维操作
## 3.1 账号管理
1. 管理员账号密码统一存放Secret，禁止明文硬编码
```bash
# 查看admin密码
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```
2. 离职人员账号清理：Grafana页面组织用户删除，同步OIDC权限回收
3. 只读账号统一分配Viewer角色，禁止业务人员Editor/Admin权限

## 3.2 面板运维
### 导入临时面板
仅调试使用，上线前必须导出JSON提交Git托管，禁止长期本地存储。
### 批量面板失效排查
```bash
# 查看Grafana日志筛选数据源报错
kubectl logs -f deploy/kube-monitor-grafana -n monitoring | grep datasource
```
### 面板备份（全量SQLite）
```bash
# 拷贝grafana.db到本地备份
kubectl cp kube-monitor-grafana-7f96c8d76-2xq9l:/var/lib/grafana/grafana.db ./grafana-$(date +%Y%m%d).db -n monitoring
```

## 3.3 插件管理
所有插件统一在values.yaml grafana.plugins配置，自动安装，禁止容器内手动安装。
插件加载异常排查：查看Grafana启动日志plugin加载报错。

## 3.4 重启Grafana（配置变更后）
```bash
kubectl rollout restart deployment kube-monitor-grafana -n monitoring
# 观察滚动更新进度
kubectl rollout status deploy/kube-monitor-grafana -n monitoring
```

# 4. Alertmanager 告警运维
## 4.1 临时静默告警（维护窗口）
### 方式1：API临时静默（临时维护，重启失效）
```bash
# 创建2小时静默
curl -X POST http://kube-monitor-alertmanager.monitoring.svc:9093/api/v2/silences -d '{
  "matchers": [{"name": "alert_group", "value": "business-api", "isRegex": false}],
  "startsAt": "'$(date -Iseconds)'",
  "endsAt": "'$(date -Iseconds -d "+2 hours")'",
  "comment": "业务升级维护静默",
  "createdBy": "sre-name"
}'
```
### 方式2：Git静态静默（长期维护窗口，推荐）
修改alertmanagerConfig CRD，写入silences规则，Git永久留存。

## 4.2 告警渠道故障排查
```bash
# 过滤告警发送失败日志
kubectl logs -f statefulset/kube-monitor-alertmanager -n monitoring | grep notify
```
常见问题：Webhook密钥失效、出口网络策略拦截、企业微信/钉钉接口限流。

## 4.3 重载Alertmanager配置
```bash
curl -X POST http://kube-monitor-alertmanager.monitoring.svc:9093/-/reload
```

## 4.4 告警抑制规则更新
节点整机故障抑制Pod告警统一托管在AlertmanagerConfig，变更走GitOps发布。

# 5. 采集CR资源日常运维
## 5.1 批量查看采集资源
```bash
# 查看全量ServiceMonitor
kubectl get servicemonitor -A
# 查看全量PodMonitor
kubectl get podmonitor -A
# 查看全量告警/预聚合规则
kubectl get prometheusrule -A
```

## 5.2 临时禁用单业务采集
修改对应CR标签，移除 `platform: monitor`，Prometheus自动忽略：
```yaml
metadata:
  labels:
    # platform: monitor 注释此行
```
提交Git同步，无需重启Prometheus。

## 5.3 采集目标Dropped/down排查标准流程
1. 确认Namespace存在 `monitor-enabled: "true"`
2. CR存在 `platform: monitor` 标签
3. Prometheus UI Status-Targets查看具体报错（连接超时/鉴权失败/relabel丢弃）
4. 集群内curl验证metrics端口连通性
5. 检查NetworkPolicy是否拦截monitoring命名空间访问业务Pod

## 5.4 规则语法校验（发布前本地校验）
```bash
# 批量校验规则文件
promtool check rules ./rules/*.yaml
```

# 6. 持久化存储PVC日常运维
## 6.1 PVC挂载状态检查
```bash
kubectl get pvc -n monitoring
# 查看PVC挂载异常Pod
kubectl describe pvc kube-monitor-prometheus-db -n monitoring
```

## 6.2 NFS存储扩容
1. 扩容NFS后端磁盘容量
2. 无需修改PVC（NFS支持在线扩容）
3. 验证容器内磁盘识别容量更新
```bash
kubectl exec -it kube-monitor-prometheus-0 -n monitoring -- df -h /prometheus
```

## 6.3 磁盘爆满应急清理流程
1. 优先清理Prometheus老旧TSDB块（见2.2）
2. 清理Grafana过期备份db文件
3. 临时扩容NFS磁盘
4. 长期优化：调整Prometheus retention缩短数据保留时间

# 7. 通用日志排查命令集
## 7.1 Prometheus 采集异常
```bash
# 采集目标连接错误
kubectl logs sts/kube-monitor-prometheus -n monitoring | grep scrape
# 规则执行报错
kubectl logs sts/kube-monitor-prometheus -n monitoring | grep rule
# 存储写入异常
kubectl logs sts/kube-monitor-prometheus -n monitoring | grep tsdb
```
## 7.2 Grafana 面板无数据
```bash
kubectl logs deploy/kube-monitor-grafana -n monitoring | grep -E "datasource|query"
```
## 7.3 告警收不到
```bash
kubectl logs sts/kube-monitor-alertmanager -n monitoring | grep -E "notify|silence"
```
## 7.4 采集组件node-exporter异常
```bash
kubectl logs daemonset/kube-monitor-node-exporter -n monitoring
```

# 8. 版本升级标准化流程（kube-prometheus-stack）
1. 本地修改Chart版本号values.yaml
2. 本地执行helm template渲染，无语法报错
3. promtool校验所有PrometheusRule规则
4. 提交Git，ArgoCD进入预同步阶段
5. 监控命名空间滚动更新，实时观察Pod重建状态
6. 升级完成校验：采集目标UP、告警渠道正常、大盘数据完整
7. 留存升级操作记录台账

# 9. GitOps变更发布规范（强制）
所有监控组件配置变更（values、SM/PM/PrometheusRule、AlertConfig）必须遵循：
1. 分支：dev测试 → prod生产
2. 提交备注：【操作类型】业务/组件-变更内容
3. 本地预校验：helm template + promtool check rules
4. ArgoCD自动同步，禁止kubectl apply手动创建CR
5. 变更完成后5分钟巡检验证生效状态

禁止操作：
- 直接kubectl edit修改集群内CR/ConfigMap/Secret
- 容器内手动修改配置、安装插件
- 临时配置不提交Git，丢失无法追溯

# 10. 高频应急基础操作
## 10.1 Prometheus 采集雪崩（大量target down）
1. 临时扩容Prometheus副本
2. 检查是否新增上万采集目标，临时下线异常ServiceMonitor
3. 调大prometheusSpec.resources内存限制
4. 清理高基数无用指标metricRelabel drop

## 10.2 Prometheus OOM反复重启
1. 临时调高内存limit
2. 清理TSDB老旧数据释放磁盘/内存
3. 优化Record规则，减少高基数聚合
4. 拆分超大ServiceMonitor为多个CR分散负载

## 10.3 Grafana 所有面板无数据
1. 检查Prometheus服务是否正常、Endpoint可连通
2. 校验Grafana数据源配置（ArgoCD是否同步丢失配置）
3. 重启Grafana Deployment
4. 确认NetworkPolicy放行monitoring→业务端口

## 10.4 磁盘占满无法写入指标
1. 进入Prometheus容器删除老旧tsdb块
2. 扩容NFS存储后端
3. 临时缩短retention保留时长
4. 长期拆分Thanos远程存储冷热分离

# 11. 权限与安全日常检查项（每日）
1. monitoring命名空间RBAC权限无过度宽松ClusterRole
2. Grafana OIDC登录正常，无通用弱密码admin账号对外开放
3. Secret密钥不存储明文，无git硬编码密钥
4. Ingress全部强制TLS，无HTTP裸域名访问Grafana
5. NetworkPolicy限制monitoring命名空间入出站，禁止全通配规则
6. 定期轮换告警Webhook、数据源数据库密钥（月度任务）

# 12. 周/月定期维护任务
## 每周一执行
1. 清理过期静默规则、下线废弃业务采集CR
2. 统计Prometheus时序基数增长，评估存储扩容需求
3. 巡检所有Grafana大盘失效面板，修复或归档废弃面板

## 每月最后一个工作日
1. 全量备份Prometheus TSDB快照、Grafana grafana.db
2. 轮换所有告警渠道、数据源密钥
3. Chart版本小版本迭代升级（安全补丁）
4. 审计监控平台账号权限，清理离职/闲置账号
5. 整理当月故障台账，优化对应告警阈值与预聚合规则

# 13. 关联文档索引
1. Prometheus全局资源调优：04-workload/01-prometheus.md
2. 存储分层与数据留存：03-storage/02-data-retention.md
3. 采集CR规范：05-prometheus-operator/01-servicemonitor.md / 02-podmonitor.md
4. 告警规则规范：05-prometheus-operator/03-prometheusrule.md
5. 故障排查总手册：09-troubleshooting/00-troubleshooting-index.md
6. GitOps发布标准：10-best-practice/gitops-cicd.md