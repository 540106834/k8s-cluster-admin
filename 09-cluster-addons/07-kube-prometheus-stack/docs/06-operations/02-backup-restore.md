# docs/09-operation/02-backup-restore.md
# 监控平台备份与恢复标准化操作手册
## 基础信息
- 集群：K8s 1.32.0
- 监控栈：kube-prometheus-stack 65.1.0
- 存储介质：NFS Subdir PV（Prometheus/Grafana）
- 交付模式：ArgoCD GitOps
- 适用：SRE运维，覆盖Prometheus TSDB、Grafana、AlertConfig、规则CR、密钥全量备份
- 前置文档：09-operation/01-daily-operation.md

## 目录
1. 备份范围与备份策略分级
2. Prometheus TSDB 快照备份（在线/离线）
3. Grafana 全量数据备份与恢复
4. 配置资源统一备份（CR/CM/Secret/AlertConfig）
5. 定时自动备份脚本（可直接Cron部署）
6. 完整灾难恢复流程（分场景）
7. 备份校验与过期清理规范
8. 恢复后校验验证清单
9. 备份存储容量与保留周期规范
10. 关联文档索引

---

# 1. 备份范围与备份策略分级
## 1.1 必须备份资源清单
### ① 时序存储（核心业务数据）
Prometheus TSDB 时序数据库：业务指标、历史趋势、聚合预计算数据
### ② Grafana 可视化资产
grafana.db SQLite库：账号、组织、权限、所有大盘、数据源配置、告警通知渠道
### ③ 集群配置资源（Git兜底+本地二次备份）
ServiceMonitor/PodMonitor/PrometheusRule/AlertmanagerConfig、监控ConfigMap、RBAC
### ④ 敏感密钥（离线加密存储）
Grafana管理员密码、告警Webhook密钥、数据源数据库账号、OIDC密钥

## 1.2 三级备份策略
1. **实时源码备份（一级，永久留存）**
所有监控YAML存放Git仓库，ArgoCD唯一数据源；所有变更强制提交，作为基准恢复源。
2. **每日定时快照备份（二级，本地NFS备份盘留存30天）**
TSDB快照、Grafana数据库、集群资源导出，每日凌晨2点自动执行。
3. **每周全量异地备份（三级，异地对象存储留存90天）**
每周日凌晨将全量备份包推送至异地存储，应对机房NFS整体故障。

## 1.3 保留周期规范
- 日增量快照：30天，自动滚动删除过期包
- 周全量异地备份：90天，手动清理
- Git代码库：永久版本保存

# 2. Prometheus TSDB 快照备份
## 2.1 在线快照（无需停止Prometheus，生产首选）
Prometheus原生API生成快照，不中断指标写入。
```bash
# 1. 调用API创建快照
curl -X POST http://kube-monitor-prometheus.monitoring.svc:9090/api/v1/admin/tsdb/snapshot
# 2. 查询快照路径（返回snapshot目录名）
curl http://kube-monitor-prometheus.monitoring.svc:9090/api/v1/admin/tsdb/snapshot
# 示例返回快照目录：/prometheus/snapshots/20260802T020000Z-xxxxxx
```
## 2.2 容器内拷贝快照至备份PVC
```bash
# 进入prometheus pod
kubectl exec -it kube-monitor-prometheus-0 -n monitoring -- sh
# 打包快照
tar -zcvf /backup/prom-snap-$(date +%Y%m%d).tar.gz /prometheus/snapshots/20260802T020000Z-xxxxxx
# 清理pod内临时快照文件夹
rm -rf /prometheus/snapshots/20260802T020000Z-xxxxxx
```
## 2.3 离线备份（磁盘故障应急，业务中断场景）
当Prometheus持续OOM/写入异常，停机全量打包DB：
```bash
# 缩容至0副本停止写入
kubectl scale statefulset kube-monitor-prometheus -n monitoring --replicas=0
# 直接打包整个/prometheus数据目录
tar -zcvf prom-full-db-$(date +%Y%m%d).tar.gz /nfs/monitor-prom-db
# 备份完成后扩容恢复
kubectl scale statefulset kube-monitor-prometheus -n monitoring --replicas=2
```

## 2.4 TSDB快照恢复流程
1. 停止Prometheus实例（缩容副本为0）
2. 删除原有损坏/pvc内/prometheus目录全部文件
3. 解压快照包至PVC挂载目录
```bash
tar -zxvf prom-snap-20260802.tar.gz -C /nfs/monitor-prom-db/
```
4. 赋予目录权限（prometheus运行用户uid=65534）
```bash
chown -R 65534:65534 /nfs/monitor-prom-db
```
5. 扩容副本启动，访问UI校验时序数据完整

# 3. Grafana 全量数据备份与恢复
## 3.1 在线备份grafana.db（无需重启Grafana）
```bash
# 直接从Pod拷贝SQLite数据库至本地备份路径
kubectl cp kube-monitor-grafana-7f96c8d76-2xq9l:/var/lib/grafana/grafana.db \
/nfs/backup/grafana/grafana-$(date +%Y%m%d).db -n monitoring
```
## 3.2 Grafana数据库恢复
1. 滚动重启Grafana停止写入：
```bash
kubectl rollout stop deployment kube-monitor-grafana -n monitoring
```
2. 拷贝备份库覆盖原有文件
```bash
kubectl cp /nfs/backup/grafana/grafana-20260802.db \
kube-monitor-grafana-7f96c8d76-2xq9l:/var/lib/grafana/grafana.db -n monitoring
```
3. 修复文件权限
```bash
kubectl exec -it deploy/kube-monitor-grafana -n monitoring -- chown grafana:grafana /var/lib/grafana/grafana.db
```
4. 恢复Deployment运行
```bash
kubectl rollout resume deployment kube-monitor-grafana -n monitoring
```
5. 登录Grafana校验：账号、大盘、数据源全部存在

## 3.3 大盘独立导出备份（补充方案）
批量导出所有看板JSON，存放Git，作为轻量恢复兜底：
```bash
# 安装grafana cli工具批量导出，或页面手动导出
grafana-cli admin export all-dashboards --path ./grafana-dashboards
```

# 4. 集群监控配置资源导出备份
## 4.1 一次性导出所有监控CR（ServiceMonitor/PodMonitor/PrometheusRule）
```bash
mkdir -p /nfs/backup/k8s-monitor-cr/$(date +%Y%m%d)
# 导出全命名空间ServiceMonitor
kubectl get servicemonitor -A -o yaml > /nfs/backup/k8s-monitor-cr/$(date +%Y%m%d)/servicemonitors.yaml
# 导出PodMonitor
kubectl get podmonitor -A -o yaml > /nfs/backup/k8s-monitor-cr/$(date +%Y%m%d)/podmonitors.yaml
# 导出告警规则
kubectl get prometheusrule -A -o yaml > /nfs/backup/k8s-monitor-cr/$(date +%Y%m%d)/prometheusrules.yaml
# 导出AlertmanagerConfig
kubectl get alertmanagerconfig -n monitoring -o yaml > /nfs/backup/k8s-monitor-cr/$(date +%Y%m%d)/alertconfig.yaml
# 导出监控命名空间ConfigMap/Secret
kubectl get cm -n monitoring -o yaml > /nfs/backup/k8s-monitor-cr/$(date +%Y%m%d)/monitor-cm.yaml
kubectl get secret -n monitoring -o yaml > /nfs/backup/k8s-monitor-cr/$(date +%Y%m%d)/monitor-secret.yaml
```
## 4.2 CR资源恢复（两种方式）
1. **优先方案（推荐）**：从Git仓库同步，ArgoCD重新应用，配置与密钥自动下发
2. **应急兜底**：使用导出yaml直接apply（仅Git仓库损坏时使用）
```bash
kubectl apply -f /nfs/backup/k8s-monitor-cr/20260802/
```

# 5. 定时自动备份脚本（可部署CronJob）
## 5.1 每日备份脚本 backup-monitor.sh
```bash
#!/bin/bash
DATE=$(date +%Y%m%d)
BACKUP_ROOT=/nfs/monitor-backup
mkdir -p ${BACKUP_ROOT}/prometheus ${BACKUP_ROOT}/grafana ${BACKUP_ROOT}/k8s-cr

# 1. Prometheus TSDB快照备份
SNAP_RESP=$(curl -s -X POST http://kube-monitor-prometheus.monitoring.svc:9090/api/v1/admin/tsdb/snapshot)
SNAP_PATH=$(echo $SNAP_RESP | jq -r '.data.name')
kubectl exec kube-monitor-prometheus-0 -n monitoring -- tar -zcvf /tmp/prom-${DATE}.tar.gz /prometheus/snapshots/${SNAP_PATH}
kubectl cp kube-monitor-prometheus-0:/tmp/prom-${DATE}.tar.gz ${BACKUP_ROOT}/prometheus/ -n monitoring

# 2. Grafana db备份
kubectl cp deploy/kube-monitor-grafana:/var/lib/grafana/grafana.db ${BACKUP_ROOT}/grafana/grafana-${DATE}.db -n monitoring

# 3. K8s监控CR导出
kubectl get servicemonitor,podmonitor,prometheusrule,alertmanagerconfig -A -o yaml > ${BACKUP_ROOT}/k8s-cr/cr-all-${DATE}.yaml

# 4. 自动清理30天前备份包
find ${BACKUP_ROOT} -name "*.tar.gz" -o -name "*.db" -mtime +30 -delete
```
## 5.2 集群内定时CronJob部署
封装为CronJob，每日02:00自动执行，输出至NFS备份盘。

# 6. 分场景完整灾难恢复流程
## 场景1：Grafana数据库损坏，时序数据完好
1. 停止Grafana Deployment
2. 使用最近grafana.db备份覆盖
3. 修复文件权限，重启Grafana
4. 校验大盘、数据源、告警渠道、账号权限

## 场景2：Prometheus NFS存储故障，时序数据丢失
1. 新建空白Prometheus PVC
2. 解压最近TSDB快照至新PVC目录，修正权限
3. 启动Prometheus StatefulSet
4. UI校验历史指标曲线、预聚合Record指标完整
5. 校验告警规则正常执行，无Rule Err

## 场景3：监控CR全部误删除（Git仓库完好）
1. 无需本地备份，直接在ArgoCD界面点击Sync同步Git代码
2. 等待控制器重建所有ServiceMonitor/PodMonitor/PrometheusRule
3. Prometheus Targets页面确认采集目标全部UP

## 场景4：Git仓库丢失，仅留存本地CR备份
1. 新建临时命名空间，apply本地导出CR全量yaml
2. 手动重建ArgoCD应用，将导出YAML重新提交至新Git仓库
3. 切换生产环境至新Git仓库源

## 场景5：整机机房故障（异地全量恢复）
1. 拉取异地存储最新周全量备份包
2. 先恢复K8s CR配置，再恢复Grafana库，最后恢复Prometheus TSDB
3. 校验采集、告警、大盘全链路可用性

# 7. 备份校验规范（每日备份后自动校验）
## 7.1 TSDB备份校验
解压快照包执行tsdb完整性检测：
```bash
tar -zxvf prom-20260802.tar.gz
promtool tsdb check ./snapshots/xxx
```
返回`DB is OK`代表备份有效。

## 7.2 Grafana数据库校验
```bash
# 检查SQLite文件无损坏
sqlite3 grafana-20260802.db "PRAGMA integrity_check;"
```
返回`ok`为正常。

## 7.3 CR资源校验
```bash
# 校验yaml语法无错误
kubectl apply --dry-run=client -f cr-all-20260802.yaml
```
无语法报错代表备份文件可用。

# 8. 恢复后完整校验清单
1. Prometheus
   - StatefulSet副本正常运行无重启
   - TSDB无报错，历史指标7/30天曲线完整
   - Targets采集目标UP率100%
   - Rules页面无Err，Record/Alert规则正常计算
2. Grafana
   - 所有大盘正常加载无数据源报错
   - 业务账号、权限、组织完整
   - 告警通知渠道可正常测试发送
3. 告警链路
   - Alertmanager配置加载正常
   - 模拟异常指标可正常触发钉钉/企微告警
4. 采集CR
   - 全业务ServiceMonitor/PodMonitor正常识别

# 9. 备份存储容量规划与清理
1. 单天TSDB快照：约为当前时序数据10%-20%
2. Grafana数据库：稳定500MB以内
3. 30天日备份总容量预估：<100GB
4. 自动清理规则：脚本内置`find -mtime +30`删除过期日备份
5. 每周异地备份人工复核，90天手动清理

# 10. 关联文档索引
1. 监控平台日常运维：09-operation/01-daily-operation.md
2. Prometheus TSDB调优与存储：04-workload/01-prometheus.md
3. GitOps变更发布规范：10-best-practice/gitops-cicd.md
4. 集群NFS存储运维手册：03-storage/01-nfs-pv.md
5. 故障排查总目录：09-troubleshooting/00-troubleshooting-index.md