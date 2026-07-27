# expose-application-service.md
# 应用对外流量暴露标准化配置手册（ClusterIP / NodePort / MetalLB LB / Ingress）
## 一、文档定位
本文针对企业K8s业务应用，完整覆盖**四层Service + 七层Ingress**全流量暴露方案：内部服务ClusterIP、四层长连接MetalLB LoadBalancer、七层HTTP/HTTPS Ingress、临时测试NodePort；区分DEV/UAT/PROD环境隔离规范，配套Java微服务部署、监控、网络策略文档，业务上线必经流量暴露配置SOP。
前置依赖：
deploy-java-application.md｜业务Deployment正常部署
build-ingress-platform.md｜Ingress-Nginx网关就绪
build-loadbalancer.md｜MetalLB四层LB平台部署完成
03-network-data-path.md｜集群南北向流量转发链路
下游关联：publish-application-release.md、validate-project-environment.md

## 二、四种Service类型适用场景（选型规范）
| 类型 | 适用场景 | 环境推荐 | 说明 |
|------|--------|---------|------|
| ClusterIP | 仅集群内部Pod互相调用（微服务内网互通） | DEV/UAT/PROD通用 | 不对外暴露，仅集群内访问 |
| NodePort | 开发临时调试，禁止生产对外 | DEV仅 | 节点固定端口，安全风险高 |
| LoadBalancer（MetalLB） | MySQL/Redis/Kafka等四层TCP长连接 | UAT/PROD | 独立公网/内网IP，四层流量 |
| Ingress（Ingress-Nginx） | HTTP/HTTPS Web、API网关、前端页面 | 全环境标准 | 统一收口七层域名，自动证书、限流WAF |

### 企业强制规范
1. **所有Web/HTTP业务统一使用Ingress收口**，禁止直接NodePort对公网暴露
2. **数据库、消息队列四层长连接**使用MetalLB LoadBalancer
3. 微服务内部调用仅使用ClusterIP，不占用LB公网IP资源
4. 区分内外网IngressClass，内网域名、公网域名物理隔离

## 三、前置准备
1. 业务Deployment就绪，Pod正常Running，容器业务端口固定（如8080）
2. 四层LB MetalLB地址池、Ingress-Nginx网关平台部署完成
3. 域名DNS解析：公网域名指向LB公网IP，内网域名指向内网LB
4. CertManager证书平台就绪，自动签发HTTPS证书
5. 网络策略基线就绪，按需放行Ingress/LB访问Pod规则
6. 项目命名空间已完成全维度验收（validate-project-environment.md）

## 四、第一部分：内部微服务 ClusterIP（必配，所有业务）
### 4.1 ClusterIP Service YAML模板（内网服务）
```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: prod-business
  labels:
    app: api-server
spec:
  selector:
    app: api-server # 匹配业务Pod标签
  ports:
  - port: 80          # Service访问端口（集群内统一80）
    targetPort: 8080  # 容器内部业务端口
    protocol: TCP
    name: http
  type: ClusterIP
  # 保留真实客户端IP，不跨节点SNAT
  internalTrafficPolicy: Local
```
### 4.2 验证集群内部访问
```bash
# 同命名空间Pod访问
kubectl exec -it test-pod -- curl http://api-svc
# 跨命名空间访问完整域名
curl http://api-svc.prod-business.svc.cluster.local
```
### 4.3 作用说明
1. 提供稳定内网域名，微服务之间通过Service名称调用
2. 自动负载均衡分发流量至所有业务Pod
3. 仅集群内网可达，外部无法直接访问

## 五、第二部分：四层TCP业务 MetalLB LoadBalancer（数据库/中间件）
### 5.1 内网中间件LB（仅办公内网访问）
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-lb
  namespace: prod-business
  labels:
    lb-type: inner # 匹配内网IP地址池
spec:
  selector:
    app: mysql
  ports:
  - port: 3306
    targetPort: 3306
    protocol: TCP
  type: LoadBalancer
  # 保留客户端真实源IP
  internalTrafficPolicy: Local
  # 会话保持（数据库长连接必备）
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600
```
### 5.2 公网四层业务LB（对外中间件，谨慎使用）
修改labels为`lb-type: public`，自动分配公网独立IP。
### 5.3 校验LB IP分配与连通性
```bash
# 查看自动分配的外部IP
kubectl get svc mysql-lb -n prod-business
# 内网服务器测试端口连通
nc 192.168.30.15 3306
```

## 六、第三部分：七层HTTP/HTTPS Ingress 对外Web服务（标准生产）
### 6.1 公网业务Ingress（自动HTTPS证书）
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-public-ingress
  namespace: prod-business
  annotations:
    # 指定外网Ingress网关
    kubernetes.io/ingress.class: nginx-public
    # CertManager自动签发SSL证书
    cert-manager.io/cluster-issuer: public-letsencrypt
    # HTTP强制跳转HTTPS
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # 获取真实客户端IP
    nginx.ingress.kubernetes.io/enable-real-ip: "true"
    # QPS限流防CC攻击
    nginx.ingress.kubernetes.io/limit-rps: "20"
    # 上传文件大小限制
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  tls:
  - hosts: ["api.example.com"]
    secretName: api-tls-cert
  rules:
  - host: api.example.com
    http:
      paths:
      - path: "/api"
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port:
              number: 80
```
### 6.2 内网管理后台Ingress（仅办公内网访问）
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: nginx-internal
spec:
  rules:
  - host: admin.inner.example.com
```
### 6.3 常用增强注解
1. IP黑名单封禁攻击源
`nginx.ingress.kubernetes.io/deny-cidrs: "203.0.113.0/24"`
2. CORS跨域开启
`nginx.ingress.kubernetes.io/enable-cors: "true"`
3. 长连接超时调整
`nginx.ingress.kubernetes.io/proxy-read-timeout: "300"`

### 6.4 域名连通校验
1. 浏览器访问`https://api.example.com`，无证书告警
2. HTTP 80自动跳转HTTPS 443
3. 高频请求触发限流返回429

## 七、第四部分：NodePort（仅DEV临时调试，生产禁用）
### 7.1 临时测试模板
```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-nodeport
  namespace: dev-business
spec:
  selector:
    app: api-server
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080 # 30000-32767区间
  type: NodePort
```
### 7.2 生产禁用原因
1. 端口分散，安全组难以统一管控
2. 无证书、无WAF、无限流，易遭受扫描攻击
3. 无法统一日志、监控大盘，运维复杂

## 八、多环境差异化规范
### DEV开发环境
1. 内网ClusterIP必备
2. 可临时创建NodePort调试
3. 内网Ingress可选，无强制HTTPS
### UAT测试环境
1. ClusterIP + 内网Ingress标准配置
2. 公网域名强制HTTPS自动证书
3. 四层中间件使用内网LB
### PROD生产环境（严格约束）
1. 禁止NodePort对公暴露业务
2. Web服务统一公网Ingress，强制HTTPS、限流、IP黑名单
3. 数据库/中间件使用BGP模式MetalLB四层LB
4. 内外网Ingress物理隔离，管理后台仅内网域名访问
5. 所有Service开启Local流量策略，保留真实客户端IP

## 九、网络策略配套放行规则
### 1. Ingress访问Pod放行
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-access-api
  namespace: prod-business
spec:
  podSelector:
    matchLabels:
      app: api-server
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
```
### 2. LB节点访问Pod放行
添加对应CIDR/节点标签放行四层LB流量。

## 十、全链路验收测试（交付必测）
1. 集群内部：Pod通过ClusterIP域名正常调用服务
2. 内网访问：办公网络访问内网LB/内网Ingress域名
3. 公网访问：外网客户端访问公网Ingress域名，HTTPS正常
4. 四层中间件：本地数据库客户端连接MetalLB LB IP+端口
5. 限流、黑白名单、强制跳转HTTPS功能验证
6. 业务日志打印原始客户端公网IP（开启Local流量策略）

## 十一、高频故障排查
### 故障1：访问Ingress域名返回502 Bad Gateway
根因：ClusterIP Service无就绪Endpoint、NetworkPolicy拦截Ingress访问Pod
排查：`kubectl get ep api-svc`、检查ingress放行NetworkPolicy

### 故障2：LoadBalancer Service长期Pending，无外部IP
根因：MetalLB IP地址池标签不匹配、地址池IP耗尽
排查：`kubectl describe svc mysql-lb` 查看事件

### 故障3：业务日志全部显示代理内网IP，丢失真实客户端IP
根因：Service未配置internalTrafficPolicy: Local、LB未透传X-Forwarded-For头部
修复：补充Service本地流量策略，Ingress开启real-ip

### 故障4：上传文件413 Request Entity Too Large
根因：Ingress注解proxy-body-size过小，调大参数

### 故障5：HTTPS访问证书过期警告
根因：CertManager签发失败，证书Secret未正常生成
排查：`kubectl get cert -n prod-business` 证书状态

## 十二、生产运维标准化规范
1. 分层流量隔离：内网微服务ClusterIP、四层中间件MetalLB LB、Web七层Ingress
2. 生产环境禁用NodePort对外暴露，所有HTTP/HTTPS收口统一Ingress
3. 公网Ingress强制HTTPS、自动证书、限流、IP黑名单防护CC攻击
4. 所有Service配置internalTrafficPolicy: Local，保留真实客户端IP用于审计
5. 内外网IngressClass严格隔离，管理后台仅内网域名开放
6. 四层长连接中间件统一使用BGP模式MetalLB，避免二层ARP单点瓶颈
7. 业务上线必须完成四层流量连通验收，纳入validate-project-environment.md
8. 定期清理废弃LB、Ingress资源，释放公网IP与域名

## 十三、关联文档索引
deploy-java-application.md Java业务Deployment部署模板
build-ingress-platform.md Ingress-Nginx内外网网关部署
build-loadbalancer-platform.md MetalLB四层LB平台配置
build-certificate-platform.md CertManager自动SSL证书签发
03-network-data-path.md 南北向四层/七层流量完整转发链路
05-network-security.md Ingress/LB配套NetworkPolicy放行规则
validate-project-environment.md 项目环境流量暴露交付验收标准
06-network-debug.md Ingress 502、LB IP分配故障排查手册