# deploy-stateful-application.md
# K8s 有状态应用 StatefulSet 标准化部署手册（MySQL/Redis/MongoDB/Elasticsearch）
## 一、文档定位
本文面向企业生产集群，针对**数据库、缓存、分布式中间件**等有状态业务，提供 `StatefulSet` 完整部署规范：固定网络标识、有序创建/删除、稳定存储绑定、Headless Service、PV 节点亲和、主从副本、快照备份、故障自动恢复；区分 DEV/UAT/PROD 三套环境，配套存储 CSI、网络平台、项目交付文档。
前置依赖：
create-project-workspace.md｜项目Namespace基线就绪
build-storage-platform.md｜NFS/RBD 块存储 CSI 就绪
build-monitoring-platform.md｜中间件Exporter监控组件
configure-project-resource-policy.md｜资源配额、网络策略基线
下游关联：publish-application-release.md、validate-project-environment.md

## 二、StatefulSet 核心特性（对比 Deployment）
1. **有序生命周期**：创建按 0→1→2 顺序启动；删除按 2→1→0 逆序销毁
2. **稳定唯一网络标识**：Pod 固定域名 `{pod-name}.{svc-name}.ns.svc.cluster.local`，主从配置无需动态IP
3. **持久存储一对一绑定**：每个Pod独立PV，删除Pod不会自动删除数据（回收策略Retain）
4. **稳定身份**：主机名、hostname永久不变，适配数据库主从同步、集群选举
5. Headless Service 无负载均衡，直接解析所有Pod独立地址，用于集群节点互相发现

### 适用业务
✅ MySQL、PostgreSQL、Redis Cluster、MongoDB、Elasticsearch、Kafka、MinIO
❌ 普通无状态Java Web（使用Deployment）

## 三、前置环境校验
1. 集群CSI存储可用，支持动态PV、节点亲和绑定、数据持久化
2. 项目Namespace基线资源就绪：LimitRange、ResourceQuota、默认Deny网络策略
3. Harbor私有仓库中间件镜像拉取权限正常
4. 监控Exporter（mysqld-exporter/redis-exporter）镜像就绪
5. 网络放行：集群内部3306/6379等中间件端口，跨Pod互通无阻断
6. 生产环境规划副本数≥3，满足集群高可用选举

## 四、核心配套资源说明（StatefulSet 缺一不可）
1. **Headless Service**：无头服务，提供固定Pod域名解析，无ClusterIP
2. StatefulSet：核心控制器，有序管理有状态Pod
3. StorageClass/PVC模板：volumeClaimTemplates，自动为每个Pod生成独立PV
4. ConfigMap：中间件my.conf/redis.conf配置文件
5. Secret：数据库root账号、同步复制密码
6. NetworkPolicy：放行集群内部主从同步端口
7. ServiceMonitor：中间件监控指标采集

## 五、步骤1：创建 Headless 无头服务
### headless-svc.yaml
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless
  namespace: prod-db
  labels:
    app: mysql
spec:
  selector:
    app: mysql
  clusterIP: None # 核心：无头服务，不分配集群IP
  ports:
  - port: 3306
    targetPort: 3306
    name: mysql
```
部署：
```bash
kubectl apply -f headless-svc.yaml -n prod-db
# 验证域名解析
kubectl run test --image=harbor.example.com/library/busybox:1.36 --rm -it -- nslookup mysql-0.mysql-headless.prod-db.svc.cluster.local
```

## 六、步骤2：配置 ConfigMap 中间件配置文件
### mysql-config.yaml
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-conf
  namespace: prod-db
data:
  my.cnf: |
    [mysqld]
    datadir=/var/lib/mysql
    port=3306
    character-set-server=utf8mb4
    default-storage-engine=innodb
    # 主从同步配置
    server-id=1
    log-bin=mysql-bin
    binlog-format=ROW
```
```bash
kubectl apply -f mysql-config.yaml -n prod-db
```

## 七、步骤3：创建 Secret 数据库账号密码
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
  namespace: prod-db
type: Opaque
data:
  root-password: MTIzNDU2
  replication-user: cm9w
  replication-password: cmVwMTIz
```

## 八、步骤4：StatefulSet 完整生产模板（核心）
### statefulset-mysql.yaml
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: prod-db
  labels:
    app: mysql
    env: prod
spec:
  replicas: 3 # 生产3副本主从集群
  selector:
    matchLabels:
      app: mysql
  # 绑定无头服务
  serviceName: mysql-headless
  # PV自动创建模板，每个Pod独立存储
  volumeClaimTemplates:
  - metadata:
      name: mysql-data
    spec:
      storageClassName: rbd-sc # 块存储CSI（数据库优先块存储，禁止NFS）
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 50Gi
  # 发布策略：有序滚动更新
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0 # 全部副本同步更新
  template:
    metadata:
      labels:
        app: mysql
    spec:
      securityContext:
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
      - name: mysql
        image: harbor.example.com/prod/mysql:8.0.36
        imagePullPolicy: Always
        ports:
        - containerPort: 3306
          name: mysql
        # 资源限制
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            cpu: 2000m
            memory: 4Gi
        # 环境变量读取Secret
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        - name: MYSQL_REPL_USER
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: replication-user
        - name: MYSQL_REPL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: replication-password
        # 探针
        livenessProbe:
          exec:
            command: ["mysqladmin","ping","-uroot","-p$(MYSQL_ROOT_PASSWORD)"]
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ["mysql","-uroot","-p$(MYSQL_ROOT_PASSWORD)","-e","SELECT 1"]
          initialDelaySeconds: 20
          periodSeconds: 5
        # 挂载配置与持久化存储
        volumeMounts:
        - name: mysql-data
          mountPath: /var/lib/mysql
        - name: config-volume
          mountPath: /etc/mysql/conf.d
      volumes:
      - name: config-volume
        configMap:
          name: mysql-conf
```
### 部署执行
```bash
kubectl apply -f statefulset-mysql.yaml -n prod-db
# 有序观察 Pod 创建顺序 mysql-0 → mysql-1 → mysql-2
watch kubectl get pods -n prod-db -l app=mysql
```

## 九、步骤5：网络策略放行主从同步端口
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mysql-repl
  namespace: prod-db
spec:
  podSelector:
    matchLabels:
      app: mysql
  policyTypes: [Ingress,Egress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: mysql
    ports:
    - protocol: TCP
      port: 3306
```

## 十、步骤6：监控接入（mysqld-exporter Sidecar）
修改StatefulSet容器列表，新增exporter边车采集指标，配套ServiceMonitor接入Prometheus。

## 十一、多环境差异化规范
### DEV开发环境
1. replicas:1 单实例，无主从
2. 存储可临时NFS，资源配额宽松
3. 网络放开同ns互通，无严格主从同步策略

### UAT测试环境
1. replicas:2 双副本模拟主从
2. 块存储CSI，资源中等限制
3. 网络仅放行内部同步端口

### PROD生产环境（强制规范）
1. replicas≥3，完整主从集群，故障自动切换
2. 统一块存储RBD/LocalPV，**禁止NFS存放数据库数据**
3. 存储独立PVC，单Pod故障PV不丢失
4. 零信任网络策略，仅放行主从同步与授权业务访问
5. 配置定时数据库逻辑备份 + ETCD集群备份双保护
6. 开启完整监控、慢查询日志持久化

## 十二、有状态应用运维核心操作
### 1. 有序滚动更新版本
修改image镜像，StatefulSet按逆序逐个重建Pod，不中断集群
```bash
kubectl set image statefulset mysql mysql=harbor.example.com/prod/mysql:8.0.37 -n prod-db
```

### 2. 单独重建故障Pod（数据保留）
```bash
kubectl delete pod mysql-2 -n prod-db
# 控制器自动重建，复用原有PV数据，不会丢失库表
```

### 3. PVC扩容（在线扩容存储）
编辑volumeClaimTemplates内storage容量，CSI自动扩容，Pod无需重建。

### 4. 集群主从故障转移
mysql-0主节点宕机，手动切换mysql-1为新主，更新配置后重启实例。

## 十三、交付验收标准（纳入validate-project-environment.md）
1. Pod按0/1/2有序启动，全部Running/Ready，无CrashLoop
2. 每个Pod生成独立PVC，删除Pod数据持久保留
3. Headless域名解析正常，主从同步连通无延迟
4. 数据库主从复制正常，binlog同步无报错
5. 节点宕机后重建Pod，原有数据完整保留
6. 监控可采集QPS、连接数、慢查询、主从延迟指标
7. 业务服务可正常连接数据库读写数据

## 十四、高频故障与解决方案
### 故障1：StatefulSet Pod 无法启动，PVC pending
根因：StorageClass不可用、存储节点亲和限制、CSI控制器异常
处理：核对存储驱动，检查PVC绑定事件

### 故障2：删除Pod后数据丢失
根因：使用hostPath本地存储，无共享CSI；规范使用块存储动态PVC

### 故障3：主从同步失败，IO延迟过高
根因：使用NFS存储数据库；切换RBD块存储，优化my.cnf同步参数

### 故障4：滚动更新卡住，分区更新未完成
根因：partition参数配置错误，单个Pod探针失败阻断更新
排查：kubectl describe statefulset 查看事件与探针日志

### 故障5：业务无法连接数据库，3306端口不通
根因：NetworkPolicy未放行内部同步/业务访问端口，添加Ingress放行规则

## 十五、生产运维标准化规范
1. 数据库、核心中间件统一使用StatefulSet，禁止Deployment承载持久化业务
2. 生产数据库强制块存储RBD/LocalPV，禁止NFS共享存储（IO、锁机制缺陷）
3. 三套环境副本差异化：DEV单实例、UAT双副本、PROD≥3副本集群高可用
4. Headless无头服务必配，依靠固定域名完成主从集群同步，不依赖浮动IP
5. 定时执行数据库逻辑备份，配合ETCD快照，双份数据保护防止丢失
6. 严禁直接删除StatefulSet（会连带删除所有PVC），如需下线先清空业务再逐步清理
7. 项目交付必须校验PV持久化、主从同步、故障Pod重建数据完整性
8. 核心中间件全部接入专用Exporter监控，告警主从延迟、连接耗尽、磁盘满

## 十六、关联文档索引
create-project-workspace.md 项目Namespace基线资源
build-storage-platform.md RBD/NFS CSI持久化存储部署
build-monitoring-platform.md 中间件Exporter监控接入
configure-project-resource-policy.md 资源配额、网络策略基线
publish-application-release.md StatefulSet版本滚动发布流程
validate-project-environment.md 有状态应用交付验收标准
06-network-debug.md PVC挂载、数据库端口连通故障排查手册