# backup‑restore.md
## 1 环境基线
- Kubernetes‑v1.32、containerd
- 采集组件：Fluent‑Bit
- 缓冲组件：Kafka
- 存储引擎：Loki / Elasticsearch / ClickHouse
- 存储介质：本地SSD、NFS‑SC动态存储类
- 文档范围：采集配置、Kafka消息、三类日志存储、Grafana面板、告警规则全套备份策略、定时备份、灾难恢复、跨环境迁移操作

## 2 整体备份架构
备份对象分为五层，分层独立执行备份任务
1. 配置层：Fluent‑Bit流水线、Kafka配置、存储组件参数、PrometheusRule告警、Grafana仪表盘（Git作为永久基线，定时导出快照）
2. 消息缓冲层：Kafka Topic消息快照
3. Loki：Chunk数据、标签索引、compactor元数据
4. Elasticsearch：索引快照
5. ClickHouse：数据表分区备份

> 优先Git托管所有配置文件；定时备份作为故障兜底手段。

## 3 Fluent‑Bit采集端配置备份
1. 所有input、parser、filter、output配置存放于Git仓库，ArgoCD同步管理
2. 定时导出集群内部ConfigMap配置作为快照备份
```bash
kubectl get configmap -n logging-agent -o yaml > fluent-bit-config-$(date +%Y%m%d).yaml
```
3. 备份清单：脱敏规则、日志过滤策略、磁盘缓冲参数、Kafka‑Topic路由配置

### 恢复流程
1. 使用ArgoCD同步Git配置；
2. 手动重建ConfigMap；
3. 发送SIGHUP信号实现Fluent‑Bit热重载配置，无需重启Pod。

## 4 Kafka集群备份与恢复
Kafka消息仅短期缓冲，一般不需要长期持久备份；针对审计日志Topic开启快照备份
### 备份方案
1. 开启主题分区副本高可用（审计日志副本数=3）
2. 使用kafka‑mirror‑maker2做Topic镜像备份
3. 定时导出broker配置、ACL权限、用户账号
### 灾难恢复
1. 单Broker故障：依靠分区副本自动完成Leader切换
2. 集群整体故障：从镜像Topic恢复日志消息；丢失窗口期日志由上层业务重新生成

## 5 Loki 备份与恢复
### 备份对象
Chunk压缩日志块、标签索引、Compactor元数据、告警规则、查询面板
### 备份方式
1. 底层PVC存储快照（NFS存储直接目录拷贝）
2. 开启对象存储后端，Chunk自动持久化至远端存储
3. 定时导出Loki‑runtime配置、limits限制、告警PrometheusRule
### 手动快照示例
```bash
# 拷贝ingester持久化目录
cp -r /nfs/loki-ingester/* /backup/loki/$(date +%Y%m%d)/
```
### 恢复步骤
1. 停止Ingester、Compactor组件
2. 将Chunk备份目录还原至PVC存储路径
3. 启动组件，重建标签索引
4. 校验标签基数、日志Chunk完整性，Grafana执行日志查询验证

## 6 Elasticsearch 索引快照备份
### 快照仓库配置
注册远端快照仓库（NFS路径或者对象存储）
```json
PUT /_snapshot/log_backup
{
  "type": "fs",
  "settings": {
    "location": "/nfs/es-snapshot"
  }
}
```
### 创建快照
```json
PUT /_snapshot/log_backup/snap-20260805
{
  "indices": ["container-log-*"],
  "ignore_unavailable": true
}
```
### 索引恢复
```json
POST /_snapshot/log_backup/snap-20260805/_restore
```
### 运维规范
1. 每日凌晨执行一次全量快照
2. 过期快照定时清理，保留最近7天备份文件

## 7 ClickHouse 分区备份与恢复
ClickHouse最小数据单元为分区，基于分区进行备份
### 分区备份
1. 冷分区直接拷贝分区目录
2. 使用ALTER TABLE DETACH PARTITION卸载分区，拷贝至备份目录
```sql
-- 卸载分区
ALTER TABLE container_log DETACH PARTITION '20260801';
```
### 分区恢复
```sql
-- 将分区文件放回数据表目录之后挂载分区
ALTER TABLE container_log ATTACH PARTITION '20260801';
```
### 全量备份
定时对数据表PVC目录做快照备份；审计数据表优先多副本部署。

## 8 Grafana、告警资源备份
1. Grafana仪表盘导出JSON文件存入Git仓库
2. 备份数据源配置、账号权限、文件夹结构
3. 备份PrometheusRule日志告警规则、ServiceMonitor资源
```bash
kubectl get prometheusrule -n logging-storage -o yaml > alert-rule.yaml
```

## 9 定时备份周期标准
|备份对象|备份周期|备份文件保存时长|
|---|---|---|
|所有配置资源|实时Git托管+每日快照|永久|
|Loki Chunk快照|每日凌晨|30天|
|Elasticsearch索引快照|每日凌晨|30天|
|ClickHouse分区备份|每日凌晨|90天（审计日志）|
|Kafka配置、ACL|每日|30天|

## 10 灾难分级恢复方案
### 级别1：单Pod异常
组件副本自动故障转移；无需执行备份恢复
### 级别2：PVC存储损坏
从当日快照还原数据，校验日志完整性；Kafka缓冲内的消息自动补发写入存储
### 级别3：整套日志平台销毁
1. 重建整套日志平台资源
2. 恢复Fluent‑Bit、Kafka配置
3. 依次还原 Loki / ES / ClickHouse 备份数据
4. 恢复Grafana面板、告警规则
5. 开启采集流水线，恢复日志采集链路

## 11 备份最佳实践
1. 配置优先使用Git作为第一备份，快照仅用于灾难兜底
2. 业务日志、系统日志、审计日志三套存储分开备份，审计日志备份周期拉长
3. 备份文件和业务存储介质物理隔离，避免磁盘故障同时损坏数据与备份
4. 定期执行恢复演练，验证备份文件可用性
5. 备份任务纳入监控，备份失败触发告警通知

## 12 常见故障点
1. NFS快照拷贝时Chunk/索引文件处于写入状态，备份文件损坏；优先低峰期执行备份
2. ClickHouse正在写入的热分区不能直接拷贝，需要先卸载分区
3. Loki标签索引损坏，只需要还原Chunk，后台Compactor自动重建索引

## 13 后续文档指引
daily‑operation.md 日志平台日常巡检、告警处理、日常运维规范