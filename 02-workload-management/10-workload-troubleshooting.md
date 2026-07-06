# 10-workload-troubleshooting.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：目录下全部 01~09 工作负载文档
- 集群环境：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心定位：全类型工作负载统一故障排查SOP，覆盖Pod、Deployment、StatefulSet、DaemonSet、Job/CronJob，包含定位命令、根因、修复方案、分环境处置规范

## 二、通用故障排查标准流程（所有负载统一执行顺序）
1. **查看Pod基础状态**
   ```bash
   kubectl get pods -n ${ns} -w
   ```
2. **完整事件定位（最关键，调度/镜像/探针/配额报错全部在这里）**
   ```bash
   kubectl describe pod ${pod-name} -n ${ns}
   ```
3. **查看容器运行日志（崩溃、启动报错核心依据）**
   ```bash
   # 当前运行Pod日志
   kubectl logs ${pod-name} -n ${ns}
   # 上一轮崩溃Pod历史日志
   kubectl logs -p ${pod-name} -n ${ns}
   # 多容器指定容器日志
   kubectl logs ${pod-name} -c ${container-name} -n ${ns}
   ```
4. **进入容器内部调试网络/文件/进程**
   ```bash
   kubectl exec -it ${pod-name} -n ${ns} -- sh
   ```
5. **查看控制器滚动更新/伸缩事件**
   ```bash
   # Deployment
   kubectl describe deploy ${name} -n ${ns}
   # StatefulSet
   kubectl describe sts ${name} -n ${ns}
   # DaemonSet
   kubectl describe ds ${name} -n ${ns}
   # Job/CronJob
   kubectl describe job ${name} -n ${ns}
   kubectl describe cronjob ${name} -n ${ns}
   ```
6. **资源配额校验**
   ```bash
   kubectl describe resourcequota -n ${ns}
   ```

## 三、Pod 高频状态故障全集
### 3.1 Pending 调度阻塞（无法创建容器）
#### 根因分类
1. 资源不足：节点CPU/Memory requests总和打满；
2. 镜像拉取失败：镜像地址错误、Harbor鉴权缺失、镜像不存在；
3. 依赖资源缺失：Secret/ConfigMap/PVC未创建；
4. 调度约束不匹配：nodeSelector、nodeAffinity、污点容忍缺失；
5. ResourceQuota Pod/CPU/Memory达到命名空间上限。
#### 修复方案
- 清理闲置Pod释放资源，或上调Quota；
- 核对镜像Tag、创建imagePullSecret；
- 补全缺失CM/Secret/PVC；
- 补充tolerations/亲和标签匹配节点。

### 3.2 CrashLoopBackOff 反复崩溃重启
#### 根因分类
1. 程序启动异常：启动命令错误、配置文件缺失、数据库连接失败；
2. OOM内存超限：memory limits过小，退出码137；
3. 端口冲突、权限不足、镜像损坏；
4. 探针配置错误导致容器被持续杀死。
#### 修复方案
- `kubectl logs -p` 查看崩溃堆栈日志；
- 调高容器memory limits，优化程序内存占用；
- 修正启动command、挂载正确配置文件。

### 3.3 Running 但无法对外访问
#### 根因分类
1. readiness探针持续失败，未加入Service Endpoint；
2. Service端口/selector标签不匹配；
3. Calico网络策略拦截流量；
4. 容器监听127.0.0.1，未监听0.0.0.0。
#### 修复方案
- 修复健康接口，调大探针初始延迟；
- 核对Service port与容器端口、matchLabels；
- 放开NetworkPolicy访问策略；
- 修改程序监听地址为0.0.0.0。

### 3.4 Terminating 长时间删不掉（卡死）
#### 根因分类
1. 存在Finalizer阻塞资源；
2. preStop脚本执行卡死，无超时退出；
3. 节点失联kubelet无法上报状态。
#### 修复方案
```bash
# 方案1：编辑资源清空finalizer
kubectl edit pod ${pod} -n ${ns}
# 删除spec.finalizers数组全部内容保存
# 方案2：强制删除（谨慎，生产优先方案1）
kubectl delete pod ${pod} -n ${ns} --grace-period=0 --force
```

### 3.5 Unknown 节点失联
#### 根因
节点宕机、断网、kubelet服务崩溃；
#### 修复
恢复节点网络/重启kubelet；节点永久下线则手动删除Pod。

## 四、Deployment 无状态负载专属故障
### 4.1 滚动更新卡住，新Pod无法就绪
1. 新镜像业务启动报错，logs查看堆栈；
2. readiness探针超时/返回非200；
3. 新版本依赖中间件未就绪；
4. maxUnavailable=0但无空闲节点创建新Pod。
修复：`kubectl rollout pause` 暂停发布，修复后resume或undo回滚。

### 4.2 HPA 无法自动扩容/缩容
1. metrics-server异常，指标显示`<unknown>`；
2. ResourceQuota Pod上限耗尽；
3. maxReplicas已达上限；
4. 缩容冷却窗口未结束。
修复：重启metrics-server、上调Quota、调整HPA min/max。

### 4.3 配置文件更新后不生效
单纯修改ConfigMap/Secret不会触发滚动更新，执行重启：
```bash
kubectl rollout restart deploy xxx -n ${ns}
```

### 4.4 副本数频繁抖动、反复扩缩容
流量毛刺导致HPA频繁触发，调大`scaleDown.stabilizationWindowSeconds=300`防抖。

## 五、StatefulSet 有状态中间件专属故障
### 5.1 Pod Pending，PVC无法绑定
1. StorageClass存储池磁盘满；
2. PV回收策略不匹配、无可用PV；
3. ResourceQuota PVC数量耗尽。
修复：清理闲置PVC、扩容存储、上调命名空间PVC配额。

### 5.2 Pod域名无法互相解析（主从同步失败）
缺失Headless Service / serviceName与svc名称不一致。
修复：创建clusterIP: None无头服务，对齐sts.spec.serviceName。

### 5.3 滚动更新全部Pod同时重启
未配置partition灰度分批，生产中间件必须设置partition分步更新。

### 5.4 缩容后主从数据同步异常
直接缩容主节点，未采用partition先更新从节点；
修复：回滚，使用partition=2/1/0分步灰度更新。

### 5.5 Pod重建后数据丢失
未使用volumeClaimTemplates，使用EmptyDir临时存储或手动删除PVC。

## 六、DaemonSet 节点级组件故障
### 6.1 新增节点不创建DS Pod
nodeSelector/nodeAffinity/污点容忍不匹配，describe ds查看调度事件。

### 6.2 Pod启动失败：hostPath权限不足
宿主机目录权限限制，调整目录权限或配置securityContext运行用户。

### 6.3 采集日志/监控数据缺失
hostPath挂载路径错误、容器无读取宿主机文件权限、配置文件错误。

### 6.4 滚动更新多节点同时重建
maxUnavailable数值过大，生产统一设置maxUnavailable: 1。

## 七、Job / CronJob 批处理定时任务故障
### 7.1 CronJob 到点不生成Job
1. `suspend: true` 定时任务被暂停；
2. cron表达式书写错误；
3. startingDeadlineSeconds过期错过调度窗口。
修复：取消暂停、修正cron表达式、调大调度容错窗口。

### 7.2 Job反复失败持续重启
backoffLimit未耗尽，查看Pod日志：SQL错误、数据库连接失败、存储无写入权限。

### 7.3 多任务并发导致数据库锁冲突
concurrencyPolicy未设置Forbid，修改为禁止并发策略。

### 7.4 任务执行超时被强制杀死
activeDeadlineSeconds时长不足，调大超时阈值或优化任务执行效率。

### 7.5 大量历史Job堆积占用资源
successfulJobsHistoryLimit/failedJobsHistoryLimit数值过大，批量清理旧Job。

## 八、资源配额类通用故障
### 8.1 创建Pod报错：exceeded quota
Namespace ResourceQuota硬上限打满：CPU/内存/Pod/PVC任一资源耗尽。
修复：清理闲置负载，或上调quota hard限制。

### 8.2 无resources容器未自动填充默认值
对应命名空间未部署LimitRange，重新apply LimitRange资源。

### 8.3 节点资源充足，但Pod调度失败
节点总requests总和打满，limits不参与调度计算；缩容闲置Pod或新增节点。

### 8.4 OOM killed 退出码137
容器memory limits小于业务峰值内存占用，调高内存限制。

## 九、网络连通类通用故障
1. Pod跨Namespace无法访问Service
   排查Service域名格式 `svc.ns.svc.cluster.local`、NetworkPolicy拦截；
2. 探针探测超时失败
   容器防火墙拦截内部端口、程序未就绪；
3. 无法拉取Harbor镜像
   内网不通、imagePullSecret缺失、镜像仓库证书异常。

## 十、分环境故障处置规范
### DEV本地
故障可直接删除重建负载，无需备份、无需审批，快速调试。
### FAT测试
故障优先回滚版本，无法恢复可清空环境重建，每日自动清理资源兜底。
### UAT预生产
故障先暂停发布/伸缩，导出资源备份后再回滚；故障记录用于验证生产预案。
### PROD生产（最高优先级约束）
1. 故障第一时间阻断流量/暂停滚动更新，优先回滚稳定版本；
2. 操作双人复核，重大故障先执行etcd快照备份；
3. 禁止直接强制删除PVC、数据库类有状态资源；
4. 故障完成后输出故障复盘记录，优化发布/监控规范。

## 十一、故障应急速查命令合集
```bash
# 1. 全量查看Pod状态与节点分布
kubectl get pods -n ${ns} -o wide

# 2. 查看调度、镜像、探针、配额核心事件
kubectl describe pod ${pod-name} -n ${ns}

# 3. 查看崩溃历史日志
kubectl logs -p ${pod-name} -n ${ns}

# 4. 暂停滚动发布阻断故障扩散
kubectl rollout pause deploy/sts ${name} -n ${ns}

# 5. 紧急回滚上一稳定版本
kubectl rollout undo deploy/sts ${name} -n ${ns}

# 6. 批量清理过期失败Job
kubectl delete jobs -n fat --field-selector status.failed=1

# 7. 查看HPA指标异常事件
kubectl describe hpa ${hpa-name} -n ${ns}

# 8. 查看命名空间资源配额占用
kubectl describe resourcequota -n ${ns}
```

## 十二、关联文档
1. 前置基础：01~09 各类工作负载运维规范
2. 数据兜底：`etcd-backup.md` 故障前快照备份规范
3. 集群级故障：`10-troubleshooting.md`（集群全局故障文档）
4. 升级故障：`kubernetes-upgrade-theory-guide.md` 升级引发负载异常排查
5. 集群迁移：`cluster-migration.md` 迁移后负载异常定位方案