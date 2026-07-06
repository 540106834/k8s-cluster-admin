# 09-rollout-and-rollback.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`03-deployment-management.md`、`04-stateful-workloads.md`、`08-workload-scaling.md`
- 集群环境：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：滚动更新原理、发布暂停/恢复、版本历史、回滚、负载重启、灰度分批更新、发布流程规范、发布故障处理

## 二、Rollout 底层核心理论
### 2.1 适用控制器
支持 rollout 完整生命周期操作：`Deployment` / `StatefulSet` / `DaemonSet`
Job/CronJob 无滚动发布机制，每次执行全新Pod。

### 2.2 触发滚动更新的变更条件
修改 `spec.template` 下任意字段都会触发 rollout：
1. 容器镜像版本变更
2. 环境变量 env / ConfigMap / Secret 挂载内容变更
3. 探针参数、资源 requests/limits、lifecycle 钩子修改
4. 容器命令 command、端口、存储卷挂载变更

仅修改副本数、HPA、标签、annotations 不会触发滚动更新。

### 2.3 版本存储机制
每次滚动更新生成一条 revision，保存在控制器内部；
通过 `revisionHistoryLimit` 控制保留历史版本数量，用于故障回滚。
- FAT：保留5条
- UAT/PROD：强制保留10条

### 2.4 两种更新策略对比
1. **RollingUpdate（全环境推荐）**
   逐步新建就绪Pod，再销毁旧Pod，业务零中断；通过 `maxSurge` / `maxUnavailable` 控制更新节奏。
2. **Recreate（生产禁止）**
   先全部删除旧Pod，再新建，业务完全中断，仅本地DEV临时调试使用。

### 2.5 StatefulSet 独有 partition 灰度机制
通过 `partition=N` 实现分批灰度发布：仅更新序号≥N的Pod，先更新从节点，最后更新主节点，规避中间件停机风险。

## 三、标准发布全流程（声明式优先）
### 3.1 方式1：yaml文件更新（版本管理推荐）
1. 修改yaml镜像/配置；
2. 执行声明式提交：
```bash
kubectl apply -f deploy-order-prod.yaml -n prod
```
3. 实时观测发布进度：
```bash
kubectl rollout status deploy order-api -n prod -w
```

### 3.2 方式2：命令行快速更新镜像（临时调试）
```bash
kubectl set image deploy order-api order-api=harbor.jinshaoyong.com/k8s/order:v1.2.0 -n prod
```

### 3.3 查看发布历史记录
```bash
# 查看所有历史版本
kubectl rollout history deploy order-api -n prod
# 查看某一条revision完整变更详情
kubectl rollout history deploy order-api --revision=3 -n prod
```

## 四、发布暂停、恢复（大版本灰度窗口期）
### 4.1 暂停滚动更新
适用于发布一半发现异常，立即停止继续新建Pod：
```bash
kubectl rollout pause deploy order-api -n prod
```
暂停后无法触发新的滚动更新，所有spec.template修改不会生效。

### 4.2 恢复滚动更新
```bash
kubectl rollout resume deploy order-api -n prod
```

## 五、版本回滚（线上故障核心操作）
### 5.1 快速回滚至上一个稳定版本
```bash
kubectl rollout undo deploy order-api -n prod
```

### 5.2 指定回滚至某一历史revision
```bash
kubectl rollout undo deploy order-api --to-revision=2 -n prod
```

### 5.3 StatefulSet 灰度分批回滚
先调整partition从高序号往低序号回滚，最后恢复主节点：
```bash
# 仅回滚序号2、3副本
kubectl patch sts mysql -n prod -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
# 确认从节点正常后，再全量回滚
kubectl patch sts mysql -n prod -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
```

## 六、负载重启（重载配置/环境变量）
ConfigMap/Secret内容变更不会自动触发滚动更新，需手动重启Pod加载新配置：
```bash
# Deployment重启
kubectl rollout restart deploy order-api -n prod
# StatefulSet重启
kubectl rollout restart sts mysql -n prod
# DaemonSet节点采集组件重启
kubectl rollout restart ds filebeat -n kube-system
```
底层逻辑：新增revision，触发全量滚动重建Pod，重新挂载最新配置。

## 七、分环境发布规范（DEV/FAT/UAT/PROD）
### DEV本地
- 无严格流程，可使用Recreate策略，无需留存多版本历史；
- 无需双人复核，随时重启/回滚。

### FAT测试
- 统一RollingUpdate，maxUnavailable=0；
- revisionHistoryLimit=5；
- 发布失败可直接回滚，无需备份。

### UAT预生产
- 对齐生产更新参数，maxSurge=1,maxUnavailable=0；
- revisionHistoryLimit=10；
- 发布前导出资源yaml备份，验证完整业务流程后再上线生产。

### PROD生产（强约束）
1. 仅允许RollingUpdate，`maxUnavailable:0` 保障更新期间副本不减少；
2. revisionHistoryLimit固定10，留存至少10条历史用于紧急回滚；
3. 中间件StatefulSet必须使用partition灰度分批更新；
4. 发布窗口限定业务低峰，操作双人复核；
5. 发布前导出部署yaml备份，核心业务变更前执行etcd快照；
6. 发布过程中监控接口成功率、错误率，异常立即pause+undo回滚；
7. 禁止使用Recreate停机更新策略。

## 八、StatefulSet 灰度分批发布实操（生产中间件专用）
```yaml
# sts更新策略模板
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    partition: 2
```
操作步骤：
1. partition=2：仅更新序号2副本（从节点），验证同步正常；
2. partition=1：更新序号1从节点；
3. partition=0：最后更新序号0主节点；
全程可随时pause、undo，避免主库直接重启引发业务雪崩。

## 九、发布故障快速处理
### 9.1 滚动更新卡住，新Pod无法就绪
1. 执行 `kubectl describe deploy xxx` 查看事件；
2. 高频诱因：readiness探针失败、镜像拉取失败、配置缺失、数据库连接失败；
3. 临时pause停止发布，修复问题后resume或直接undo回滚。

### 9.2 新版本存在严重bug，紧急回滚
1. 立即 `rollout pause` 阻断新增Pod；
2. `rollout undo` 快速切回上一稳定版本；
3. 导出故障版本日志定位问题。

### 9.3 ConfigMap更新后配置不生效
单纯修改CM不会触发rollout，执行 `rollout restart` 重建Pod加载新配置。

### 9.4 历史revision丢失无法回滚
revisionHistoryLimit数值过小，旧版本自动清理；生产调大至10，定期导出yaml离线备份。

### 9.5 StatefulSet更新全部Pod同时重启
partition=0，未开启灰度分批；调整partition分步更新。

### 9.6 发布过程大量5xx报错
readiness探针initialDelaySeconds太短，Pod未就绪就接入流量；调大探针初始延迟。

## 十、完整生产发布标准操作流程
1. 发布前：导出当前部署yaml备份、确认Harbor镜像存在、核对资源Quota充足；
2. 低峰窗口执行apply更新；
3. rollout status实时观测滚动进度；
4. 监控业务指标（QPS、错误率、响应耗时）；
5. 异常：pause暂停 → undo回滚；
6. 正常：等待全部Pod就绪，留存发布记录；
7. 核心中间件：采用partition灰度分步更新，分多阶段验证。

## 十一、运维速查命令汇总
```bash
# 查看发布进度
kubectl rollout status deploy xxx -n prod -w

# 查看历史版本列表
kubectl rollout history deploy xxx -n prod

# 查看单条版本详情
kubectl rollout history deploy xxx --revision=3 -n prod

# 暂停发布
kubectl rollout pause deploy xxx -n prod

# 恢复发布
kubectl rollout resume deploy xxx -n prod

# 回滚上一版本
kubectl rollout undo deploy xxx -n prod

# 指定版本回滚
kubectl rollout undo deploy xxx --to-revision=2 -n prod

# 重载配置重启负载
kubectl rollout restart deploy xxx -n prod
```

## 十二、关联文档
1. 无状态负载：`03-deployment-management.md` RollingUpdate策略配置
2. 有状态中间件：`04-stateful-workloads.md` partition灰度更新机制
3. Pod健康保障：`02-pod-lifecycle.md` readiness探针控制发布流量接入
4. 弹性伸缩：`08-workload-scaling.md` 发布期间HPA联动扩容保障容量
5. 资源防护：`07-resource-management.md` 发布前配额校验
6. 故障汇总：`10-workload-troubleshooting.md` 发布卡死、Pod就绪失败排错