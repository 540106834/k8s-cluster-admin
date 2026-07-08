# 05-network-security.md
## 一、文档基础信息
- 归属目录：`05-security-management/`
- 前置阅读：`00-README.md`、`03-network-management/06-network-policy.md`、`03-network-management/08-network-troubleshooting.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4、全集群NetworkPolicy落地、内网Harbor镜像仓库
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心覆盖：NetworkPolicy深度安全隔离、多环境跨网段阻断、Pod入站/出站端口白名单、出站外网/内网访问管控、Ingress网关访问白名单、内网仓库固定访问策略、网络安全故障排查

## 二、网络安全底层核心理论
### 2.1 定位
Namespace仅做资源逻辑隔离，**无天然网络隔离能力**，NetworkPolicy是Pod粒度四层网络访问控制唯一原生方案，由Calico内核iptables/ipset实现流量拦截，实现深度防御：
1. 入站Ingress：控制谁能访问本Namespace内Pod；
2. 出站Egress：控制本Namespace Pod能访问哪些外部地址/服务；
3. 全局默认拒绝基线：UAT/PROD所有NS开启`default-deny-all-ingress`，采用白名单放行模型。

### 2.2 三层网络隔离防御框架
1. 跨环境网段阻断：FAT Pod网段 10.244.0.0/16 禁止主动访问 UAT(10.245.0.0/16)、PROD(10.246.0.0/16)；
2. 同Namespace细粒度白名单：中间件仅允许业务服务指定端口访问；
3. 出站边界管控：仅放行DNS、内网Harbor、业务依赖内网服务，阻断公网出站。

### 2.3 核心约束
- 无任何NetworkPolicy时：全部流量默认放行；
- 只要存在任意一条Policy，未匹配流量全部拒绝；
- 无法管控控制平面组件（kube-system calico/coredns/ingress-controller），需单独放白名单。

## 三、核心安全隔离标准模板
### 3.1 全局默认拒绝入站（UAT/PROD强制部署）
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all-ingress
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

### 3.2 同Namespace内部互通基础白名单
部署默认拒绝后必须配套，保证业务Pod内部调用：
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace-internal
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
```

### 3.3 多环境隔离核心：FAT出站阻断UAT/PROD网段
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-egress-access-uat-prod
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

### 3.4 中间件端口白名单（MySQL仅允许订单服务访问3306）
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

### 3.5 Egress出站放行内网Harbor镜像仓库（全环境通用）
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-harbor
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
      ipBlock:
        cidr: 192.168.10.0/24
    ports:
    - port: 443
      protocol: TCP
```

### 3.6 放行CoreDNS 53端口（所有NS必配）
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-coredns
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
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
```

### 3.7 Ingress网关访问业务Pod白名单
```yaml
ingress:
- from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: kube-system
    podSelector:
      matchLabels:
        app: nginx-ingress-controller
```

## 四、DEV/FAT/UAT/PROD 网络安全差异化基线
### DEV本地
无NetworkPolicy，全流量放行，仅本地调试使用。

### FAT测试
1. 不部署default-deny-all-ingress，默认全通；
2. 强制出站阻断UAT/PROD业务网段；
3. 放行DNS、Harbor基础出站；
4. 可临时删除所有Policy调试。

### UAT预生产
1. 全局开启默认拒绝入站，白名单管控；
2. 出站禁止访问FAT网段；
3. 仅放行必要跨环境只读访问PROD备份服务；
4. Ingress、中间件严格端口白名单。

### PROD生产（强制安全红线）
1. 所有命名空间启用`default-deny-all-ingress`，最小白名单模型；
2. 彻底阻断FAT主动访问生产数据库、缓存；
3. 中间件仅开放业务指定端口，禁止全局全端口放行；
4. 出站仅允许内网机房地址，阻断公网直接出站；
5. Ingress网关单独白名单，无白名单外部域名无法转发；
6. 新增跨NS访问策略双人复核，变更留存审计日志；
7. 定期清理废弃临时调试NetworkPolicy。

## 五、网络安全运维标准命令
```bash
# 查看全集群所有网络隔离策略
kubectl get networkpolicy --all-namespaces

# 查看Policy完整规则、IP段、端口、标签匹配
kubectl describe networkpolicy allow-order-access-mysql -n prod

# 临时清空FAT所有策略（调试应急）
kubectl delete networkpolicy --all -n fat

# 测试跨环境阻断效果（FAT访问PROD数据库预期拒绝）
kubectl exec -it test-pod -n fat -- telnet mysql.prod.svc.cluster.local 3306

# 批量导出所有网络安全策略备份
kubectl get networkpolicy -A -o yaml > all-np-backup.yaml
```

## 六、高频网络安全故障排查
### 1. 同Namespace服务502、无法互相调用
缺少`allow-same-namespace-internal`互通白名单策略。

### 2. 所有Pod域名解析失败
未配置放行coredns 53 UDP/TCP出站策略。

### 3. FAT Pod可连通PROD中间件
未部署IPBlock出站阻断策略，未拦截生产Pod网段10.246.0.0/16。

### 4. Ingress访问业务返回502
未添加Ingress Controller Pod访问业务NS的Ingress白名单。

### 5. Pod无法拉取Harbor镜像
Egress未放行镜像仓库内网IP段443端口。

### 6. 新增跨业务白名单策略不生效
标签匹配错误、CIDR网段书写错误；重启calico-node同步内核过滤规则。

### 7. 删除一条Policy后业务全部断流
删除了default-deny基础策略，批量重新apply全套网络策略。

## 七、生产网络安全最佳实践
1. UAT/PROD统一启用默认拒绝入站，全程白名单管控流量；
2. 三层业务环境网段物理隔离，依靠IPBlock阻断测试访问生产；
3. 数据库、Redis核心中间件严格限制访问源Pod标签，禁止全局开放端口；
4. 统一放行DNS、内网仓库基础出站，其余外网出站按需单独审批；
5. 区分七层Ingress网关访问白名单，防止外部域名无限制转发；
6. 网络策略变更前导出yaml备份，集群升级前执行etcd快照；
7. 监控跨环境异常访问日志，FAT访问生产中间件实时告警。

## 八、关联文档
1. 底层网络实现：`03-network-management/06-network-policy.md` Calico底层规则实现
2. 七层网关：`03-network-management/04-ingress-management.md` Ingress后端访问放行规范
3. 四层服务：`03-network-management/03-service-management.md` Service端口访问白名单管控
4. 审计日志：`06-audit-log.md` NetworkPolicy创建/删除高危操作审计告警
5. 安全加固：`07-security-best-practices.md` 网络安全月度巡检清单
6. 网络故障排错：`03-network-management/08-network-troubleshooting.md` Policy拦截端口不通完整SOP