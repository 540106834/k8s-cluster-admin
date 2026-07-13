# 03-deployment-management.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`01-namespace-management.md`、`02-pod-lifecycle.md`
- 集群版本：Kubernetes v1.32.13，containerd 2.1.5，内网Harbor镜像仓库
- 环境分层：DEV本地、FAT功能测试、UAT预生产、PROD生产
- 核心覆盖：Deployment原理、声明式模板、副本管控、更新策略、扩缩容、环境差异化规范、故障排查

## 二、Deployment 底层理论
### 2.1 定位
Deployment 是**无状态业务标准控制器**，底层通过 ReplicaSet 管控Pod副本，提供版本滚动更新、副本自愈、历史版本回滚能力；
适用于Web、API、网关、后台服务等无状态应用，不适合数据库、消息队列等有状态中间件。

### 2.2 层级控制关系
Deployment → ReplicaSet → Pod
1. Deployment：定义期望副本数、镜像、更新策略、探针、资源限制；
2. ReplicaSet：负责维持对应版本Pod副本数量；
3. 滚动更新时会创建新ReplicaSet，旧ReplicaSet保留用于回滚；
4. 仅删除Deployment才会级联删除所有ReplicaSet与Pod。

### 2.3 无状态核心特征
1. Pod完全对等，无固定网络标识、无专属PVC；
2. Pod重建后IP、主机名变更，流量可任意调度至任意副本；
3. 水平扩缩容不影响业务数据一致性。

## 三、标准声明式Deployment模板（分环境适配）
### 通用基础模板
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: fat
  labels:
    app: api-server
    env: fat
    business: order
spec:
  # 副本数分环境差异化配置
  replicas: 2
  selector:
    matchLabels:
      app: api-server
  # 滚动更新策略（生产强制，禁止Recreate）
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  # 保留历史版本数，用于回滚
  revisionHistoryLimit: 10
  template:
    metadata:
      labels:
        app: api-server
    spec:
      # 优雅关闭时长
      terminationGracePeriodSeconds: 60
      containers:
      - name: api-server
        image: harbor.jinshaoyong.com/k8s/api-server:v1.0.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        # 资源限制（全环境强制）
        resources:
          requests:
            cpu: 200m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        # 全套健康探针（UAT/PROD强制）
        startupProbe:
          httpGet:
            path: /health/startup
            port: 8080
          failureThreshold: 30
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /health/live
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        # 优雅关闭钩子
        lifecycle:
          preStop:
            exec:
              command: ["sh","-c","sleep 10"]
        env:
        - name: ENV_MODE
          valueFrom:
            configMapKeyRef:
              name: env-config
              key: env
        volumeMounts:
        - name: config-volume
          mountPath: /app/config
      volumes:
      - name: config-volume
        configMap:
          name: api-config
```

## 四、分环境副本&策略规范（DEV/FAT/UAT/PROD）
| 环境 | replicas副本数 | rollingUpdate配置 | revisionHistoryLimit | 探针要求 |
|------|----------------|-------------------|----------------------|----------|
| DEV本地 | 1 | 无强制要求 | 3 | 可选，本地调试可省略 |
| FAT测试 | 2 | maxSurge=1,maxUnavailable=0 | 5 | readiness+liveness必配，startup可选 |
| UAT预生产 | 3 | maxSurge=1,maxUnavailable=0 | 10 | 三探针完整配置，对齐生产参数 |
| PROD生产 | ≥3（核心服务5+） | maxSurge=1,maxUnavailable=0 | 10 | 三探针+preStop钩子强制配置 |

### 更新策略两种模式说明
1. **RollingUpdate（推荐全环境）**
   逐步新建Pod，就绪后销毁旧Pod，业务零停机；`maxUnavailable:0` 保证更新过程副本数不低于期望值。
2. **Recreate（禁止生产使用）**
   先删除全部旧Pod，再新建，会出现业务中断，仅临时测试场景使用。

## 五、Deployment 核心生命周期操作
### 5.1 创建/更新部署（声明式标准操作）
```bash
# 标准声明式提交，增量更新资源
kubectl apply -f deploy-api-fat.yaml -n fat
```

### 5.2 查看Deployment、ReplicaSet状态
```bash
# 查看所有deployment
kubectl get deploy -n uat
# 关联查看副本控制器
kubectl get rs -n prod
# 完整详情，事件、更新进度、探针报错
kubectl describe deploy api-server -n prod
```

### 5.3 手动扩缩容副本
```bash
# 临时调整副本至5
kubectl scale deploy api-server --replicas=5 -n fat
# 生产缩容至3
kubectl scale deploy api-server --replicas=3 -n prod
```
> 规范：长期副本调整优先修改yaml文件apply，scale仅临时应急。

### 5.4 镜像版本迭代发布

#### 方式1：命令行快速更新镜像

```bash
kubectl set image deploy api-server api-server=harbor.jinshaoyong.com/k8s/api-server:v1.0.1 -n prod
```
#### 方式2：修改yaml文件apply（版本管理推荐）

修改spec.template.spec.containers.image字段后执行 `kubectl apply -f`。

### 5.5 观察滚动更新进度
```bash
# 实时观测更新Pod创建销毁
kubectl rollout status deploy api-server -n prod -w
# 查看更新事件记录
kubectl rollout history deploy api-server -n prod
```

### 5.6 重启Deployment（重载配置/环境变量）
```bash
kubectl rollout restart deploy api-server -n fat
```
底层逻辑：触发滚动更新，新建一批Pod，旧Pod逐步销毁。

### 5.7 版本回滚（故障核心操作）
```bash
# 查看历史发布版本
kubectl rollout history deploy api-server -n prod
# 回滚至上一个稳定版本
kubectl rollout undo deploy api-server -n prod
# 指定回滚到某一历史版本
kubectl rollout undo deploy api-server --to-revision=2 -n prod
```

### 5.8 删除Deployment
```bash
# 删除整套无状态服务（级联删除RS、Pod）
kubectl delete -f deploy-api-prod.yaml
# 命令删除
kubectl delete deploy api-server -n fat
```

## 六、资源标签与选择器规范
1. 固定标签：`app、env、business、owner`，统一过滤Deployment；
2. selector.matchLabels必须与pod template labels完全一致，否则控制器无法管理Pod；
3. 禁止修改selector标签，修改会导致Deployment丢失原有Pod控制权。

## 七、生产落地约束规范
1. 所有业务无状态服务必须使用Deployment，禁止裸Pod运行；
2. PROD/UAT环境强制使用RollingUpdate，maxUnavailable=0保障可用性；
3. 必须配置resources requests+limits，搭配命名空间LimitRange兜底；
4. 开启revisionHistoryLimit留存历史版本，故障支持快速回滚；
5. 预生产、生产全套三探针+preStop优雅关闭配置；
6. 镜像统一内网Harbor，imagePullPolicy:IfNotPresent，减少重复拉取；
7. 发布前导出当前Deployment yaml备份，重大变更提前执行etcd快照；
8. FAT环境每日自动清理闲置Deployment，PROD禁止自动清理，人工操作双人复核。

## 八、高频故障与排查方案
1. **滚动更新卡住，新Pod无法就绪**
   执行`kubectl describe deploy`查看事件，多为readiness探针失败、配置文件缺失、镜像拉取失败。
2. **Deployment副本数长期达不到期望**
   节点CPU/内存资源不足、镜像私有仓库鉴权失败、PVC无法绑定。
3. **回滚后业务异常**
   历史镜像被Harbor清理，提前留存稳定版本镜像；核对revision历史版本。
4. **更新后大量Pod CrashLoopBackOff**
   新版本程序bug、配置参数变更、数据库连接地址未适配环境。
5. **修改selector标签后Pod失控**
   selector为不可变字段，如需变更只能新建Deployment，切换流量后删除旧资源。
6. **缩容/删除Pod流量瞬间丢失**
   preStop钩子未配置、terminationGracePeriodSeconds时间过短，存量请求未处理完成。

## 九、常用运维速查命令
```bash
# 批量导出命名空间所有deployment备份
kubectl get deploy -n prod -o yaml > deploy-prod-backup-$(date +%Y%m%d).yaml

# 批量扩容所有业务副本至2（FAT环境）
kubectl get deploy -n fat | awk '{print $1}' | grep -v NAME | xargs -I {} kubectl scale deploy {} --replicas=2 -n fat

# 查看所有发布历史记录
kubectl rollout history deploy --all-namespaces
```

## 十、关联文档
1. 前置基础：`02-pod-lifecycle.md` 探针、优雅终止、Pod状态机制
2. 资源管控：`07-resource-management.md` LimitRange & ResourceQuota
3. 发布回滚汇总：`09-rollout-and-rollback.md` 完整发布流程规范
4. 有状态对比：`04-stateful-workloads.md` StatefulSet适用场景区分
5. 故障汇总：`10-workload-troubleshooting.md` Deployment更新卡死、Pod崩溃排错