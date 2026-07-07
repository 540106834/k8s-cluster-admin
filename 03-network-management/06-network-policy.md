# 06-network-policy.md
## 一、文档基础信息
- 归属目录：`03-network-management/`
- 前置阅读：`00-README.md`、`01-kubernetes-network-model.md`、`02-cni-overview.md`、`03-service-management.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4（支持完整NetworkPolicy）、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：NetworkPolicy底层原理、入站/出站规则、默认全局拒绝策略、多环境网络隔离（FAT禁止访问UAT/PROD）、Pod标签白名单、分环境模板、运维与故障排查

## 二、NetworkPolicy 底层理论
### 2.1 定位
NetworkPolicy 是K8s原生Pod粒度网络访问控制资源，由Calico CNI落地实现，用于**控制Pod之间、Pod与外部、Pod与Service之间的TCP/UDP流量放行/拦截**；
Namespace仅做资源逻辑隔离，无网络隔离能力，必须依靠NetworkPolicy实现多环境安全隔离。

### 2.2 核心规则边界
1. 规则作用域：绑定指定Namespace，仅管控本ns内Pod；
2. 流量方向：`ingress` 入站（外部访问本ns Pod）、`egress` 出站（本ns Pod访问外部）；
3. 匹配维度：Pod标签、Namespace标签、IP段、端口、协议；
4. 无匹配规则默认放行；配置任意policy后变为默认拒绝；
5. 不限制节点自身、kube-system集群基础设施流量。

### 2.3 关键隔离目标（生产强制落地）
1. FAT环境Pod**禁止主动访问UAT、PROD所有业务与中间件**；
2. UAT仅可有限只读访问PROD中间件，禁止写操作；
3. PROD默认拒绝所有跨Namespace访问，仅白名单业务互通；
4. 所有环境Pod仅允许访问CoreDNS 53端口做域名解析；
5. 限制Pod出站，仅放行内网仓库、上游DNS、业务依赖第三方地址。

## 三、核心策略模板分类
### 3.1 全局默认拒绝策略（UAT/PROD必部署）
作用：当前Namespace下所有Pod，无匹配规则则全部阻断入站流量，最小权限白名单模型。
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all-ingress
  namespace: prod
spec:
  podSelector: {} # 匹配本ns全部Pod
  policyTypes:
  - Ingress
```

### 3.2 允许同命名空间内部互通（基础白名单）
部署默认拒绝后，必须添加本条策略，保证同环境业务Pod互相调用：
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
```

### 3.3 允许访问CoreDNS DNS解析（全环境通用）
所有Pod必须放行kube-system 53端口，否则域名解析失败：
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-access
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: coredns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

### 3.4 跨环境隔离核心策略：禁止FAT访问UAT/PROD
#### 1）PROD出站禁止访问FAT网段
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-egress-fat
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress: []
  # 拒绝去往FAT Pod网段10.244.0.0/16
  except:
  - to:
      ipBlock:
        cidr: 10.244.0.0/16
```
#### 2）UAT出站禁止访问FAT网段
同上述模板，namespace改为uat，拦截10.244.0.0/16。
#### 3）FAT出站完全禁止访问UAT/PROD Pod网段
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-egress-uat-prod
  namespace: fat
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress: []
  except:
  - to:
      ipBlock:
        cidr: 10.245.0.0/16
  - to:
      ipBlock:
        cidr: 10.246.0.0/16
```

### 3.5 业务跨ns白名单放行（PROD内部业务互通）
仅允许order服务访问mysql中间件，精准标签匹配：
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-order-access-mysql
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: mysql
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          env: prod
      podSelector:
        matchLabels:
          app: order-api
    ports:
    - protocol: TCP
      port: 3306
```

### 3.6 出站放行内网Harbor镜像仓库
所有环境Pod需要拉取镜像，统一放行仓库固定IP：
```yaml
egress:
- to:
  ipBlock:
    cidr: 192.168.10.0/24
  ports:
  - port: 443
    protocol: TCP
```

## 四、DEV/FAT/UAT/PROD 策略标准化规范
### DEV本地
本地Kind/minikube，不启用NetworkPolicy，无网络隔离限制。

### FAT测试
1. 不部署default-deny-all-ingress，默认全放行；
2. 强制出站阻断UAT/PROD Pod网段；
3. 仅放行同ns互通、DNS、内网Harbor；
4. 临时调试可删除所有NetworkPolicy。

### UAT预生产
1. 部署default-deny-all-ingress默认拒绝入站；
2. 放行同ns互通、DNS、Harbor；
3. 出站禁止访问FAT网段；
4. 如需访问PROD只读中间件，单独添加白名单策略；
5. 规则配置完全对齐生产模板。

### PROD生产（强安全约束）
1. 强制部署`default-deny-all-ingress`，白名单管控所有入站流量；
2. 阻断FAT/UAT主动访问数据库、缓存等核心中间件；
3. 中间件仅允许对应业务Pod定向访问，禁止全局开放端口；
4. 出站仅放行DNS、内网Harbor、业务依赖第三方地址；
5. 禁止任何无规则全开放策略；
6. 新增跨环境访问必须双人复核，添加专属白名单Policy。

## 五、NetworkPolicy 标准运维操作
```bash
# 创建/更新隔离策略
kubectl apply -f np-default-deny-prod.yaml -n prod

# 查看所有网络策略
kubectl get networkpolicy -n prod

# 完整查看规则、匹配标签、IP网段、端口
kubectl describe networkpolicy default-deny-all-ingress -n prod

# 批量导出某环境所有隔离策略备份
kubectl get networkpolicy -n prod -o yaml > np-prod-backup.yaml

# 删除临时策略
kubectl delete networkpolicy allow-temp-test -n fat
```

## 六、网络隔离校验调试命令
```bash
# 在FAT Pod测试访问PROD MySQL（预期连接被拒绝）
kubectl exec -it test-pod -n fat -- telnet mysql.prod.svc.cluster.local 3306

# UAT Pod测试访问PROD只读库（放开白名单后连通）
kubectl exec -it test-pod -n uat -- curl mysql.prod.svc.cluster.local:3306

# 测试DNS 53端口连通性
kubectl exec -it test-pod -n prod -- nslookup harbor.jinshaoyong.com
```

## 七、高频网络策略故障排查
### 1. Pod同ns内部无法互相访问
部署了default-deny-all-ingress，但缺少`allow-same-namespace`放行策略。

### 2. 域名解析全部失败
NetworkPolicy未放行kube-system coredns 53 UDP/TCP端口。

### 3. FAT Pod可以连通PROD数据库
未部署出站阻断策略deny-egress-uat-prod，未拦截PROD Pod网段。

### 4. 业务发布后服务502、无法访问后端Service
Ingress/网关Pod未加入白名单，Policy拦截网关访问业务Pod端口。

### 5. Pod无法拉取Harbor镜像
Egress策略未放行镜像仓库IP与443端口。

### 6. 新增跨环境访问白名单不生效
标签匹配错误、IP段CIDR书写错误、策略未apply生效；Calico规则同步延迟，重启calico-node刷新。

### 7. 生产删除Policy后业务全部断流
删除了default-deny-all后未同步补全放行规则，重新批量apply全套网络策略。

## 八、生产安全最佳实践
1. UAT/PROD环境必须启用默认拒绝入站策略，采用白名单最小访问模型；
2. 三层业务环境（FAT/UAT/PROD）网段互相隔离，依靠IPBlock拦截跨环境非法访问；
3. 数据库、Redis等中间件严格限制访问源Pod标签，禁止全局开放端口；
4. 所有Policy纳入Git版本管理，变更前导出yaml备份；
5. 大版本集群升级前执行etcd快照，网络策略变更双人复核；
6. 定期清理废弃临时调试NetworkPolicy，减少规则冗余；
7. 监控跨环境异常访问日志，出现FAT访问PROD数据库立即告警。

## 九、关联文档
1. 网络底座：`02-cni-overview.md` Calico实现NetworkPolicy底层过滤规则
2. 四层服务：`03-service-management.md` Service跨ns访问依赖网络策略放行
3. DNS服务发现：`05-dns-service-discovery.md` 53端口统一放行规范
4. 七层网关：`04-ingress-management.md` Ingress Controller访问后端Pod白名单配置
5. 网络排错：`08-network-troubleshooting.md` Policy拦截导致端口不通、502完整排查SOP