# docs/02-deployment/03-upgrade.md
# kube-prometheus-stack Helm 版本升级操作手册
## 文档基础信息
- K8s 集群：v1.32（锁定集群版本，不随Chart升级变动）
- 当前Chart基线：kube-prometheus-stack-65.1.0
- 存储：NFS StorageClass `nfs-sc` 持久化PVC
- Chart源：离线MinIO存储tgz包
- 配置管理：Git仓库统一管理values、CRD、大盘模板
- 文档等级：★★★★★ 核心运维文档
- 前置阅读：01-installation.md、02-configuration.md

## 目录
1. 升级前置约束与版本兼容规则
2. 升级前风险评估与备份流程
3. 离线Chart新版本获取（MinIO上传流程）
4. 升级预校验（dry-run、语法、存储、CRD）
5. 标准Helm Upgrade完整执行步骤
6. 升级后全链路验证清单
7. 升级异常回滚流程（helm rollback）
8. 跨大版本升级特殊处理（CRD手动更新）
9. 日常小配置热更新流程（无需Chart版本变更）
10. 升级变更管理规范（GitOps）
11. 关联文档索引

---

## 1. 升级前置约束与版本兼容规则
### 1.1 硬性约束（禁止违反）
1. **集群K8s版本锁定v1.32**，升级Chart前必须核对Chart兼容K8s版本，不兼容则禁止升级；
2. 仅支持**同大版本小幅迭代**（如65.1.0 → 65.2.0）；跨主版本（65→66）属于重大变更，需单独评审、停机窗口；
3. 所有有状态组件（Prometheus/Alertmanager/Grafana）使用`nfs-sc`持久卷，升级不会丢失时序数据/面板配置；
4. 离线环境无外网helm repo，新版本Chart包必须手动上传MinIO；
5. 禁止直接`kubectl edit`集群内监控资源，所有变更通过Git values+helm upgrade下发。

### 1.2 版本兼容核查要点
1. 查阅Chart官方Changelog，确认CRD字段、Prometheus/Alertmanager/Grafana镜像破坏性变更；
2. 核对新版本是否废弃旧字段（如存储配置、serviceMonitor筛选、告警路由参数）；
3. 确认新版本容器镜像架构兼容集群节点OS；
4. 跨主版本升级必须单独执行CRD手动替换步骤。

### 1.3 升级窗口要求
- 小版本迭代（patch/minor）：低峰业务时段执行，无需停机窗口；
- 跨主版本Major升级：预留30分钟维护窗口，提前下发业务通知。

---

## 2. 升级前风险评估与全量备份流程
### 2.1 备份清单（升级前必执行）
#### 2.1.1 Git配置备份（基准配置固化）
```bash
cd /opt/kube-monitor
git pull origin main
# 新建tag标记当前稳定基线版本
git tag -a monitor-v65.1.0 -m "基线Chart 65.1.0 稳定版本"
git push origin --tags
```

#### 2.1.2 集群当前helm发布配置备份
```bash
# 导出当前生效values
helm get values kube-monitor -n monitoring > ./backup/values-65.1.0-bak.yaml
# 导出完整渲染资源清单
helm get manifest kube-monitor -n monitoring > ./backup/manifest-65.1.0-bak.yaml
# 导出所有监控CRD资源（ServiceMonitor/PodMonitor/PrometheusRule）
kubectl get servicemonitor,podmonitor,prometheusrule -n monitoring -o yaml > ./backup/crd-monitor-bak.yaml
# 导出Grafana所有大盘ConfigMap
kubectl get configmap -n monitoring -l dashboard=grafana -o yaml > ./backup/grafana-dash-bak.yaml
```

#### 2.1.2 持久化数据备份（NFS层）
登录NFS服务端，对Prometheus/Alertmanager/Grafana对应PVC目录打快照/压缩备份：
```bash
# NFS服务端示例，根据实际挂载路径调整
tar -zcvf prometheus-tsdb-bak-$(date +%Y%m%d).tgz /nfs/monitor/pvc-prometheus
tar -zcvf alertmanager-bak-$(date +%Y%m%d).tgz /nfs/monitor/pvc-alertmanager
tar -zcvf grafana-bak-$(date +%Y%m%d).tgz /nfs/monitor/pvc-grafana
```

### 2.2 风险评估检查项
1. 检查Prometheus当前抓取target是否全UP，无大量失联指标；
2. 确认PVC全部Bound，NFS服务端读写无延迟、磁盘水位＜80%；
3. 确认无未恢复的监控告警（节点异常、存储满、采集失败）；
4. 确认Harbor存在新版本全部组件离线镜像，缺失则先导出导入镜像。

---

## 3. 离线Chart新版本获取（MinIO上传流程）
### 3.1 外网机器下载目标版本Chart
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm pull prometheus-community/kube-prometheus-stack --version 65.2.0
```

### 3.2 上传至离线MinIO Chart桶
```bash
mc cp kube-prometheus-stack-65.2.0.tgz minio-monitor/charts/
# 校验上传结果
mc ls minio-monitor/charts/
```

### 3.3 内网部署机器拉取新版本Chart包
```bash
helm repo update minio-charts
# 检索确认版本存在
helm search repo minio-charts/kube-prometheus-stack --versions
# 拉取至本地目录
mkdir -p /opt/monitor-chart
helm pull minio-charts/kube-prometheus-stack --version 65.2.0 -d /opt/monitor-chart
tar -zxvf /opt/monitor-chart/kube-prometheus-stack-65.2.0.tgz -C /opt/monitor-chart/
```

---

## 4. 升级预校验（必须全部通过才可执行真实升级）
### 4.1 配置文件语法校验
```bash
yamllint ./values/*.yaml
```

### 4.2 Dry-run 渲染预发布（核心校验步骤）
```bash
NEW_CHART="/opt/monitor-chart/kube-prometheus-stack"
cd /opt/kube-monitor
helm upgrade kube-monitor ${NEW_CHART} \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml \
--version 65.2.0 \
--dry-run --debug > dry-run-output.log
```
校验要点：
1. 无YAML语法报错、字段废弃警告；
2. PVC存储配置`nfs-sc`未丢失；
3. 镜像仓库`harbor.example.com/library`未被重置为外网；
4. Secret引用（grafana-admin、alert-webhook-secret）配置正常；
5. 副本数、资源限制、采集筛选规则与预期一致。

### 4.3 CRD兼容性校验
dry-run日志检索`CustomResourceDefinition`，确认新版本CRD无破坏性字段删除；
跨主版本升级需手动对比新旧CRD yaml。

### 4.4 镜像存在性校验
提取dry-run中所有image地址，批量校验Harbor镜像存在：
```bash
# 示例检查单镜像
skopeo inspect docker://harbor.example.com/library/prometheus:v2.50.0
```

---

## 5. 标准Helm Upgrade完整执行步骤（同大版本小幅升级）
### 5.1 执行升级命令
```bash
NEW_CHART="/opt/monitor-chart/kube-prometheus-stack"
cd /opt/kube-monitor
helm upgrade kube-monitor ${NEW_CHART} \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml \
--version 65.2.0
```

### 5.2 等待组件滚动更新完成
```bash
kubectl get pods -n monitoring -w
```
滚动更新行为说明：
1. Prometheus Operator Deployment：滚动重建，无数据影响；
2. node-exporter DaemonSet：逐节点滚动，节点监控短暂中断数秒；
3. Prometheus/Alertmanager StatefulSet：HA双副本顺序重建，单副本存活保证采集不中断；
4. Grafana Deployment：滚动更新，面板临时不可访问10~30秒。

### 5.3 查看helm发布修订记录
```bash
helm history kube-monitor -n monitoring
# 输出新增REVISION编号，标记新版本
```

---

## 6. 升级后全链路验证清单（逐项核对）
### 6.1 组件基础状态校验
1. 所有Pod状态Running，无CrashLoopBackOff、ImagePullBackOff；
2. StatefulSet/Deployment/DaemonSet副本数与values配置一致；
3. PVC保持Bound，挂载`nfs-sc`不变；
4. CRD资源定义更新至新版本；

### 6.2 Prometheus采集校验
1. 访问Prometheus UI `/targets`，所有exporter、kubelet采集目标UP；
2. 历史时序数据完整（删除Pod重建后NFS持久化数据保留）；
3. RecordingRule、AlertRule全部加载无报错；
4. 自监控指标正常采集。

### 6.3 Alertmanager校验
1. 告警路由、分组、抑制规则生效；
2. 测试告警可正常推送至钉钉/企业微信；
3. 历史静默配置未丢失。

### 6.4 Grafana可视化校验
1. HTTPS Ingress正常访问，管理员账号登录正常；
2. Prometheus数据源自动连接成功；
3. 内置大盘、Git自定义业务大盘完整加载；
4. 面板历史查询无缺失指标。

### 6.5 基础设施采集校验
node-exporter、kube-state-metrics指标完整，节点资源、K8s元数据无缺失。

### 6.6 持续观测30分钟
监控以下指标无异常突降：
- prometheus_tsdb_head_samples_appended_total 指标写入速率
- scrape_samples_scraped 抓取样本量
- alertmanager_notifications_sent_total 告警发送量

---

## 7. 升级异常回滚流程（故障无法修复时执行）
### 7.1 快速回滚（基于helm revision）
```bash
# 查看历史修订
helm history kube-monitor -n monitoring
# 回滚至上一个稳定版本（REVISION编号）
helm rollback kube-monitor 1 -n monitoring
# 等待Pod回滚重建完成
kubectl get pods -n monitoring -w
```

### 7.2 回滚后校验
1. 确认所有组件回退至原Chart镜像版本；
2. 采集、告警、Grafana功能恢复；
3. 若回滚后配置异常，使用升级前备份crd/values手动修复。

### 7.3 极端场景回滚（helm rollback失效）
1. 卸载当前release（保留PVC持久数据）
```bash
helm uninstall kube-monitor -n monitoring --keep-history
```
2. 使用基线旧Chart包+备份values重新install
```bash
helm install kube-monitor /opt/monitor-chart/kube-prometheus-stack-65.1.0 \
-n monitoring \
-f ./backup/values-65.1.0-bak.yaml
```
3. 重新应用备份CRD、Grafana大盘ConfigMap。

---

## 8. 跨大版本Major升级特殊处理（65.x → 66.x）
跨主版本CRD结构存在破坏性变更，helm upgrade不会自动更新CRD，需手动操作：
1. 升级前备份全部CRD（2.1.2章节备份命令）；
2. 解压新版本Chart，提取新版CRD清单：
   ```bash
   cp /opt/monitor-chart/kube-prometheus-stack/crds/*.yaml ./crd/new-crd/
   ```
3. 手动应用新版CRD，覆盖集群旧定义：
   ```bash
   kubectl apply -f ./crd/new-crd/
   ```
4. 执行helm upgrade完整流程；
5. 升级完成校验CRD版本、字段兼容性，业务监控资源无丢失。

> 风险提示：跨版本CRD替换可能导致临时监控采集中断，必须预留维护窗口。

---

## 9. 日常小配置热更新流程（无需升级Chart版本）
仅修改values参数（资源扩容、调整抓取间隔、新增告警路由），Chart版本不变，流程简化：
1. 修改Git仓库values文件，提交推送；
2. 执行dry-run预校验；
3. 执行helm upgrade，Chart路径、版本号保持不变；
4. 验证组件滚动更新、功能正常；
无需重新上传MinIO Chart包、无需替换CRD。

示例命令：
```bash
helm upgrade kube-monitor /opt/monitor-chart/kube-prometheus-stack-65.1.0 \
-n monitoring \
-f ./values/values-base.yaml \
-f ./values/values-prod.yaml
```

---

## 10. 升级变更管理规范（GitOps强制标准）
1. 所有版本升级操作记录提交Git，更新文档内Chart基线版本；
2. 变更日志必填内容：升级前后版本、变更原因、维护窗口时长、风险点、验证结果；
3. 升级完成后打上Git Tag固化稳定基线；
4. 升级失败回滚需记录故障根因，同步更新故障排查文档`09-troubleshooting/01-install-error.md`；
5. 禁止无dry-run校验直接执行upgrade操作。

---

## 11. 关联文档索引
1. 离线安装基础流程：01-installation.md
2. values完整配置说明：02-configuration.md
3. 存储持久化设计：03-storage/01-storage-design.md
4. 安装/升级故障排查：09-troubleshooting/01-install-error.md
5. 平台资源容量规划：10-best-practices/01-resource-planning.md
6. 监控组件日常运维：06-operations/01-daily-operation.md