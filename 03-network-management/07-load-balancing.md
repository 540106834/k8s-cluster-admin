# 07-load-balancing.md
## 一、文档基础信息
- 归属目录：`03-network-management/`
- 前置阅读：`00-README.md`、`01-kubernetes-network-model.md`、`03-service-management.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4、kube-proxy ipvs模式、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：Service四层负载均衡三类型对比、NodePort端口范围管控、云厂商LoadBalancer对接、ipvs转发优化、源IP保留、四层业务落地规范、故障排查

## 二、四层负载均衡底层原理
### 2.1 核心组件 kube-proxy
三种转发模式：
1. iptables：默认兼容模式，大规模集群性能差；
2. ipvs（生产强制）：内核负载均衡，支持加权轮询、最小连接、会话保持，高并发低延迟；
3. ipvs+Calico BGP/VXLAN协同，实现Pod跨节点四层转发。

### 2.2 四层负载均衡与七层Ingress区分
1. **四层LB（Service NodePort/LoadBalancer）**
   基于TCP/UDP端口转发，不解析HTTP协议，适用MySQL、Redis、TCP长连接、RPC等非Web业务。
2. **七层Ingress**
   解析HTTP/HTTPS，域名、路径、灰度、证书，Web/API业务标准对外入口。
> 生产规范：Web业务统一Ingress，TCP长连接/数据库四层服务使用LoadBalancer。

## 三、三种Service负载均衡完整对比
| 类型 | 访问范围 | 端口范围 | 适用场景 | 生产管控约束 |
|------|----------|----------|----------|--------------|
| ClusterIP | 仅集群内部Pod访问 | 自定义端口 | 微服务内部互调，所有业务默认 | 全环境统一使用，无暴露风险 |
| NodePort | 任意机器访问节点IP+端口 | 30000–32767 | FAT临时测试、内网快速调试 | PROD禁止长期启用，用完即删 |
| LoadBalancer | 公网/内网负载均衡IP | 自定义端口 | 数据库、Redis、TCP长连接四层业务 | 仅四层专有业务使用，HTTP禁用 |

### 关键特性补充
1. ClusterIP：虚拟内网IP，仅集群内可达，无外部暴露风险；
2. NodePort：每个节点监听同一端口，流量转发后端Pod；
3. LoadBalancer：云厂商/硬件LB对接集群，自动分配独立公网/内网VIP，流量转发至节点NodePort。

## 四、标准模板示例
### 4.1 ClusterIP（内部微服务，通用）
```yaml
apiVersion: v1
kind: Service
metadata:
  name: order-api-svc
  namespace: prod
  labels:
    app: order-api
    env: prod
spec:
  type: ClusterIP
  selector:
    app: order-api
  ports:
  - port: 80
    targetPort: 8080
  sessionAffinity: ClientIP
```

### 4.2 NodePort（FAT临时调试专用）
```yaml
spec:
  type: NodePort
  ports:
  - port: 3306
    targetPort: 3306
    nodePort: 30306 # 固定30000-32767区间
```

### 4.3 LoadBalancer（云集群四层数据库暴露）
```yaml
spec:
  type: LoadBalancer
  # 保留客户端真实源IP（生产强制）
  externalTrafficPolicy: Local
  # 仅放行指定外部IP访问
  loadBalancerSourceRanges:
  - 192.168.5.0/24
  ports:
  - port: 3306
    targetPort: 3306
```

## 五、核心配置参数详解
### 5.1 externalTrafficPolicy
1. `Cluster`（默认）：流量均衡分发全节点Pod，源IP被SNAT修改；
2. `Local`（生产推荐）：仅转发至当前节点本地Pod，保留真实客户端源IP，便于审计限流。

### 5.2 sessionAffinity 会话保持
- `ClientIP`：同一客户端IP固定转发同一Pod，适合有状态TCP长连接；
- 超时配置 `sessionAffinityConfig.clientIP.timeoutSeconds`，生产设3h。

### 5.3 loadBalancerSourceRanges
白名单外部访问IP段，禁止全网开放四层端口，缩小攻击面。

### 5.4 ipvs调度算法（kube-proxy配置）
```yaml
mode: ipvs
ipvs:
  scheduler: lc # lc最小连接、rr轮询、wrr加权轮询
```
- wrr：按Pod资源权重分发，通用业务；
- lc：长连接数据库、缓存优先，均衡连接数。

## 六、DEV/FAT/UAT/PROD 分环境标准化规范
### DEV本地
仅ClusterIP，临时调试可用NodePort，无端口管控。
### FAT测试
1. 内部业务统一ClusterIP；
2. NodePort仅短期测试，下班前清理；
3. 不分配LoadBalancer实例，节约成本。
### UAT预生产
1. 对齐生产ipvs调度、externalTrafficPolicy=Local；
2. 四层TCP业务可临时创建LoadBalancer，配置IP白名单；
3. 闲置NodePort立即删除。
### PROD生产（强约束）
1. Web/HTTP业务**禁止使用LoadBalancer/NodePort**，统一Ingress七层；
2. MySQL/Redis/RPC等TCP长连接四层业务使用LoadBalancer；
3. 强制 `externalTrafficPolicy: Local` 保留源IP；
4. 配置`loadBalancerSourceRanges`白名单，禁止0.0.0.0/0全网开放；
5. 关闭所有闲置NodePort，禁用30000-32767端口对外暴露；
6. kube-proxy统一ipvs模式，调度算法wrr/lc按需配置；
7. 四层LB变更双人复核，提前导出Service yaml备份。

## 七、云厂商LB对接规范
1. 内网LB：绑定机房内网VIP，仅办公/内网服务器访问；
2. 公网LB：绑定独立公网IP，配置安全组限流、CC防护；
3. 后端节点组自动同步集群NodePort节点，节点上下线自动更新；
4. 健康检查配置TCP端口探测，匹配Service后端就绪Pod；
5. 释放集群前必须删除LoadBalancer实例，避免持续计费。

## 八、kube-proxy ipvs 转发优化落地
1. 集群初始化阶段配置kube-proxy使用ipvs，禁止iptables长期运行；
2. 调大ipvs内核连接表，防止高并发连接溢出；
3. 开启ipvs metrics接入监控，观测四层连接数、转发失败；
4. 大规模集群开启ipvs精简规则，降低节点iptables表膨胀。

## 九、运维标准操作命令
```bash
# 查看所有四层Service类型
kubectl get svc -n prod

# 查看LoadBalancer分配VIP、外部访问白名单
kubectl describe svc mysql-lb -n prod

# 查看kube-proxy转发模式
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode

# 快速创建临时NodePort（FAT调试）
kubectl patch svc order-svc -n fat -p '{"spec":{"type":"NodePort"}}'

# 锁定LoadBalancer访问源IP白名单
kubectl patch svc mysql-lb -n prod -p '{"spec":{"loadBalancerSourceRanges":["192.168.5.0/24"]}}'

# 批量清理所有NodePort服务
kubectl get svc -n fat --field-selector spec.type=NodePort | grep -v NAME | awk '{print $1}' | xargs kubectl delete svc -n fat
```

## 十、高频四层负载均衡故障排查
### 1. LoadBalancer公网无法访问
安全组未放行对应端口、loadBalancerSourceRanges白名单拦截、后端无就绪Pod。
### 2. 四层业务获取不到真实客户端IP
externalTrafficPolicy未配置Local，流量经过SNAT丢失源IP。
### 3. NodePort外部访问超时
节点防火墙拦截30000-32767端口、NetworkPolicy拦截网关访问Pod。
### 4. 高并发TCP连接大量丢包
kube-proxy使用iptables性能不足，切换ipvs模式；调大ipvs内核连接上限。
### 5. 会话不保持，客户端频繁切换Pod
未开启sessionAffinity: ClientIP。
### 6. 扩容Pod后流量不分发至新副本
ipvs规则同步延迟，重启kube-proxy或等待同步周期。
### 7. 云LB健康检查失败，后端全部下线
就绪探针失败、端口不匹配、NetworkPolicy拦截LB探测IP。

## 十一、生产最佳实践
1. 严格区分七层Ingress与四层LoadBalancer使用场景，杜绝混用；
2. PROD环境严控NodePort，仅FAT临时调试使用；
3. 四层LB必须配置IP白名单，禁止全网无限制访问；
4. 统一ipvs转发模式，提升高并发四层转发性能；
5. 四层数据库业务加长terminationGracePeriodSeconds，配合会话保持；
6. 监控LoadBalancer连接数、四层转发失败率，异常触发告警；
7. 集群下线前释放云厂商LoadBalancer实例，避免持续计费。

## 十二、关联文档
1. 四层服务基础：`03-service-management.md` Service完整规范
2. 七层网关区分：`04-ingress-management.md` Web业务七层对外暴露标准
3. 网络隔离：`06-network-policy.md` LB探测IP、客户端IP访问白名单放行策略
4. 网络排错：`08-network-troubleshooting.md` 四层端口不通、LB健康检查失败排查SOP
5. CNI底层：`02-cni-overview.md` Calico与kube-proxy转发协同机制