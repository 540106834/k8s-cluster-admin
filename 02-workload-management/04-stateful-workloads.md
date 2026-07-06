# 04-stateful-workloads.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`01-namespace-management.md`、`02-pod-lifecycle.md`、`03-deployment-management.md`
- 集群环境：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：StatefulSet底层原理、稳定网络标识、有序启停、PVC一对一绑定、分环境模板、扩缩容、更新策略、故障恢复、中间件落地规范

## 二、StatefulSet 底层核心理论
### 2.1 适用场景
专门管理**有状态应用**：MySQL、Redis、MongoDB、Elasticsearch、Kafka等数据库/缓存/消息中间件；
与Deployment（无状态）核心差异：Pod存在身份标识、绑定独立持久化存储、启停有序。

### 2.2 三大核心特性（区别于Deployment）
1. **稳定唯一网络身份**
   Pod名称固定：`{sts-name}-0`、`{sts-name}-1`、`{sts-name}-2`；
   内部固定域名：`{pod-name}.{service-name}.{ns}.svc.cluster.local`；
   Pod重建后名称、域名不变，仅IP变更，适配集群主从选举。
2. **有序创建与销毁**
   - 扩容：按序号从小到大依次创建，前一个Ready才创建下一个；
   - 缩容：按序号从大到小依次删除；
   - 更新：滚动更新同样按序号顺序执行，保障集群主从稳定性。
3. **PVC一对一持久绑定**
   通过`volumeClaimTemplates`自动生成独立PVC，每个Pod独占一块存储；
   Pod删除重建时自动复用原有PVC，数据永久留存，不会随Pod销毁丢失。

### 2.3 依赖组件：Headless Service
StatefulSet必须配套无头Service（`clusterIP: None`），用于解析Pod固定域名，**不能使用普通Service**。

### 2.4 层级关系
StatefulSet → Headless Service → 有序编号Pod → 独立PVC

## 三、标准完整 StatefulSet 模板（含Headless Service）
### 1. Headless Service（前置依赖）
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-svc
  namespace: prod
  labels:
    app: mysql
    env: prod
spec:
  selector:
    app: mysql
  clusterIP: None # 无头服务，核心标识
  ports:
  - port: 3306
    targetPort: 3306
```

### 2. StatefulSet 主体模板
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: prod
  labels:
    app: mysql
    env: prod
    business: order
spec:
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  serviceName: mysql-svc # 绑定上方无头Service，必填
  # 滚动更新策略，有序分批更新
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0 # 0=全部更新；N=仅更新序号≥N的Pod，灰度分批
  # 历史版本留存
  revisionHistoryLimit: 10
  # PVC自动模板，每个Pod生成独立存储
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: local-ssd
      resources:
        requests:
          storage: 50Gi
  template:
    metadata:
      labels:
        app: mysql
    spec:
      terminationGracePeriodSeconds: 120 # 数据库加长优雅关闭窗口
      containers:
      - name: mysql
        image: harbor.jinshaoyong.com/k8s/mysql:8.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3306
        # 资源限制，数据库资源隔离严格
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            cpu: 4000m
            memory: 8Gi
        # 完整三探针（UAT/PROD强制）
        startupProbe:
          tcpSocket:
            port: 3306
          failureThreshold: 30
          periodSeconds: 5
        readinessProbe:
          tcpSocket:
            port: 3306
          initialDelaySeconds: 10
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 3306
          initialDelaySeconds: 20
          periodSeconds: 15
        lifecycle:
          preStop:
            exec:
              command: ["sh","-c","mysqladmin shutdown -u root -p${MYSQL_ROOT_PASSWORD}; sleep 20"]
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        - name: config
          mountPath: /etc/mysql/conf.d
      volumes:
      - name: config
        configMap:
          name: mysql-cnf
```

## 四、分环境标准化配置规范（DEV/FAT/UAT/PROD）
| 环境 | replicas副本数 | updateStrategy.partition | PVC存储规格 | 优雅关闭时长 | 探针要求 |
|------|----------------|--------------------------|------------|--------------|----------|
| DEV本地 | 1 | - | 10Gi本地存储 | 60s | 探针可选，本地调试简化 |
| FAT测试 | 1~2 | 0 | 20Gi SSD | 90s | readiness+liveness必配 |
| UAT预生产 | 3 | 灰度分批可设partition | 50Gi SSD，对齐生产规格 | 120s | 全套三探针+preStop优雅关闭 |
| PROD生产 | ≥3（主从集群） | 灰度分批更新（partition分批） | 50Gi+独立SSD存储类 | 120s | 三探针+数据库专属preStop钩子强制开启 |

### 更新策略 partition 灰度说明
生产中间件升级推荐分批灰度：
1. 先设 `partition:2`，仅更新序号2的Pod（从节点）；验证无误；
2. 修改 `partition:1`，更新序号1；
3. 最后 `partition:0` 更新主节点，规避主库停机风险。

## 五、StatefulSet 核心运维操作
### 5.1 创建资源（必须先部署Headless Service）
```bash
kubectl apply -f mysql-headless-svc.yaml -n prod
kubectl apply -f mysql-sts.yaml -n prod
```

### 5.2 查看资源状态
```bash
# 查看StatefulSet
kubectl get sts -n uat
# 查看有序Pod
kubectl get pods -n prod | grep mysql
# 查看自动生成PVC
kubectl get pvc -n prod | grep mysql-data
# 完整事件、更新进度、探针报错
kubectl describe sts mysql -n prod
```

### 5.3 手动扩缩容副本
```bash
# 扩容至4节点
kubectl scale sts mysql --replicas=4 -n fat
# 缩容至3节点（从大序号开始删除，先删mysql-3）
kubectl scale sts mysql --replicas=3 -n prod
```
> 规范：长期副本调整优先修改yaml apply，scale仅临时应急；数据库缩容前确认数据同步完成。

### 5.4 镜像/配置滚动更新
```bash
# 方式1：命令更新镜像
kubectl set image sts mysql mysql=harbor.jinshaoyong.com/k8s/mysql:8.0.36 -n prod
# 方式2：修改yaml apply（版本管理推荐）
kubectl apply -f mysql-sts.yaml -n prod

# 实时观察更新进度
kubectl rollout status sts mysql -n prod -w
# 查看历史更新记录
kubectl rollout history sts mysql -n prod
```

### 5.5 灰度分批更新（生产中间件安全更新）
```bash
# 仅更新序号2、3 Pod，0/1主库不更新
kubectl patch sts mysql -n prod -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
```

### 5.6 重启StatefulSet（重载配置）
```bash
kubectl rollout restart sts mysql -n fat
```

### 5.7 版本回滚
```bash
# 回滚上一版本
kubectl rollout undo sts mysql -n prod
# 指定revision回滚
kubectl rollout undo sts mysql --to-revision=2 -n prod
```

### 5.8 删除 StatefulSet（高危操作）
```bash
# 仅删除sts与Pod，保留PVC（数据留存，生产推荐）
kubectl delete sts mysql -n prod
# 删除sts+Pod+PVC（数据彻底销毁，禁止生产直接执行）
kubectl delete sts mysql -n prod --cascade=orphan=false
```
> 生产删除规范：先删除STS，确认业务下线后，人工确认无数据留存再手动删除PVC。

## 六、持久化存储核心运维规范
1. `volumeClaimTemplates` 创建的PVC生命周期独立于Pod，删除Pod不会删除PVC；
2. 同序号Pod重建自动绑定原有PVC，数据持久不丢失；
3. 扩容副本自动新增对应PVC，缩容仅删除Pod，PVC保留；
4. 生产环境使用独立SSD StorageClass，禁止共享系统盘机械盘；
5. FAT环境PVC可定时清理，PROD PVC人工审核后才可删除。

## 七、StatefulSet vs Deployment 核心对比
| 特性 | StatefulSet（有状态） | Deployment（无状态） |
|------|-----------------------|----------------------|
| Pod名称 | 固定有序：app-0、app-1 | 随机UID，重建名称完全变更 |
| 网络域名 | 固定稳定域名 | 无固定域名，仅Service统一入口 |
| 存储 | 一对一独立PVC | 共享PVC或临时EmptyDir |
| 启停顺序 | 有序创建/反向缩容 | 并行创建删除，无序 |
| 更新方式 | 支持partition灰度分批 | 全局并行滚动更新 |
| 适用负载 | MySQL/Redis/ES/Kafka中间件 | Web、API、微服务无状态业务 |

## 八、生产安全约束规范
1. 数据库、缓存等有状态组件**强制使用StatefulSet**，禁止Deployment承载；
2. 必须配套Headless Service，不可使用普通ClusterIP Service；
3. PROD环境更新采用partition灰度分批，优先更新从节点，最后更新主节点；
4. 加长`terminationGracePeriodSeconds`，配置preStop执行数据库正常关闭；
5. PVC独立SSD存储，禁止使用Local临时存储、EmptyDir承载业务数据；
6. 删除STS默认保留PVC，防止误删业务数据；
7. 中间件变更前执行etcd快照+数据库全量备份；
8. NetworkPolicy隔离FAT环境直连PROD中间件Pod。

## 九、高频故障与排查方案
1. **Pod创建卡死Pending，PVC无法绑定**
   StorageClass资源不足、存储节点磁盘满、PV回收策略不匹配。
2. **更新后主从同步异常**
   未使用partition灰度，直接更新主节点导致数据库重启断同步；调整分批更新策略。
3. **Pod重建后数据丢失**
   误手动删除PVC，或未使用volumeClaimTemplates，采用临时EmptyDir。
4. **域名无法互相解析**
   缺失Headless Service、serviceName与svc名称不匹配。
5. **缩容后数据丢失**
   缩容仅删除Pod，PVC保留；若手动删除PVC才会丢失数据。
6. **滚动更新全部Pod同时重启**
   partition=0，未开启分批灰度，生产中间件需设置partition分步更新。

## 十、运维速查命令
```bash
# 批量导出中间件sts备份
kubectl get sts -n prod -o yaml > sts-mysql-prod-backup.yaml

# 批量查看所有sts关联PVC
kubectl get sts,pvc -n prod

# 仅删除sts保留PVC
kubectl delete sts mysql -n prod

# 查看sts完整更新事件
kubectl describe sts mysql -n prod
```

## 十一、关联文档
1. 前置基础：`02-pod-lifecycle.md` 探针、优雅终止机制
2. 无状态对比：`03-deployment-management.md` Deployment部署规范
3. 存储管控：`07-resource-management.md` 存储资源配额限制
4. 发布灰度：`09-rollout-and-rollback.md` 滚动更新、partition灰度流程
5. 存储运维：集群存储PV/PVC管理文档
6. 故障汇总：`10-workload-troubleshooting.md` 中间件Pod启动、存储绑定排错