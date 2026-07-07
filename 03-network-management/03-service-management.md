# 03-service-management.md
## 一、文档基础信息
- 归属目录：`03-network-management/`
- 前置阅读：`00-README.md`、`01-kubernetes-network-model.md`、`02-pod-lifecycle.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4、kube-proxy ipvs模式、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：Service底层原理、四类Service完整模板、Endpoint/EndpointSlice、标签选择器、Headless无头服务、StatefulSet配套规范、分环境管控、故障排查

## 二、Service 底层核心理论
### 2.1 核心定位
Service 为一组Pod提供**稳定不变的四层访问入口**，屏蔽PodIP动态变化、实现负载均衡、故障后端自动摘除；
底层依赖 `kube-proxy` 生成转发规则，依赖 `EndpointSlice` 维护后端就绪Pod列表。

### 2.2 核心价值
1. 固定虚拟ClusterIP，Pod重建、扩缩容IP不变；
2. 自动筛选匹配标签的就绪Pod做后端；
3. 内置负载均衡、会话保持；
4. 配合CoreDNS生成标准集群域名，实现服务发现；
5. Headless模式支持StatefulSet获取独立Pod域名，适配有状态中间件主从集群。

### 2.3 层级联动关系
Service → EndpointSlice → 就绪Pod列表
1. Service通过`selector`匹配Pod标签；
2. 控制器同步生成EndpointSlice，存储所有就绪PodIP+端口；
3. kube-proxy监听EndpointSlice变更，刷新节点转发规则(ipvs/iptables)；
4. Pod访问Service域名/ClusterIP时，流量均衡分发至后端Pod。

### 2.4 Endpoint 与 EndpointSlice 区别
1. Endpoint（旧版）：一个Service仅生成1个资源，大规模Pod性能差；
2. EndpointSlice（集群默认启用）：自动分片，每个分片最多100个Pod，大规模集群性能优化；
3. 就绪探针失败的Pod会自动从EndpointSlice移除，不再接收流量。

## 三、Service 四种类型完整对比
| 类型 | 使用场景 | 访问范围 | 核心特性 | 生产使用规范 |
|------|----------|----------|----------|--------------|
| ClusterIP（默认） | 集群内部微服务互调 | 仅集群内Pod可访问 | 分配固定虚拟内网IP | 业务微服务标准选型，FAT/UAT/PROD统一使用 |
| Headless(clusterIP: None) | StatefulSet中间件（MySQL/Redis/ES/Kafka） | 集群内 | 无虚拟IP，域名直接解析全部PodIP，固定Pod域名 | 有状态组件强制配套，禁止无状态业务使用 |
| NodePort | 临时测试、内网快速调试 | 集群节点IP+端口 | 在每个节点暴露固定端口 | PROD环境禁止长期使用，仅FAT临时调试 |
| LoadBalancer | 云集群四层公网入口 | 公网/内网负载均衡 | 对接云厂商LB，分配独立公网IP | 仅四层TCP业务使用，HTTP/HTTPS统一走Ingress七层 |

## 四、标准模板分类型示例
### 4.1 ClusterIP 通用无状态服务（Deployment配套）
```yaml
apiVersion: v1
kind: Service
metadata:
  name: order-api-svc
  namespace: prod
  labels:
    app: order-api
    env: prod
    business: order
spec:
  type: ClusterIP
  selector:
    app: order-api # 与Deployment Pod标签完全匹配
  ports:
  - port: 80
    targetPort: 8080 # 容器内部端口
    protocol: TCP
  # 会话保持，可选
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

### 4.2 Headless 无头服务（StatefulSet专用，强制clusterIP: None）
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-headless-svc
  namespace: prod
  labels:
    app: mysql
    env: prod
spec:
  type: ClusterIP
  clusterIP: None # 无头核心标识
  selector:
    app: mysql
  ports:
  - port: 3306
    targetPort: 3306
```
配套域名规则：
`mysql-0.mysql-headless-svc.prod.svc.cluster.local`
`mysql-1.mysql-headless-svc.prod.svc.cluster.local`

### 4.3 NodePort 临时测试模板（FAT专用）
```yaml
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080 # 端口范围30000-32767
```

### 4.4 LoadBalancer 四层负载均衡（云集群）
```yaml
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local # 保留源IP
  ports:
  - port: 3306
    targetPort: 3306
```

## 五、标签选择器规范
1. 固定标签：`app、env、business`，selector仅匹配`app`；
2. selector一旦创建**不支持修改**，修改会丢失原有Endpoint后端；
3. 无selector的Service：手动管理EndpointSlice，用于外部中间件、第三方服务接入集群。

## 六、分环境 Service 标准化约束
### DEV本地
- 优先ClusterIP，临时调试可用NodePort；
- 无访问限制，无需严格域名规范。

### FAT测试
- 业务统一ClusterIP；
- NodePort仅短期测试，用完即删除；
- StatefulSet必须配套Headless；
- 不分配正式LoadBalancer。

### UAT预生产
- 完全对齐生产配置；
- 关闭闲置NodePort；
- 中间件Headless强制部署；
- 四层特殊业务可临时启用LoadBalancer。

### PROD生产（强约束）
1. 微服务统一使用ClusterIP，禁止长期NodePort暴露；
2. MySQL/Redis/ES/Kafka等StatefulSet**必须配套Headless Service**；
3. HTTP/HTTPS业务统一Ingress七层，不使用LoadBalancer承载Web流量；
4. 开启sessionAffinity会话保持按需配置；
5. 无selector外部服务单独管理EndpointSlice，禁止混用业务selector；
6. Service变更前导出yaml备份，大版本升级前etcd快照。

## 七、核心运维操作命令
```bash
# 创建/更新Service
kubectl apply -f svc-order-prod.yaml -n prod

# 查看所有Service
kubectl get svc -n prod

# 查看EndpointSlice后端就绪Pod
kubectl get endpointslices -n prod
kubectl describe endpointslices order-api-svc -n prod

# 查看Service完整详情、事件、后端Pod
kubectl describe svc order-api-svc -n prod

# 批量查看Headless服务
kubectl get svc -n prod --field-selector spec.clusterIP=None

# 删除Service（不会删除Pod，仅删除四层转发入口）
kubectl delete svc order-api-svc -n prod
```

## 八、Service + StatefulSet 配套完整流程
1. 先创建Headless Service（clusterIP: None）；
2. StatefulSet `spec.serviceName` 绑定该Service名称；
3. 部署StatefulSet，自动生成有序Pod；
4. 通过固定Pod域名实现主从识别、数据同步；
5. 扩容/缩容自动更新EndpointSlice，域名保持不变。

## 九、高频故障排查
### 1. 访问Service 502/连接超时
- selector标签与Pod不匹配，EndpointSlice为空；
- 所有Pod就绪探针失败，无就绪后端；
- NetworkPolicy拦截Pod访问Service端口。

### 2. Headless Service 无法解析独立Pod域名
缺失`clusterIP: None`，或sts.spec.serviceName与svc名称不一致。

### 3. NodePort 外部无法访问
安全组放行30000-32767端口、节点防火墙拦截、externalTrafficPolicy配置错误。

### 4. 扩容Pod后流量未分发至新副本
EndpointSlice未同步更新，重启kube-proxy或等待同步周期。

### 5. ClusterIP 外部机器无法访问
ClusterIP仅集群内部Pod可达，外部需Ingress/NodePort/LB。

### 6. 无selector Service 无法访问外部服务
手动维护EndpointSlice，填写外部服务IP与端口。

## 十、运维最佳实践
1. 所有业务微服务统一ClusterIP，域名标准化 `svc.ns.svc.cluster.local`；
2. 有状态中间件强制Headless，保障固定网络身份；
3. PROD禁用闲置NodePort，缩小攻击面；
4. 开启ipvs模式kube-proxy，提升大规模Service转发性能；
5. 同Namespace同名Service不冲突，依靠域名区分跨Namespace服务；
6. 定期清理废弃Service，避免无效EndpointSlice占用集群资源。

## 十一、关联文档
1. 网络模型基础：`01-kubernetes-network-model.md` Service通信模型
2. 有状态负载：`02-workload-management/04-stateful-workloads.md` StatefulSet配套规范
3. 域名解析：`05-dns-service-discovery.md` Service域名解析机制
4. 七层接入：`04-ingress-management.md` Ingress绑定后端Service
5. 网络隔离：`06-network-policy.md` 控制Pod访问Service端口权限
6. 网络排错：`08-network-troubleshooting.md` Service访问不通、Endpoint为空排错