# docs/09-operation/04-health-check.md
# K8s监控平台健康巡检标准手册
## 基础信息
- K8s集群：1.32.0
- 监控栈：kube-prometheus-stack 65.1.0
- 交付：ArgoCD GitOps
- 适用：SRE日常定时巡检、变更后验收、故障根因定位预检
- 前置文档：01-daily-operation.md、02-backup-restore.md、03-rollback.md

## 目录
1. 巡检分层与执行周期规范
2. 第一层：K8s容器资源健康检查（Pod/Deployment/STS/DaemonSet）
3. 第二层：存储持久层健康（PVC/NFS/TSDB/grafana.db）
4. 第三层：Prometheus核心健康校验（采集、规则、存储、API）
5. 第四层：Grafana可视化链路校验（数据源、大盘、账号）
6. 第五层：Alertmanager告警链路全链路校验
7. 第六层：采集CR资源合规校验（SM/PM/PrometheusRule）
8. 第七层：备份任务健康校验
9. 一键批量巡检脚本（可定时Cron执行）
10. 健康分级判定标准（正常/预警/故障）
11. 关联文档索引

---

# 1. 巡检分层与执行周期规范
## 1.1 三层执行周期
1. **实时轻量巡检（5分钟自动）**：监控平台自身组件存活、端口连通、磁盘水位告警指标
2. **每日标准化全量巡检（早班09:00人工执行）**：本文完整7层校验清单
3. **变更后强制验收巡检**：Chart升级/配置提交/CR修改后必须完整跑完所有校验项

## 1.2 巡检前置条件
1. ArgoCD应用同步状态为Synced，无OutOfSync/Unknown
2. 集群网络策略无阻断monitoring命名空间内外访问
3. 备份NFS存储服务正常挂载

# 2. 第一层：K8s容器资源健康检查
## 2.1 组件实例状态校验命令
```bash
# 查看全量监控组件状态
kubectl get sts,deploy,ds -n monitoring -o wide
# 筛选异常Pod：未就绪、重启次数>0
kubectl get pods -n monitoring | awk '$3!="Running" || $4>0'
```
## 2.2 逐项校验标准
### StatefulSet（Prometheus / Alertmanager）
1. 副本数匹配values.yaml配置，无缩容扩容进行中
2. Pod Ready状态1/1，重启次数=0
3. PVC绑定正常，无Lost/Unbound状态
4. liveness/readiness探针持续成功，无探针超时报错

### Deployment（Grafana / kube-state-metrics）
1. 可用副本数等于期望副本
2. 滚动更新完成，无progressDeadlineExceeded
3. OOMKilled事件为0，无频繁重启

### DaemonSet（node-exporter / cadvisor）
1. 集群所有节点Pod全部就绪，无节点缺失实例
2. 无节点资源不足导致Pending

## 2.3 资源配额校验
1. CPU/内存实际使用不超过limit 80%，长期超限判定预警
2. 无容器因内存限制被OOM杀死（查看Events）
```bash
kubectl get events -n monitoring --sort-by=.lastTimestamp | grep -i oom
```

# 3. 第二层：存储持久层健康校验
## 3.1 PVC挂载状态
```bash
kubectl get pvc -n monitoring
kubectl describe pvc kube-monitor-prometheus-db -n monitoring
```
校验点：
- Status: Bound；StorageClass匹配NFS-Subdir；无挂载失败事件

## 3.2 磁盘水位校验
### Prometheus TSDB磁盘
```bash
kubectl exec kube-monitor-prometheus-0 -n monitoring -- df -h /prometheus
```
判定阈值：
- <80%：正常；80%~85%：预警；≥85%：故障，立即清理快照/扩容

### Grafana数据盘
```bash
kubectl exec deploy/kube-monitor-grafana -n monitoring -- df -h /var/lib/grafana
```
grafana.db文件存在、文件大小稳定增长，无空文件/0字节损坏库

### 备份NFS盘
```bash
df -h /nfs/monitor-backup
```
备份盘水位阈值同80%红线，避免备份任务失败

## 3.3 TSDB完整性预检
```bash
kubectl exec kube-monitor-prometheus-0 -n monitoring -- promtool tsdb check /prometheus
```
输出`DB is OK`为正常；出现block损坏直接判定故障，启动快照回滚流程

# 4. 第三层：Prometheus核心健康校验
## 4.1 API连通性校验
```bash
# 健康接口
curl -s http://kube-monitor-prometheus.monitoring.svc:9090/-/healthy
# 就绪接口
curl -s http://kube-monitor-prometheus.monitoring.svc:9090/-/ready
```
必须返回 `OK`，超时/报错判定组件故障

## 4.2 采集目标Targets校验
1. UI路径：Status → Targets
2. 校验标准：
   - UP目标占比100%，无大规模Down
   - Down目标分类排查：网络不通、metrics端口未开放、relabel丢弃
3. 批量查看失败采集目标命令：
```bash
curl -s http://kube-monitor-prometheus.monitoring.svc:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health!="up")'
```

## 4.3 Rules规则健康校验
UI路径：Status → Rules
1. 所有分组无Err状态
2. 无大量重复告警、无规则执行超时日志
3. 预聚合Recording指标可正常查询，无NaN空曲线
```bash
# 规则执行错误日志检索
kubectl logs sts/kube-monitor-prometheus -n monitoring | grep -i rule.*error
```

## 4.4 核心运行指标预检（直接查询PromQL）
1. `prometheus_tsdb_head_series`：时序总量无突增突降（突增预警采集雪崩）
2. `prometheus_target_scrapes_sample_out_of_order_total`：乱序样本持续增长判定采集异常
3. `prometheus_rule_evaluation_duration_seconds`：P95 < 0.5s，过高预警规则性能差

# 5. 第四层：Grafana可视化链路校验
## 5.1 服务连通性
```bash
curl -s http://kube-monitor-grafana.monitoring.svc:3000/api/health
```
返回ok为正常，无法访问判定故障

## 5.2 数据源校验
1. 所有Prometheus数据源状态绿色连通，无HTTP 5xx/认证失败
2. 测试数据源查询：基础指标`up{}`可正常返回数据
## 5.3 大盘可用性抽检
随机抽取3个核心业务大盘：
1. 面板无"Data source error"
2. 曲线连续无断档，近24小时数据完整
3. 告警面板可正常展示Firing告警

## 5.4 账号与权限预检
1. OIDC登录流程正常，无登录跳转失败
2. 无闲置管理员账号，业务账号仅分配Viewer角色

# 6. 第五层：Alertmanager告警链路全链路校验
## 6.1 服务健康检测
```bash
curl -s http://kube-monitor-alertmanager.monitoring.svc:9093/-/healthy
```
返回OK为正常

## 6.2 配置加载校验
```bash
curl -s http://kube-monitor-alertmanager.monitoring.svc:9093/api/v2/status | jq '.config'
```
无配置解析报错，路由、抑制、匹配规则完整加载

## 6.3 告警渠道发送测试
手动触发测试告警，验证钉钉/企业微信渠道可接收：
```bash
# 推送测试通知
curl -X POST 告警webhook地址 -d '{"text":"监控平台健康巡检测试消息"}'
```
## 6.4 静默规则预检
无过期遗留silence、无错误全局静默导致告警收不到
```bash
curl http://kube-monitor-alertmanager.monitoring.svc:9093/api/v2/silences
```

# 7. 第六层：采集CR资源合规校验
## 7.1 CR完整性校验
```bash
kubectl get servicemonitor,podmonitor,prometheusrule -A
```
业务命名空间CR数量与Git仓库清单匹配，无丢失/多余废弃CR

## 7.2 标签合规校验
1. 所有业务SM/PM必须携带标签 `platform: monitor`
2. Namespace必须配置标签 `monitor-enabled: true`，否则采集被过滤
## 7.3 规则语法预检
批量校验所有PrometheusRule无PromQL语法错误
```bash
# 本地仓库校验
promtool check rules ./rules/*.yaml
# 集群在线校验：临时导出所有规则做dry-run
kubectl get prometheusrule -A -o yaml > all-rules.yaml && promtool check rules all-rules.yaml
```

## 7.4 无高基数违规规则
规则中禁止未去除`pod_name/container_name`等高基数标签，避免时序爆炸

# 8. 第七层：备份任务健康校验
1. 校验昨日备份文件存在：prom快照tar包、grafana.db、CR导出yaml
2. 备份文件完整性校验：
   - TSDB快照：promtool tsdb check解压目录无报错
   - grafana.db：sqlite3 integrity_check返回ok
3. 自动清理脚本正常执行，无30天以上过期备份堆积

# 9. 一键批量巡检脚本（health-check.sh）
```bash
#!/bin/bash
echo "===== 1. Pod资源状态检查 ====="
kubectl get pods -n monitoring | awk '$3!="Running" || $4>0'

echo -e "\n===== 2. Prometheus 健康接口 ====="
curl -s http://kube-monitor-prometheus.monitoring.svc:9090/-/healthy

echo -e "\n===== 3. Alertmanager 健康接口 ====="
curl -s http://kube-monitor-alertmanager.monitoring.svc:9093/-/healthy

echo -e "\n===== 4. Grafana 健康接口 ====="
curl -s http://kube-monitor-grafana.monitoring.svc:3000/api/health

echo -e "\n===== 5. 磁盘水位 ====="
kubectl exec kube-monitor-prometheus-0 -n monitoring -- df -h /prometheus
kubectl exec deploy/kube-monitor-grafana -n monitoring -- df -h /var/lib/grafana

echo -e "\n===== 6. 异常采集目标 ====="
curl -s http://kube-monitor-prometheus.monitoring.svc:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health!="up") | .labels, .health'
```
可配置定时任务每5分钟自动输出巡检日志至监控日志盘。

# 10. 健康分级判定标准
## 10.1 正常（绿色）
所有分层校验全部通过；磁盘水位<80%；无重启Pod；采集UP率100%；备份完整。

## 10.2 预警（黄色，24小时内处理）
1. 磁盘水位80%~85%
2. 少量非核心业务采集目标Down（<5%）
3. Pod单次偶然重启，无复现
4. 备份任务延迟1小时内完成，文件完好

## 10.3 故障（红色，立即处理，必要触发回滚）
1. 组件Pod CrashLoop/OOM/探针失败
2. Prometheus/Alertmanager健康接口返回异常
3. 磁盘水位≥85%，TSDB写入阻塞
4. 采集目标大规模Down（>20%）
5. 规则存在Err，告警链路完全中断
6. 昨日备份文件缺失/损坏

# 11. 关联文档索引
1. 日常运维操作手册：09-operation/01-daily-operation.md
2. 备份恢复操作：09-operation/02-backup-restore.md
3. 变更回滚流程：09-operation/03-rollback.md
4. Prometheus调优规范：04-workload/01-prometheus.md
5. 故障排查总目录：09-troubleshooting/00-troubleshooting-index.md