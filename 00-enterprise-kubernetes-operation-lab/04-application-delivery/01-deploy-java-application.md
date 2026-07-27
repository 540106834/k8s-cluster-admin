# deploy-java-application.md
# Java 微服务标准化部署手册（SpringBoot）
## 一、文档定位
本文面向企业K8s集群，提供**SpringBoot Java微服务**标准化部署全流程：容器镜像规范、配置管理ConfigMap/Secret、无状态Deployment资源、探针、资源配额、环境变量、日志、JVM调优、网络策略、监控接入；适配dev/uat/prod三套项目命名空间，是业务微服务首次上线标准SOP。
前置依赖：
validate-project-environment.md｜项目命名空间验收通过
build-harbor-registry.md｜私有镜像仓库就绪
build-monitoring-platform.md｜Prometheus监控平台
build-log-platform.md｜Loki日志平台
03-network-data-path.md｜集群东西向流量链路
下游关联：publish-application-release.md、expose-application-service.md

## 二、Java应用前置规范（镜像/打包标准）
### 2.1 标准化Dockerfile（企业统一模板）
```dockerfile
# 基础JDK镜像（统一企业内部JDK镜像，禁止公共openjdk）
FROM harbor.example.com/library/jdk17:2026
WORKDIR /app
# 传入构建参数：版本、应用名
ARG APP_NAME
ARG APP_VERSION
COPY target/${APP_NAME}-${APP_VERSION}.jar app.jar
# JVM启动入口脚本
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
# 非root用户运行，安全基线
RUN groupadd appuser && useradd -g appuser appuser
USER appuser
# 暴露业务端口
EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
```

### 2.2 entrypoint.sh JVM动态调优脚本（核心）
自动读取容器CPU/内存limits动态设置JVM堆，无需硬编码Xmx/Xms
```bash
#!/bin/bash
set -e
# 自动获取容器内存限制，JVM堆设置为容器内存70%
MEM_LIMIT=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
MEM_MB=$(( ${MEM_LIMIT}/1024/1024 ))
XMX=$(( ${MEM_MB} * 7 / 10 ))
XMS=$XMX

# JVM通用生产参数
JVM_OPTS="-Xms${XMX}m -Xmx${XMX}m \
-XX:+UseG1GC \
-XX:+HeapDumpOnOutOfMemoryError \
-XX:HeapDumpPath=/data/logs/heapdump.hprof \
-Dspring.profiles.active=${SPRING_PROFILES_ACTIVE} \
-Dlogging.file.name=/data/logs/app.log \
-javaagent:/app/prometheus-jmx-exporter.jar=9404:/app/jmx-config.yaml"

exec java ${JVM_OPTS} -jar /app/app.jar
```

### 2.3 镜像推送规范
1. 开发环境镜像：`harbor.example.com/dev/app-api:v1.0.0-dev`
2. 测试环境镜像：`harbor.example.com/uat/app-api:v1.0.0-uat`
3. 生产环境镜像：`harbor.example.com/prod/app-api:v1.0.0`
4. 禁止使用latest标签，所有镜像使用语义化版本号

## 三、前置环境校验（部署前必查）
1. 目标命名空间完整验收通过（validate-project-environment.md）
2. Harbor私有镜像可在该命名空间正常拉取
3. 集群StorageClass就绪（日志持久化PVC）
4. Prometheus、Loki日志平台正常采集
5. 网络基线NetworkPolicy已创建，后续按需添加放行规则
6. 项目配置文件、数据库账号存入ConfigMap/Secret

## 四、核心资源分层说明
Java微服务部署配套5类K8s资源，缺一不可：
1. ConfigMap：application.yml、日志配置、JMX监控配置
2. Secret：数据库账号、Redis密码、JWT密钥（加密敏感信息）
3. PVC：持久化日志目录（防止容器重建丢失日志）
4. Deployment：无状态业务运行载体（核心）
5. ServiceMonitor：自动采集JVM/业务metrics指标接入监控

## 五、步骤1：创建配置 ConfigMap
### configmap-app.yaml
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-api-config
  namespace: prod-business
data:
  application-prod.yml: |
    spring:
      datasource:
        url: jdbc:mysql://mysql-prod:3306/db
      profiles:
        active: prod
    management:
      endpoints:
        web:
          exposure:
            include: health,info,prometheus
  jmx-config.yaml: |
    lowercaseOutputName: true
    rules:
    - pattern: "java.lang.*"
```
```bash
kubectl apply -f configmap-app.yaml
```

## 六、步骤2：创建敏感配置 Secret（数据库、中间件密码）
### secret-app.yaml
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-api-secret
  namespace: prod-business
type: Opaque
data:
  db-username: YWRtaW4=
  db-password: cGFzc3dvcmQxMjM=
```
```bash
kubectl apply -f secret-app.yaml
```

## 七、步骤3：创建日志持久化PVC（可选，企业规范必配）
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-api-log-pvc
  namespace: prod-business
spec:
  storageClassName: nfs-sc
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 20Gi
```

## 八、步骤4：Deployment 完整标准生产模板（核心）
### deploy-app.yaml
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-api
  namespace: prod-business
  labels:
    app: app-api
    env: prod
spec:
  replicas: 3 # 生产≥3副本高可用
  selector:
    matchLabels:
      app: app-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0 # 发布不中断业务
  template:
    metadata:
      labels:
        app: app-api
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9404"
    spec:
      # 安全基线：禁止root运行
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: app-api
        image: harbor.example.com/prod/app-api:v1.0.0
        imagePullPolicy: Always
        ports:
        - containerPort: 8080 # 业务端口
          name: http
        - containerPort: 9404 # JVM监控端口
          name: metrics
        # 资源限制（匹配LimitRange基线）
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            cpu: 2000m
            memory: 3Gi
        # 三大探针（生产强制配置）
        livenessProbe:
          httpGet:
            path: /actuator/health/liveness
            port: http
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /actuator/health/readiness
            port: http
          initialDelaySeconds: 30
          periodSeconds: 5
        startupProbe:
          httpGet:
            path: /actuator/health
            port: http
          failureThreshold: 30
          periodSeconds: 10
        # 环境变量：读取Secret/ConfigMap
        env:
        - name: SPRING_PROFILES_ACTIVE
          value: "prod"
        - name: DB_USERNAME
          valueFrom:
            secretKeyRef:
              name: app-api-secret
              key: db-username
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: app-api-secret
              key: db-password
        # 挂载配置、日志PVC
        volumeMounts:
        - name: config-volume
          mountPath: /app/config
        - name: log-storage
          mountPath: /data/logs
      volumes:
      - name: config-volume
        configMap:
          name: app-api-config
      - name: log-storage
        persistentVolumeClaim:
          claimName: app-api-log-pvc
```

### 部署执行
```bash
kubectl apply -f deploy-app.yaml
# 实时观察Pod启动进度
watch kubectl get pods -n prod-business -l app=app-api
# 查看启动日志排查报错
kubectl logs -f -n prod-business deploy/app-api
```

## 九、步骤5：创建ClusterIP Service（内部服务访问）
```yaml
apiVersion: v1
kind: Service
metadata:
  name: app-api-svc
  namespace: prod-business
  labels:
    app: app-api
spec:
  selector:
    app: app-api
  ports:
  - port: 80
    targetPort: 8080
    name: http
  type: ClusterIP
```
```bash
kubectl apply -f service.yaml
```

## 十、步骤6：监控接入 ServiceMonitor（采集JVM指标）
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: app-api-monitor
  namespace: prod-business
  labels:
    prometheus: k8s
spec:
  selector:
    matchLabels:
      app: app-api
  endpoints:
  - port: metrics
    interval: 15s
```
```bash
kubectl apply -f servicemonitor.yaml
```

## 十一、步骤7：网络策略放行（允许前端服务访问本应用8080端口）
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-access-api
  namespace: prod-business
spec:
  podSelector:
    matchLabels:
      app: app-api
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
```

## 十二、部署后完整验收校验
### 1. Pod状态校验
所有副本Running、Ready，无CrashLoopBackOff、镜像拉取失败
### 2. 探针校验
启动探针、存活探针、就绪探针无失败事件
```bash
kubectl describe deploy app-api -n prod-business | grep Events
```
### 3. 配置&密钥挂载校验
进入Pod查看application.yml、数据库密码正常加载
```bash
kubectl exec -n prod-business deploy/app-api -- cat /app/config/application-prod.yml
```
### 4. 连通性测试
1. 同命名空间Pod访问Service ClusterIP正常返回接口
2. 前端Pod可正常调用后端API，无403/连接超时
3. 数据库、Redis中间件连接正常，无启动报错
### 5. 监控指标校验
Grafana大盘可查看JVM堆内存、GC次数、接口QPS、线程数
### 6. 日志校验
Loki可采集应用stdout日志，ERROR日志可过滤检索
### 7. JVM OOM保护校验
内存溢出自动生成heapdump堆转储文件至日志PVC

## 十三、DEV / UAT / PROD 环境差异化配置
1. **DEV**
   - 副本数1，资源requests/limits宽松
   - JVM堆内存调大，开启热加载调试
   - 网络策略放开同命名空间互通
2. **UAT**
   - 副本数2，资源中等限制
   - 完整探针配置，模拟生产参数
3. **PROD**
   - 副本≥3，maxUnavailable=0零停机发布
   - 严格JVM参数、OOM堆转储、日志持久化
   - 网络零信任，仅显式放行依赖服务

## 十四、高频部署故障与处理
### 故障1：Pod ErrImagePull 401
根因：命名空间未配置Harbor ImagePullSecret
修复：参考 enable-private-image-access.md 配置镜像拉取密钥

### 故障2：Pod启动后Readiness探针失败，无法就绪
根因：Spring未开放/actuator健康端点、JVM启动超时、数据库连接失败
排查：kubectl logs查看Spring启动日志，核对application.yml数据库地址

### 故障3：JVM内存溢出OOM Kill
根因：容器limits内存过小，JVM XMX超过容器限制
修复：上调Deployment内存limits，entrypoint脚本自动适配堆大小

### 故障4：其他服务无法调用API，连接超时
根因：NetworkPolicy默认拒绝，缺少放行Ingress规则
处理：添加业务访问放行NetworkPolicy

### 故障5：Prometheus无JVM监控指标
根因：ServiceMonitor标签不匹配、9404端口被网络策略拦截
排查：Pod内curl localhost:9404/metrics验证指标暴露

## 十五、生产落地运维规范
1. Java应用统一使用内置JVM自动调优entrypoint，禁止硬编码Xmx
2. 生产环境必须配置三套探针，maxUnavailable=0保证发布无中断
3. 禁止使用latest镜像标签，严格语义化版本管理
4. 敏感数据库、中间件密码统一存入Secret，不写入ConfigMap
5. 所有微服务必须接入Prometheus JVM监控与Loki日志
6. 生产副本数≥3，分散至不同节点，避免单节点故障业务中断
7. 业务上线前完整执行连通性、监控、日志验收，验收通过方可对外提供服务

## 十六、关联文档索引
validate-project-environment.md 项目命名空间前置验收标准
publish-application-release.md 新版本滚动发布操作手册
rollback-application-release.md 发布故障快速回滚流程
expose-application-service.md Ingress/NodePort对外暴露业务
build-monitoring-platform.md JVM监控大盘配置
build-log-platform.md Java应用日志采集规范
05-network-security.md NetworkPolicy业务放行配置
06-network-debug.md Pod启动、探针、镜像拉取故障排查