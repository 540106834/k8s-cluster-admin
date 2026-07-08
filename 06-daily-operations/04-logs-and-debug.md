# 04-logs-and-debug.md
## 一、文档基础信息
- 归属目录：`06-daily-operations/`
- 前置阅读：`00-README.md`、`01-kubectl-usage.md`
- 集群基准：Kubernetes v1.32.13、容器日志json格式、Filebeat日志采集、审计事件持久化、内网Harbor调试镜像
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：kubectl logs 全量参数、实时流式日志、历史过期日志、资源事件检索、kubectl exec交互进入容器、临时调试Pod创建、故障现场留存规范、日志脱敏、调试安全约束、日志故障排查

## 二、日志与调试底层原理
### 2.1 容器日志输出机制
1. 容器stdout/stderr输出由containerd统一捕获，以json文件持久存储在节点本地 `/var/log/containers/`；
2. 日志驱动统一json格式，包含时间戳、日志流、容器元数据，供Filebeat采集至日志平台；
3. 容器删除后节点本地日志随容器清理，长期追溯依赖外部日志存储平台（ELK）。

### 2.2 事件（Events）说明
apiserver记录资源全生命周期事件：Pod调度失败、镜像拉取失败、准入拦截、PVC挂载失败、发布滚动进度、资源配额超限等，是故障第一层排查入口。

### 2.3 调试两种方式区分
1. **kubectl exec**：进入业务运行中容器，临时查看文件、网络、磁盘；
2. **临时调试Pod**：独立临时Pod挂载相同PVC/网络命名空间，包含curl、tcpdump、df、mysql客户端等全套调试工具，不污染业务容器。

## 三、kubectl logs 标准日志操作
### 3.1 实时跟踪日志（生产最常用）
```bash
# 实时持续输出日志
kubectl logs -f mysql-0 -n prod

# 多容器Pod指定容器名
kubectl logs -f order-api -n prod -c app
```

### 3.2 查看最近N行日志
```bash
# 查看最后200行
kubectl logs --tail=200 order-api-7f98d7654c-2xqzf -n prod
```

### 3.3 查看历史旧Pod日志（Pod重启后查看崩溃前日志）
```bash
# --previous 读取已终止Pod日志
kubectl logs --previous mysql-0 -n prod
```

### 3.4 时间范围过滤日志
```bash
# 近1小时日志
kubectl logs --since=1h order-api -n prod
# 指定时间点之后日志
kubectl logs --since-time="2026-07-08T02:00:00Z" order-api -n prod
```

### 3.5 日志导出本地备份（故障现场留存）
```bash
kubectl logs order-api-0 -n prod > app-log-$(date +%Y%m%d).log
```

## 四、资源Events事件检索（故障优先排查入口）
```bash
# 查看当前命名空间全部事件，按时间排序
kubectl get events -n prod --sort-by=.metadata.creationTimestamp

# 仅看Pod相关警告/错误事件
kubectl get events -n prod | grep -E "Warning|Error"

# 实时跟踪新事件
kubectl get events -n prod -w

# 筛选PVC挂载、准入拒绝事件
kubectl get events -n prod | grep -E "FailedMount|denied|Forbidden"
```
常见事件报错：镜像拉取失败、资源不足、PSS安全策略拦截、存储挂载超时、Quota超限。

## 五、kubectl exec 容器交互调试规范
### 5.1 进入运行中容器交互式终端
```bash
# 标准进入sh
kubectl exec -it mysql-0 -n prod -- sh
# 容器仅包含bash
kubectl exec -it mysql-0 -n prod -- bash
# 多容器Pod指定容器
kubectl exec -it order-api -n prod -c app -- sh
```

### 5.2 不进入终端，单次执行命令（无需交互）
```bash
# 查看磁盘挂载
kubectl exec -it mysql-0 -n prod -- df -h
# 查看内存占用
kubectl exec -it mysql-0 -n prod -- free -h
# 网络连通测试
kubectl exec -it order-api -n prod -- curl redis.prod.svc:6379
```

### 安全约束
1. PROD禁止长时间占用exec终端，调试完成立即退出；
2. 禁止在容器内修改业务代码、配置文件，全部通过ConfigMap/Secret变更；
3. 禁止在容器内输出完整数据库密码、密钥，日志脱敏。

## 六、临时调试Pod（独立工具Pod，不侵入业务容器）
### 6.1 共享网络命名空间调试（排查网络连通）
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: debug-net-temp
  namespace: prod
spec:
  shareProcessNamespace: true
  hostNetwork: false
  containers:
  - name: debug
    image: harbor.jinshaoyong.com/k8s/debug-tools:v1.0
    command: ["sleep","3600"]
  restartPolicy: Never
```
内置工具：curl、tcpdump、dig、mysql-client、redis-cli、nc、df、du、jq。

### 6.2 挂载业务PVC调试数据（数据恢复/排查）
```yaml
volumes:
- name: mysql-data
  persistentVolumeClaim:
    claimName: mysql-data-mysql-0
volumeMounts:
- name: mysql-data
  mountPath: /data/mysql
```
### 临时Pod一键创建命令
```bash
kubectl run debug-temp --image=harbor.jinshaoyong.com/k8s/debug-tools:v1.0 -n prod -- sleep 3600
```

## 七、故障现场留存标准化流程
1. 导出Pod完整日志至本地文件；
2. 导出事件列表保存；
3. 导出当前负载yaml、PVC、NetworkPolicy资源备份；
4. 如需容器现场，保留Pod不删除，临时Suspend定时备份Job降低IO；
5. 记录故障时间、操作人、现象、日志关键报错，存入故障工单。

## 八、DEV/FAT/UAT/PROD 调试差异化基线
### DEV本地
可随意exec进入容器、长期调试Pod，无严格日志留存要求。
### FAT测试
自由exec调试，临时调试Pod用完可直接删除；日志短期留存。
### UAT预生产
exec仅允许读操作，禁止容器内修改文件；故障日志留存30天。
### PROD生产（强制约束）
1. exec仅用于只读排查，禁止写入/修改业务文件；
2. 禁止长时间占用交互式终端，调试完成立即退出；
3. 核心数据库命名空间exec操作双人复核；
4. 故障必须导出日志、事件备份，留存现场再操作；
5. 不允许在业务Pod内安装额外调试工具，统一使用独立临时调试Pod。

## 九、日志&调试高频故障排查
### 1. kubectl logs 无输出、返回timeout
1. 容器未输出stdout日志，应用日志输出至文件；
2. 容器已终止，未使用`--previous`读取历史日志；
3. 节点磁盘满，containerd无法写入容器日志。

### 2. Pod创建失败但无日志，优先查events
镜像拉取失败、准入拦截、PVC不存在、资源Quota超限全部会记录在events。

### 3. kubectl exec 报错 permission denied
Pod securityContext限制，不允许交互式终端；或ServiceAccount无exec权限。

### 4. 临时调试Pod无法访问业务Service
NetworkPolicy出站白名单未放行调试Pod标签，补充白名单策略。

### 5. 日志输出密钥明文触发安全告警
应用日志未脱敏，修改日志输出逻辑，准入控制拦截明文密钥打印。

### 6. 容器重启后丢失历史日志
未使用`--previous`参数读取旧Pod日志，或日志仅本地节点存储无持久化ELK。

## 十、运维速查命令合集
```bash
# 实时跟踪日志
kubectl logs -f ${pod-name} -n ${ns}

# 查看崩溃前历史日志
kubectl logs --previous ${pod-name} -n ${ns}

# 导出日志本地保存
kubectl logs ${pod-name} -n ${ns} > fault-log-$(date +%Y%m%d).log

# 查看全量事件
kubectl get events -n ${ns} --sort-by=.metadata.creationTimestamp

# 进入容器交互终端
kubectl exec -it ${pod-name} -n ${ns} -- sh

# 创建临时调试工具Pod
kubectl run debug-temp --image=harbor.jinshaoyong.com/k8s/debug-tools:v1.0 -n prod -- sleep 3600

# 删除临时调试Pod
kubectl delete pod debug-temp -n prod
```

## 十一、生产安全最佳实践
1. 故障排查优先看events，再查日志，最后exec进入容器，减少侵入式操作；
2. 业务容器不预装大量调试工具，统一使用独立临时debug Pod；
3. PROD禁止在容器内修改配置、写入数据，所有变更走GitOps流水线；
4. 日志开启脱敏，过滤数据库密码、API密钥等敏感内容；
5. 故障必须留存日志、事件、资源yaml备份，便于事后复盘；
6. 限制exec操作RBAC权限，开发账号仅可查看日志，无exec权限；
7. 定时清理过期临时调试Pod，释放节点资源。

## 十二、关联文档
1. 客户端基础：`01-kubectl-usage.md` exec/logs操作权限预校验
2. 准入控制：`05-security-management/03-admission-control.md` 拦截输出明文密钥的Pod
3. 配置管理：`02-workload-management/11-configuration-management.md` 日志级别ConfigMap配置规范
4. 安全审计：`05-security-management/06-audit-log.md` exec、日志读取操作审计记录
5. 网络安全：`05-network-security/05-network-security.md` 调试Pod出站访问白名单策略
6. 运维巡检：`07-production-checklist.md` 日志采集失败、大量Error事件巡检项