# scale-down-application.md
# 应用临时缩容操作标准化运维手册
## 一、文档定位
本文针对业务低峰、活动结束、故障临时隔离、资源临时回收等场景，提供**Deployment/StatefulSet 人工手动缩容**完整操作流程；区分无状态微服务、有状态中间件差异化操作规范，包含缩容前风险评估、缩容执行、缩容校验、高峰期扩容恢复，配套应用发布、项目验收、下线文档。
前置依赖：
deploy-java-application.md｜无状态Java应用部署
deploy-stateful-application.md｜MySQL/Redis有状态应用部署
validate-project-environment.md｜项目环境资源基线就绪
下游关联：publish-application-release.md、decommission-application.md

## 二、缩容适用场景与风险红线
### 2.1 合法缩容场景
1. 业务夜间低峰：流量暴跌，释放节点资源供其他业务使用
2. 营销活动结束：大促活动结束后临时缩减多余副本
3. 集群资源紧张：临时腾出CPU/内存，保障核心故障业务
4. 版本灰度验证：缩减非核心环境副本，降低资源开销
5. 故障节点替换前分批排空业务（配合replace-worker-node.md）

### 2.2 禁止缩容红线（生产PROD环境严禁操作）
1. 业务高峰期（9:00-21:00 Web/交易业务）
2. 有状态集群仅剩余1副本（MySQL/Redis/ES，防止单节点宕机集群崩溃）
3. 数据库主从集群缩容至无从节点，丢失备份能力
4. 核心支付、订单交易系统，无容灾副本
5. 未配置HPA自动弹性，缩容后无人值守导致流量冲击502

### 2.3 前置风险检查项（缩容前必须校验）
1. 监控大盘QPS持续低位，确认无突发流量预期
2. PROD有状态应用副本≥3，缩容后最低保留2副本
3. 集群剩余资源充足，缩容后无需紧急扩容
4. 已屏蔽缩容相关副本告警，操作完成后恢复
5. 中间件主从复制正常，无同步延迟告警

## 三、核心区分：无状态Deployment vs 有状态StatefulSet
1. **Deployment（Java微服务）**
    缩容直接减少副本数，控制器随机销毁多余Pod，无数据依赖，操作简单；低峰可大幅缩容。
2. **StatefulSet（MySQL/Redis/ES）**
    有序缩容，从最大编号Pod开始销毁（mysql-2→mysql-1）；**不可缩至单副本**，缩容前确认集群副本机制不丢失数据。

## 四、第一部分：无状态Java应用 Deployment 缩容操作
### 4.1 方式1：命令行快速缩容（推荐）
```bash
export NS=prod-business
export APP=app-api
# 目标副本数 3
kubectl scale deployment $APP --replicas=3 -n $NS
```

### 4.2 方式2：编辑yaml永久修改（长期低峰固定副本）
```bash
kubectl edit deployment app-api -n prod-business
spec:
  replicas: 3
```

### 4.3 缩容进度实时监控
```bash
# 实时观察Pod逐步销毁
watch kubectl get pods -n $NS -l app=app-api
# 查看集群事件，排查缩容卡顿
kubectl get events -n $NS --field-selector reason=ScalingReplicaSet
```

### 4.4 缩容完成校验
1. Pod数量等于目标replicas，无多余实例
2. 业务接口访问正常，5xx错误率0
3. 监控QPS、p99延迟平稳无突增

## 五、第二部分：有状态应用 StatefulSet 缩容（MySQL/Redis）
### 5.1 缩容命令
```bash
kubectl scale statefulset mysql --replicas=2 -n prod-db
```
缩容顺序：mysql-2 先销毁 → mysql-1保留，不会销毁主节点mysql-0。

### 5.2 缩容后专项校验（数据库强制）
1. 集群副本仅剩2个，主从复制正常，无同步延迟
```bash
# 进入mysql主节点查看主从状态
kubectl exec -n prod-db mysql-0 -- mysql -uroot -p -e "show slave status\G"
```
2. 读写业务正常，无连接池耗尽报错
3. PVC保留，被销毁Pod的数据目录不删除（Retain策略）

### 5.3 严格约束
生产环境StatefulSet最小副本底线：2，禁止缩容至1。

## 六、DEV / UAT / PROD 三套环境差异化规范
| 环境 | 无状态最低副本 | 有状态最低副本 | 缩容窗口期 |
|------|---------------|---------------|------------|
| DEV | 1 | 1（仅自测） | 任意时间 |
| UAT | 2 | 2 | 工作时段 |
| PROD | 3（核心业务） | 2 | 凌晨低峰00:00-06:00 |

## 七、缩容后恢复扩容操作（流量回升）
```bash
# 恢复至业务标准副本
kubectl scale deployment app-api --replicas=5 -n prod-business
# 监控Pod重建就绪进度
watch kubectl get pods -n prod-business -l app=app-api
# 校验接口QPS分摊正常
```

## 八、高频故障与处理方案
### 故障1：缩容后业务大量502，连接超时
根因：缩容幅度过大，剩余副本无法承载当前流量；未观察QPS直接缩容
处理：立即扩容恢复原有副本，低峰小幅分批缩容

### 故障2：StatefulSet缩容后主从同步中断
根因：销毁从节点后仅剩单实例，无备份节点
规范：生产有状态最低保留2副本，禁止缩容至1

### 故障3：执行scale命令报错，资源Quota不足
根因：当前集群资源已达上限，无法维持目标副本
处理：清理闲置资源或调高Namespace ResourceQuota配额

### 故障4：缩容后Pod长期Terminating无法销毁
根因：Pod存在本地emptyDir/hostPath存储、Finalizer阻塞
处理：强制删除Pod `kubectl delete pod xxx --force --grace-period=0`

### 故障5：缩容完成后磁盘/内存告警依然触发
根因：仅缩容Pod，未清理PVC/日志临时存储
处理：区分计算资源与存储资源，缩容业务不影响持久化磁盘水位

## 九、生产运维标准化规范
1. PROD生产仅允许凌晨低峰窗口执行缩容，白天高峰期禁止操作
2. 核心交易无状态业务最低保留3副本，有状态中间件最低2副本
3. 缩容前完整观测30分钟监控QPS，确认流量持续低位再分批缩容
4. 有状态StatefulSet缩容后必须校验主从/集群副本同步状态
5. 营销大促、活动场景提前扩容，活动结束分批次逐步缩容，禁止一次性大幅缩减
6. 临时缩容必须记录恢复时间，定时巡检自动扩容恢复标准副本
7. 长期低峰业务通过HPA自动弹性替代人工手动缩容（configure-application-autoscaling.md）
8. 项目交付、日常巡检核对副本数，避免长期缩容遗忘引发流量故障

## 十、关联文档索引
deploy-java-application.md 无状态Deployment部署模板
deploy-stateful-application.md 有状态StatefulSet部署规范
configure-application-autoscaling.md HPA自动弹性伸缩
publish-application-release.md 新版本发布副本标准
rollback-application-release.md 故障回滚副本操作
decommission-application.md 应用完整下线销毁流程
validate-project-environment.md 项目环境副本资源验收标准
06-network-debug.md 缩容后业务502、连通故障排查