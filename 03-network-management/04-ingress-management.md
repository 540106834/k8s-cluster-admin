# 04-ingress-management.md
## 一、文档基础信息
- 归属目录：`03-network-management/`
- 前置阅读：`00-README.md`、`01-kubernetes-network-model.md`、`03-service-management.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4、Ingress-Nginx Controller、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：Ingress资源原理、Ingress-Nginx Controller部署运维、域名路由规则、TLS HTTPS证书、多环境域名隔离、权重灰度分流、重定向、限流、故障排查

## 二、Ingress 底层理论
### 2.1 定位
Ingress 是K8s七层HTTP/HTTPS流量网关资源，用于统一域名、路径路由、SSL证书、流量灰度、限流、重定向；
替代NodePort/LoadBalancer承载Web业务，统一外部流量接入层，生产唯一标准对外暴露方案。

### 2.2 两层组件关系
1. **Ingress（CR资源）**：声明域名、路径、后端Service、证书、分流规则，存于etcd；
2. **IngressController（Nginx DaemonSet）**：持续监听Ingress变更，自动生成Nginx配置，处理七层流量。

### 2.3 核心能力
- 多域名、多路径路由转发至不同Namespace Service；
- 自动绑定Secret TLS证书，全站HTTPS；
- 基于权重灰度流量切分；
- 访问限流、连接限制、IP黑白名单；
- HTTP强制跳转HTTPS、URL重写、跨域配置；
- 支持会话保持、缓冲区调优、后端健康检查。

### 2.4 环境域名隔离规范（固定域名体系）
| 环境 | 域名后缀 | 用途 | 证书类型 |
|------|----------|------|----------|
| FAT | `*.fat.example.com` | 功能测试 | 自签测试证书 |
| UAT | `*.uat.example.com` | 预生产验收 | 正式泛域名证书 |
| PROD | `*.example.com` | 线上业务 | 权威CA签发正式证书 |
DEV本地：hosts自定义域名，不接入集群Ingress。

## 三、标准完整Ingress模板（PROD HTTPS示例）
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: order-ingress
  namespace: prod
  labels:
    app: order-api
    env: prod
    business: order
  # Nginx ingress 扩展注解
  annotations:
    # 强制HTTP跳转HTTPS
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # 开启会话保持
    nginx.ingress.kubernetes.io/affinity: "cookie"
    # 限流单IP每秒10请求
    nginx.ingress.kubernetes.io/limit-rps: "10"
    # 后端连接超时
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "10"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  # 绑定TLS证书Secret
  tls:
  - hosts:
    - order.example.com
    secretName: prod-tls-cert
  rules:
  - host: order.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: order-api-svc
            port:
              number: 80
```

### 3.1 多路径路由示例
同一域名下不同路径转发不同服务：
```yaml
paths:
- path: /user
  pathType: Prefix
  backend:
    service:
      name: user-svc
      port: {number:80}
- path: /order
  pathType: Prefix
  backend:
    service:
      name: order-svc
      port: {number:80}
```

### 3.2 灰度权重分流模板（UAT/PROD灰度发布）
```yaml
annotations:
  # 90%流量切稳定版本，10%切新版本
  nginx.ingress.kubernetes.io/canary: "true"
  nginx.ingress.kubernetes.io/canary-weight: "10"
  nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
```
使用场景：新版本上线先切少量流量观测错误率，无异常再全量切换。

## 四、TLS证书管理规范
### 4.1 Secret证书存储格式
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: prod-tls-cert
  namespace: prod
type: kubernetes.io/tls
data:
  tls.crt: 证书base64
  tls.key: 私钥base64
```
### 4.2 分环境证书管控
1. FAT：自签openssl证书，仅内部测试；
2. UAT：与生产同一套泛域名正式证书；
3. PROD：权威CA签发证书，有效期监控，提前30天更新轮换。
### 4.3 证书更新流程
更新tls Secret后，Ingress Controller自动重载Nginx配置，无需重启Pod。

## 五、Ingress Controller 运维规范
### 5.1 部署形态
Ingress-Nginx Controller 统一以DaemonSet部署在`kube-system`，所有业务节点运行，配合LoadBalancer/节点公网IP接收外部流量。
```yaml
spec:
  updateStrategy:
    rollingUpdate:
      maxUnavailable: 1 # 滚动更新单节点下线，不中断流量
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
```
### 5.2 资源约束（全环境强制）
```yaml
resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 2000m
    memory: 2Gi
```

## 六、DEV/FAT/UAT/PROD 差异化配置标准
### DEV本地
不部署集群Ingress，本地hosts+docker调试，无HTTPS强制要求。
### FAT测试
1. 域名 `*.fat.example.com`；
2. 自签证书，不强制HTTPS跳转；
3. 限流宽松，灰度功能可自由调试；
4. 可临时放开IP白名单限制。
### UAT预生产
1. 域名 `*.uat.example.com`；
2. 完整正式证书，强制HTTPS跳转；
3. 限流、超时参数对齐生产；
4. 支持权重灰度模拟线上发布流程。
### PROD生产（强约束）
1. 业务主域名 `*.example.com`，独立证书；
2. 全局开启`force-ssl-redirect`，禁止HTTP裸访问；
3. 严格IP黑白名单，仅放行运营商/办公出口IP；
4. 限流、连接超时、缓冲区参数标准化；
5. 灰度发布必须配置权重，禁止一次性全量切换；
6. Ingress Controller滚动更新maxUnavailable=1，避免全网关重启断流；
7. 证书到期监控告警，提前轮换；
8. 禁止直接暴露NodePort，所有Web流量统一收敛至Ingress。

## 七、核心运维操作命令
```bash
# 创建/更新Ingress路由规则
kubectl apply -f ingress-order-prod.yaml -n prod

# 查看所有Ingress域名、后端、TLS状态
kubectl get ingress -n prod

# 查看完整注解、路由、事件、证书绑定
kubectl describe ingress order-ingress -n prod

# 查看Ingress-Nginx Controller日志（5xx/4xx排错）
kubectl logs -n kube-system ds/nginx-ingress-controller

# 重载Ingress Controller配置（证书/路由变更自动触发，无需手动）
kubectl rollout restart ds nginx-ingress-controller -n kube-system

# 批量导出所有环境Ingress备份
kubectl get ingress --all-namespaces -o yaml > all-ingress-backup.yaml
```

## 八、高频Ingress故障排查
### 1. 访问域名返回404
- host域名、path路径不匹配Ingress规则；
- 后端Service selector无就绪Pod，EndpointSlice为空；
- pathType配置错误（Exact/Prefix/ImplementationSpecific）。

### 2. 访问502 Bad Gateway
后端Service无就绪Pod、NetworkPolicy拦截网关访问业务Pod、服务端口不匹配。

### 3. HTTPS证书报错不安全
Secret证书过期、crt/key不匹配、Ingress未绑定tls规则。

### 4. 灰度权重不生效
canary注解缺失、同域名多条Ingress资源冲突，删除多余Ingress。

### 5. HTTP可以访问，HTTPS打不开
未配置spec.tls、443端口未在LoadBalancer/安全组放行。

### 6. 更新Ingress规则后不生效
Ingress Controller未监听到资源变更，重启ds重载配置。

### 7. 大量429 Too Many Requests
限流注解limit-rps设置过小，调大阈值或优化前端请求频率。

## 九、生产安全最佳实践
1. 全站强制HTTPS，关闭裸HTTP业务入口；
2. 配置IP白名单，限制外部非法IP访问生产域名；
3. 大版本发布使用Ingress灰度权重分流，可控切流；
4. 监控Ingress Controller Pod状态、证书过期时间、4xx/5xx错误率；
5. 不同环境域名完全隔离，禁止FAT域名解析至PROD网关；
6. Ingress资源变更前导出yaml备份，集群升级前执行etcd快照；
7. 区分业务独立Ingress资源，避免单Ingress配置臃肿难以维护。

## 十、关联文档
1. 四层服务底座：`03-service-management.md` Ingress转发后端Service规范
2. 域名解析：`05-dns-service-discovery.md` 集群外部域名DNS解析配置
3. 网络访问控制：`06-network-policy.md` 网关Pod访问业务Pod放行策略
4. 负载均衡：`07-load-balancing.md` Ingress Controller对接LoadBalancer四层入口
5. 网络故障排错：`08-network-troubleshooting.md` Ingress 404/502/SSL异常完整排查SOP
6. 发布灰度：`02-workload-management/09-rollout-and-rollback.md` 业务发布搭配Ingress灰度流量策略