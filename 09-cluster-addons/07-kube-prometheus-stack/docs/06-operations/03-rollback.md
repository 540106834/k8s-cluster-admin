# docs/09-operation/03-rollback.md
# 监控平台回滚标准化操作手册
## 基础信息
- K8s集群版本：1.32.0
- 监控组件栈：kube-prometheus-stack 65.1.0
- 交付模式：ArgoCD GitOps唯一发布入口
- 适用对象：SRE/平台运维；覆盖Chart升级、配置变更、CR资源、TSDB数据四类回滚场景
- 前置依赖文档：09-operation/01-daily-operation.md、09-operation/02-backup-restore.md

## 目录
1. 回滚通用前置规范与判定标准
2. 场景1：Chart版本升级失败回滚（Prometheus/Grafana/Alertmanager）
3. 场景2：Git配置变更回滚（values/AlertConfig/采集CR/规则）
4. 场景3：单业务CR资源误变更/删除紧急回滚
5. 场景4：TSDB时序数据损坏/规则错误污染数据回滚
6. 场景5：Grafana大盘/数据源配置变更回滚
7. 回滚后统一验证检查清单
8. 禁止操作与风险红线
9. 回滚故障复盘流程
10. 关联文档索引

---

# 1. 回滚通用前置规范与判定标准
## 1.1 触发回滚判定条件（满足任意立即执行）
1. Chart升级后组件持续CrashLoop、OOM、无法就绪，10分钟内修复无果
2. Git提交配置变更后：采集目标大规模Down、规则全报错、告警渠道失联
3. 误删/误改ServiceMonitor/PrometheusRule导致业务指标断流、大量垃圾告警
4. Prometheus规则错误写入非法时序、TSDB块损坏，历史曲线异常
5. Grafana数据源/大盘批量失效，业务无法查看监控
6. 变更引发Critical级全集群告警雪崩，影响业务运维

## 1.2 回滚前置必做操作
1. 记录当前故障现象、变更commit ID/Chart版本、操作人、时间点，留存台账
2. 确认对应时间点**有效备份**存在（TSDB快照/GrafanaDB/CR导出备份）
3. 临时关闭自动同步（ArgoCD手动暂停Auto-Sync，防止变更覆盖回滚操作）
```bash
# 暂停ArgoCD应用自动同步
argocd app set kube-monitor --sync-policy none
```
4. 通知业务值班、SRE组长，同步回滚操作窗口

## 1.3 回滚优先级规则
1. Git代码回滚（最优，永久可追溯，优先使用）
2. ArgoCD历史版本同步回滚（Chart升级场景）
3. 本地备份资源覆盖恢复（仅Git仓库不可用兜底）
4. TSDB/Grafana数据快照恢复（数据损坏专属）

# 2. 场景1：Chart版本升级失败回滚
适用：kube-prometheus-stack大/小版本升级、values全局参数修改导致组件异常
## 2.1 方式A：ArgoCD UI历史Revision回滚（推荐）
1. ArgoCD控制台进入`kube-monitor`应用 → History&Rollback
2. 选择升级前正常运行的Revision ID，点击Rollback
3. 勾选`Prune Resources`，确认同步，观察滚动更新进度
4. 监控Pod重建状态，等待所有副本就绪

## 2.2 方式B：Git代码回滚Chart版本（永久修复，杜绝反复自动升级）
```bash
# 1. 切至监控仓库目录，回滚至上一个正常commit
git log --oneline | grep "chart version"
git revert <异常变更commit-id>
# 2. 本地预校验渲染，无语法报错
helm template ./charts/kube-prometheus-stack -f values-prod.yaml
# 3. 推送回滚提交至远端
git push origin prod
# 4. ArgoCD手动触发同步
argocd app sync kube-monitor
```

## 2.3 紧急兜底：临时缩容异常组件，旧版本临时恢复
若新版本Prometheus持续OOM无法启动：
```bash
# 1. 缩容异常新版本副本至0
kubectl scale statefulset kube-monitor-prometheus -n monitoring --replicas=0
# 2. 临时使用旧Chart包本地部署应急（仅机房故障兜底）
helm install temp-monitor ./old-chart -n monitoring
```

## 2.4 升级回滚风险点
- PVC持久化存储保留，回滚后无需重建TSDB数据；
- 大版本CRD变更不可逆，若升级新增CRD，回滚后需手动清理多余CRD；
- Grafana插件版本跟随Chart，回滚后自动还原插件列表。

# 3. 场景2：Git配置变更回滚（values/AlertConfig/采集CR/规则）
适用：修改SM/PM/PrometheusRule、AlertmanagerConfig、全局values引发异常
## 3.1 标准Git回滚流程（生产标准操作）
```bash
# 1. 查询故障变更提交记录
git log --oneline --grep="monitor rule/serviceMonitor"
# 2. 生成反向提交，保留变更记录便于审计
git revert <故障commit-id>
# 3. 本地语法校验
# 校验Prometheus规则
promtool check rules ./rules/*.yaml
# 校验helm配置渲染
helm template ./charts -f values-prod.yaml
# 4. 推送远端，ArgoCD自动/手动同步
git push origin prod
argocd app sync kube-monitor
```

## 3.2 紧急临时阻断（来不及提交Git时短期应急）
仅用于阻断故障影响，禁止长期使用，事后必须补Git回滚：
1. 暂停ArgoCD自动同步
2. `kubectl edit`临时注释故障配置/删除异常标签`platform: monitor`
3. 操作完成记录台账，1小时内完成标准Git回滚

## 3.3 特殊：Alertmanager路由/抑制规则错误回滚
配置回滚同步完成后，手动重载配置立即生效，无需重启Pod：
```bash
curl -X POST http://kube-monitor-alertmanager.monitoring.svc:9093/-/reload
```

# 4. 场景3：单业务CR资源误变更/删除紧急回滚
适用：误删业务PrometheusRule、ServiceMonitor、PodMonitor，指标/告警中断
## 4.1 最优：Git回滚对应业务YAML，ArgoCD重建资源
同3.1 Git revert流程，精准回滚单文件，不影响其他业务配置。

## 4.2 兜底方案：使用定时CR备份包恢复
Git仓库损坏/本地未提交变更时，使用每日自动导出CR备份恢复：
```bash
# 从备份包提取对应业务资源，dry-run校验语法
kubectl apply -f /nfs/backup/k8s-monitor-cr/20260802/cr-all.yaml --dry-run=client
# 正式恢复
kubectl apply -f /nfs/backup/k8s-monitor-cr/20260802/cr-all.yaml
```

## 4.3 临时快速屏蔽故障CR
若错误规则引发Prometheus高负载CPU，临时移除采集标签快速阻断：
```yaml
metadata:
  labels:
    # platform: monitor 注释，Prometheus自动忽略该CR
```

# 5. 场景4：TSDB时序数据损坏/规则错误污染数据回滚
适用：错误Recording规则生成脏时序、TSDB块损坏、误删指标历史数据
## 5.1 短期脏数据清理（无需全量恢复快照）
```bash
# 进入Prometheus容器，删除指定时间范围脏时序
kubectl exec -it kube-monitor-prometheus-0 -n monitoring -- sh
promtool tsdb delete --min-time=$(date -d "1 hour ago" +%s) --max-time=$(date +%s) /prometheus
```

## 5.2 全量TSDB快照回滚（数据大面积损坏）
完整流程参考备份恢复文档，简化回滚步骤：
1. 缩容Prometheus副本至0，停止写入
2. 清空PVC内/prometheus目录
3. 解压故障前有效快照包至PVC，修复权限`chown -R 65534:65534`
4. 扩容副本启动，校验历史曲线

## 5.3 配套操作
回滚数据后同步回滚出错RecordingRule，防止再次生成脏数据。

# 6. 场景5：Grafana大盘/数据源配置变更回滚
## 6.1 轻量回滚：Git托管大盘JSON恢复
所有业务大盘JSON提交Git，变更异常直接Git revert对应大盘文件，ArgoCD同步后Grafana自动加载。

## 6.2 全量数据库回滚（数据源/账号/批量大盘损坏）
使用每日grafana.db备份覆盖恢复，流程：
1. 暂停Grafana Deployment滚动
2. 拷贝历史完好db备份至Pod内
3. 修复文件权限，恢复Deployment运行
4. 登录验证所有数据源、大盘、账号权限正常

# 7. 回滚后统一验证检查清单（所有场景必执行）
## 7.1 Prometheus校验
1. StatefulSet副本全部Running，无重启、Crash
2. Status → Targets：全业务采集目标UP率100%，无大量Dropped
3. Status → Rules：Record/Alert分组无Err，规则正常执行
4. Graph页面：核心业务QPS、资源指标曲线连续无断档
5. TSDB无日志报错，写入速率恢复正常

## 7.2 Grafana校验
1. 所有业务大盘正常渲染，无数据源连接失败
2. 数据源账号、地址配置还原至变更前状态
3. 告警通知渠道测试推送正常

## 7.3 Alertmanager校验
1. 路由、抑制、静默规则还原
2. 模拟异常指标可正常触发对应等级告警，无垃圾刷屏

## 7.4 集群CR资源校验
```bash
kubectl get servicemonitor,podmonitor,prometheusrule -A
```
所有业务采集、规则资源与变更前数量一致，无缺失/多余CR。

## 7.5 业务侧确认
同步业务开发确认监控指标、告警恢复正常，无业务影响。

# 8. 禁止操作与风险红线
1. 禁止直接`kubectl edit`修改资源作为长期回滚方案，必须落Git追溯
2. 禁止回滚完成后不暂停ArgoCD自动同步，导致变更再次覆盖
3. 禁止TSDB回滚前不停止Prometheus写入，引发数据双重写入损坏块
4. 禁止大版本Chart回滚后遗留废弃CRD，造成资源冲突
5. 禁止跳过回滚校验清单直接结束操作，遗留隐性故障
6. 禁止无备份情况下执行数据级回滚（TSDB/GrafanaDB）

# 9. 回滚故障复盘流程
1. 回滚完成、业务恢复2小时内，填写故障台账：
   - 变更人、变更时间、故障现象、回滚操作、影响时长
2. 根因定位：配置校验缺失/Chart兼容性未测试/规则PromQL语法漏洞/操作失误
3. 优化落地：补充预校验脚本、增加变更灰度窗口、完善上线审核规则
4. 同步复盘结论至SRE群，更新操作手册避坑要点

# 10. 关联文档索引
1. 日常运维标准操作：09-operation/01-daily-operation.md
2. 备份与恢复全流程：09-operation/02-backup-restore.md
3. GitOps发布规范：10-best-practice/gitops-cicd.md
4. Prometheus Chart调优文档：04-workload/01-prometheus.md
5. 全故障排查总目录：09-troubleshooting/00-troubleshooting-index.md