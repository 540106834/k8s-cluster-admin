# cleanup-application-resources.md
# 业务残留资源批量清理标准化操作手册
## 一、文档定位
本文针对业务下线、版本迭代、测试废弃场景，用于**清理项目Namespace内孤立、废弃、残留K8s资源**；区分临时清理（保留业务主体）、全量清理（仅保留命名空间基线）、彻底销毁（配合decommission-application.md），批量清理Pod、RS、PVC、ConfigMap、Secret、监控资源，清理后校验无垃圾资源残留，减少集群资源占用。
前置依赖：
deploy-java-application.md / deploy-stateful-application.md｜业务部署资源规范
disable-application-service.md｜流量关停前置操作
decommission-application.md｜应用永久下线完整流程
下游关联：validate-project-environment.md、scale-down-application.md

## 二、清理场景划分与边界区分
### 1. 迭代临时清理（日常开发/发布）
仅清理发布残留ReplicaSet、异常终止Pod、临时测试PVC，**保留Deployment/StatefulSet、Service、Ingress、基线配额/网络策略**。
适用：版本滚动发布后旧副本集、DEV临时调试Pod、过期测试PVC。

### 2. 业务停用全量清理（项目暂存，不删除Namespace）
业务暂停使用，清空所有业务运行资源，**仅保留Namespace基线资源（LimitRange/ResourceQuota/default-deny NetworkPolicy/镜像拉取Secret）**。
适用：UAT项目暂停、业务迁移过渡期、季节性下线但后续复用命名空间。

### 3. 永久下线彻底清理（配合decommission）
清空所有业务资源+基线资源，最后删除Namespace，不可逆。

### 清理红线禁止行为
1. 禁止未备份Secret、数据库PVC直接全量清理生产资源；
2. 禁止批量删除Namespace全局基线资源（Quota、LimitRange）；
3. 生产环境禁止一键批量删除所有PVC，必须人工核对数据是否无用。

## 三、前置校验（执行清理前必做）
1. 业务流量已关停，Ingress/LB无访问流量（disable-application-service.md）；
2. 确认待清理资源无上下游业务依赖，无运行中业务Pod；
3. 生产有状态应用PVC提前完成异地数据备份；
4. 区分清理范围：仅清理业务资源，不触碰命名空间基线管控资源；
5. 记录待清理资源清单，清理完成后复核。

## 四、第一部分：日常迭代残留资源清理（DEV/UAT通用）
### 4.1 清理废弃ReplicaSet（发布遗留旧版本副本集）
滚动发布后未自动回收的旧RS，无运行Pod，占用集群对象资源
```bash
export NS=dev-business
# 筛选副本数为0的ReplicaSet并批量删除
kubectl get rs -n $NS --field-selector spec.replicas=0 -o name | xargs kubectl delete -n $NS
```

### 4.2 清理异常残留Pod（CrashLoop、Evicted、Completed）
```bash
# 清理驱逐、崩溃、已完成临时Pod
kubectl get pods -n $NS | grep -E "Evicted|CrashLoopBackOff|Completed" | awk '{print $1}' | xargs kubectl delete pod -n $NS
```

### 4.3 清理过期测试PVC（DEV专用）
仅开发环境执行，生产PVC禁止批量删除
```bash
# 匹配测试标签PVC删除
kubectl get pvc -n $NS -l env=dev-test -o name | xargs kubectl delete -n $NS
```

### 4.4 清理废弃临时ConfigMap/Secret
仅测试调试临时配置，不删除业务正式配置
```bash
kubectl get configmap,secret -n $NS -l temp=test | grep -v "harbor-pull-secret|default-container-limit" | awk '{print $1}' | xargs kubectl delete -n $NS
```

### 4.5 清理无效监控ServiceMonitor
业务下线遗留监控采集规则
```bash
kubectl get servicemonitor -n $NS -l app=old-api -o name | xargs kubectl delete -n $NS
```

## 五、第二部分：业务停用全量清理（保留Namespace基线）
适用于业务暂时停用，后续会重新部署，只清空业务应用资源，保留命名空间管控基线。
### 5.1 清理顺序（从上至下，防止残留依赖）
1. 流量入口：Ingress、LoadBalancer Service
2. 弹性伸缩：HPA
3. 业务控制器：Deployment / StatefulSet
4. 内部ClusterIP Service
5. 业务专用ConfigMap、Secret（保留harbor-pull-secret镜像密钥）
6. 业务PVC（确认数据无需保留再执行）
7. 业务NetworkPolicy放行规则（保留default-deny-all基线）
8. 监控采集资源：ServiceMonitor

### 5.2 一键批量清理脚本模板
```bash
export NS=uat-business
# 1. 删除七层Ingress、四层LB服务
kubectl delete ingress -n $NS --all
kubectl delete svc -n $NS -l expose=public

# 2. 删除HPA弹性
kubectl delete hpa -n $NS --all

# 3. 删除无状态/有状态控制器
kubectl delete deploy,statefulset -n $NS --all

# 4. 删除业务内部Service（保留无头服务如需）
kubectl delete svc -n $NS -l app!=mysql-headless

# 5. 删除业务配置密钥，保留镜像拉取secret
kubectl get cm -n $NS | grep -v "default-container-limit" | awk '{print $1}' | xargs kubectl delete cm -n $NS
kubectl get secret -n $NS | grep -v "harbor-pull-secret" | awk '{print $1}' | xargs kubectl delete secret -n $NS

# 6. 删除业务放行网络策略，保留全局默认拒绝基线
kubectl get netpol -n $NS | grep -v "default-deny-all" | awk '{print $1}' | xargs kubectl delete netpol -n $NS

# 7. 清理监控采集
kubectl delete servicemonitor -n $NS --all
```

### 5.3 PVC单独清理（人工确认数据废弃后执行）
```bash
# 列出所有PVC核对业务数据
kubectl get pvc -n $NS
# 确认无用后批量删除
kubectl delete pvc -n $NS --all
```

## 六、第三部分：清理完成校验脚本（必执行）
校验基线资源保留、无业务垃圾残留
```bash
export NS=uat-business
echo "===== 校验基线资源是否保留 ====="
kubectl get limitrange,resourcequota,netpol -n $NS | grep -E "default-container-limit|ns-resource-quota|default-deny-all"

echo "===== 校验无业务Deployment/StatefulSet ====="
kubectl get deploy,statefulset -n $NS

echo "===== 校验无运行Pod ====="
kubectl get pods -n $NS

echo "===== 校验无Ingress/HPA/业务Service ====="
kubectl get ingress,hpa,service -n $NS
```
校验标准：仅基线资源存在，所有业务应用、流量、监控资源全部清空。

## 七、DEV / UAT / PROD 清理差异化规范
1. **DEV开发环境**
   可全量批量清理PVC、临时配置，无严格备份要求，迭代后定期自动清理残留RS/Pod。
2. **UAT测试环境**
   清理PVC前核对测试数据留存需求；批量清理脚本可用，禁止夜间批量删除。
3. **PROD生产环境**
   - 禁止一键批量删除PVC、Secret；必须逐个核对资源用途
   - 仅允许清理发布残留RS、异常Evicted Pod
   - 业务全量清理必须双人复核、工单审批、数据完整备份
   - 不允许执行一键全量清理脚本，分步手动删除资源

## 八、高频清理故障与风险处理
### 故障1：删除Pod长期处于Terminating无法销毁
根因：资源存在Finalizer阻塞、挂载本地存储/未释放PVC
处理：强制删除 `kubectl delete pod xxx --force --grace-period=0`，同步检查PVC挂载状态

### 故障2：批量删除后基线ResourceQuota/LimitRange被误删
根因：清理脚本未做过滤，--all全量删除
修复：参照create-project-workspace.md重新注入命名空间基线资源

### 故障3：删除PVC后数据无法恢复
根因：生产清理前未做数据异地备份
规范：生产PVC删除前必须导出完整备份并校验可用性

### 故障4：清理后命名空间无法新建Pod，镜像拉取401
根因：批量删除Secret时连带删除harbor-pull-secret镜像密钥
修复：参照enable-private-image-access.md重建镜像拉取Secret并绑定默认SA

### 故障5：网络访问全部不通，基线默认拒绝策略丢失
根因：批量删除NetworkPolicy包含default-deny-all
修复：重建全局默认拒绝基线NetworkPolicy

## 九、生产运维标准化规范
1. 区分三类清理场景，禁止混用一键脚本操作生产业务资源；
2. 生产环境仅自动清理发布残留RS、异常Pod，PVC/Secret/控制器禁止批量删除；
3. 任何涉及PVC、Secret的清理操作，必须提前备份数据与配置；
4. 清理脚本强制过滤保留Namespace基线管控资源（Quota、LimitRange、默认网络策略、镜像密钥）；
5. 业务全量清理完成后执行完整校验脚本，确认无业务残留资源；
6. 季度集群巡检定期执行残留资源清理，释放闲置CPU、内存、存储容量；
7. 永久下线场景先执行本文件全量清理，再执行decommission-application.md删除Namespace；
8. 清理操作留存执行日志，生产环境操作记录归档留存审计。

## 十、关联文档索引
create-project-workspace.md Namespace基线资源模板
disable-application-service.md 流量关停前置操作
decommission-application.md 业务永久下线完整流程
validate-project-environment.md 命名空间基线完整性校验
deploy-stateful-application.md 有状态PVC数据备份规范
06-network-debug.md Terminating残留Pod、资源阻塞故障排查