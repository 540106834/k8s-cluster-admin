# publish-application-release.md
# Java微服务滚动版本发布标准化操作手册
## 一、文档定位
本文面向企业生产K8s集群，提供**Deployment零停机滚动更新发布**完整流程：版本镜像构建推送、灰度滚动发布、发布进度观测、发布冒烟校验、发布失败识别；区分dev/uat/prod三套环境操作规范，配套回滚手册、应用部署文档，是日常业务迭代上线标准SOP。
前置依赖：
deploy-java-application.md｜业务Deployment已正常部署
build-harbor-registry.md｜新版本镜像构建推送完成
validate-project-environment.md｜项目环境验收通过
下游关联：rollback-application-release.md、deploy-java-application.md

## 二、发布核心规范与前置约束
### 2.1 滚动更新机制说明
企业统一使用`RollingUpdate`发布策略：
```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1        # 发布时额外新建1个临时Pod
      maxUnavailable: 0  # 发布期间保证业务副本无缺失，零停机核心配置
```
流程：新建新版本Pod → 就绪探针通过后自动接入流量 → 逐步销毁旧版本Pod，全程业务无中断。

### 2.2 版本镜像规范（强制）
1. 禁用`latest`浮动标签，统一**语义化版本** `v主.次.补丁`
    示例：`harbor.example.com/prod/api:v1.2.0`
2. 环境隔离镜像目录：dev/uat/prod，三套环境镜像互不复用
3. 发布前必须在Harbor完成镜像上传，无镜像缺失、构建失败

### 2.3 发布窗口规范
1. DEV：任意工作时间可发布，无窗口限制
2. UAT：工作日 9:00-21:00，避免夜间发布
3. PROD：**业务低峰窗口（凌晨00:00-06:00）**，禁止白天高峰期迭代发布

### 2.4 发布前置检查（任意一项不通过禁止发布）
1. 集群控制平面ETCD健康，无告警
2. 目标命名空间资源Quota充足，剩余CPU/内存可承载临时maxSurge副本
3. CNI网络正常，同/跨节点Pod互通无丢包
4. 新版本镜像已推送对应环境Harbor项目，可正常拉取
5. 新版本本地自测、UAT验收通过（生产发布强制）
6. 监控、日志平台正常采集指标，可观测发布异常
7. 已执行ETCD备份（生产发布必做）

## 三、步骤1：新版本镜像确认（发布前校验）
### 3.1 校验镜像存在且可拉取
```bash
# 示例：生产新版本镜像
export NEW_IMAGE=harbor.example.com/prod/api:v1.2.0
export NS=prod-business
# 管理节点测试拉取镜像
crictl pull $NEW_IMAGE
# 查看镜像信息，确认版本正确
crictl images | grep $NEW_IMAGE
```

### 3.2 镜像内容复核
1. 新版本修复需求清单核对完成
2. 配置文件、数据库脚本同步更新
3. 无高危漏洞、调试后门代码

## 四、步骤2：执行滚动发布（两种标准方式）
### 方式A：命令行快速更新镜像标签（日常迭代推荐）
```bash
# 修改Deployment镜像版本，触发滚动更新
kubectl set image deployment/app-api \
app-api=$NEW_IMAGE \
-n $NS
```

### 方式B：YAML文件完整更新（配置同步变更时使用）
编辑部署yaml，替换image字段，同时可同步修改资源、探针、环境变量
```bash
kubectl apply -f deploy-app.yaml -n $NS
```

## 五、步骤3：实时观测发布滚动进度（多维度监控）
### 5.1 实时Pod滚动刷新监控
```bash
# 持续查看新旧Pod创建销毁进度
watch kubectl get pods -n $NS -l app=app-api
```
滚动正常现象：
1. 新增新版本Pod状态ContainerCreating → Running/Ready
2. 旧Pod等待新Pod就绪后逐步Terminating销毁
3. 全程不会出现所有Pod同时消失，maxUnavailable=0保证存量副本在线

### 5.2 查看发布事件（排查卡顿/失败核心）
```bash
kubectl get events -n $NS --sort-by=.metadata.creationTimestamp
# 筛选Deployment相关事件
kubectl describe deployment app-api -n $NS
```
正常事件：
- ScalingReplicaSet：新建新版本ReplicaSet
- SuccessfulCreate：新Pod创建成功
- SuccessfulDelete：旧Pod正常销毁

### 5.3 实时查看业务日志，校验新版本启动无报错
```bash
# 实时跟踪新版本Pod日志
kubectl logs -f -n $NS deploy/app-api
```

### 5.4 监控大盘观测业务指标
1. QPS平稳无断崖下跌
2. HTTP 5xx错误率保持0，无突增
3. JVM内存、GC无异常波动

## 六、步骤4：发布冒烟测试（确认新版本正常提供服务）
发布滚动完成后，执行三类连通校验，判定发布成功：
### 1. 内部Service访问测试
```bash
kubectl exec -it test-pod -- curl http://app-api-svc
```
### 2. 外网Ingress域名访问（对外业务）
访问业务域名，接口正常返回新版本逻辑，无报错
### 3. 核心业务流程全链路测试
核心接口、数据库读写、缓存交互全部正常，数据无错乱

## 七、发布完成收尾确认
### 7.1 校验所有旧副本完全销毁
```bash
# 查看ReplicaSet，仅保留新版本RS，旧副本数=0
kubectl get rs -n $NS -l app=app-api
```
### 7.2 留存发布记录
记录：发布时间、操作人、新版本镜像、需求变更清单
### 7.3 生产环境复核ETCD备份
发布完成后执行一次手动ETCD快照备份（backup-etcd-cluster.md）

## 八、发布失败判定与应急操作
### 8.1 发布失败特征（满足任意一条判定发布异常）
1. 新Pod持续CrashLoopBackOff，反复重启
2. Readiness就绪探针长时间失败，滚动卡住不销毁旧Pod
3. 业务接口5xx错误率飙升，监控触发异常告警
4. 镜像拉取ErrImagePull 401/证书错误
5. 资源不足，新Pod调度失败Pending

### 8.2 应急处理
立即执行版本回滚，参考 `rollback-application-release.md`，恢复上一稳定版本，排查新版本代码/配置问题后重新发布。

## 九、DEV / UAT / PROD 环境发布差异化规范
1. **DEV**
    - 发布无窗口限制，可频繁迭代
    - 冒烟测试简化，仅验证服务能正常启动访问
2. **UAT**
    - 发布后完整功能验收，验证新版本需求全部生效
    - 禁止夜间凌晨发布，预留测试人员验证窗口
3. **PROD**
    - 严格低峰窗口发布，提前报备运维负责人
    - 发布前全量ETCD备份、发布后再次备份
    - 完整全链路冒烟测试，留存测试记录归档
    - 监控告警持续观测30分钟无异常才算发布完成

## 十、高频发布故障排查
### 故障1：滚动发布卡住，新Pod就绪探针失败，旧Pod不销毁
根因：新版本代码启动报错、数据库连接失败、健康接口未开放
处理：kubectl logs查看新版本启动日志，定位代码bug，执行回滚修复后重新发布

### 故障2：新Pod ErrImagePull镜像拉取失败
根因：镜像未推送Harbor、镜像标签写错、命名空间imagePullSecret异常
处理：核对镜像地址，重新推送镜像，回滚旧版本

### 故障3：集群资源不足，新Pod Pending无法调度
根因：命名空间ResourceQuota达到上限、节点CPU/内存耗尽
处理：临时清理闲置资源或调高Quota，低峰重新发布

### 故障4：发布后接口大量500错误
根因：新版本逻辑bug、数据库脚本未执行、配置文件缺失
处理：立即回滚至稳定旧版本，修复代码重新构建镜像发布

### 故障5：滚动发布过程QPS突降，业务短暂卡顿
根因：maxUnavailable未配置为0，同时销毁多个旧Pod
规范：所有生产Deployment固定maxUnavailable:0，maxSurge:1

## 十一、生产运维标准化落地规范
1. 生产环境统一RollingUpdate零停机发布策略，禁止Recreate重建发布（业务全中断）
2. PROD发布严格限定低峰窗口，提前报备运维，留存发布操作日志与冒烟测试记录
3. 新版本必须先在DEV/UAT验证通过，方可上线生产，禁止直接生产迭代
4. 发布全程同时观测日志+监控大盘，出现异常立即回滚，减少故障影响时长
5. 禁止使用latest镜像标签发布，所有迭代使用固定语义化版本
6. 每次生产发布前后均执行ETCD备份，防止发布异常集群数据损坏
7. 发布完成30分钟持续观测监控指标，无异常才算发布闭环

## 十二、关联文档索引
deploy-java-application.md Java微服务Deployment标准部署模板
rollback-application-release.md 发布异常版本回滚完整操作手册
validate-project-environment.md 发布前项目环境资源校验标准
build-harbor-registry.md 业务镜像构建与推送规范
backup-etcd-cluster.md 生产发布ETCD备份流程
06-network-debug.md Pod启动、镜像拉取、探针故障排查手册