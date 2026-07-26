# build-ingress-platform.md
# 企业统一Ingress网关平台部署运维手册
## 一、文档定位
本文用于企业K8s集群标准化七层流量入口建设，基于**Ingress-Nginx Controller**搭建统一南北向HTTP/HTTPS网关，完整覆盖资源部署、域名路由、TLS证书、限流、黑白名单、内网隔离Ingress、高可用、运维排查、与CertManager联动；
前置依赖：
build-kubernetes-cluster.md｜集群基础环境就绪
build-certificate-platform.md｜CertManager证书签发
03-network-data-path.md｜集群南北向流量转发链路
下游关联：validate-cluster-health.md、build-ingress-platform.md配套运维SOP

## 二、Ingress平台架构与设计规范
### 2.1 分层架构
1. **接入层**：云厂商LoadBalancer / 物理NodePort，外部流量统一收口
2. **网关层**：ingress-nginx DaemonSet，集群所有节点部署，四层转发至Nginx
3. **控制层**：Ingress CRD资源、IngressClass区分内外网网关
4. **证书层**：CertManager自动签发/轮换SSL证书
5. **安全层**：WAF、IP黑名单、请求限流、强制HTTPS跳转

### 2.2 企业双网关隔离规范（生产必选）
- `ingress-public`：外网网关，绑定公网LB，对外开放业务域名
- `ingress-internal`：内网网关，仅集群/办公内网访问，禁止公网暴露
通过`IngressClass`隔离两套网关流量，安全边界分离。

### 2.3 资源规划标准
1. 命名空间：`ingress-nginx` 独立隔离，不与业务混部
2. 部署模式：DaemonSet，每个节点部署一个Nginx Pod，就近转发流量
3. 资源配额：CPU 1000m/内存 512Mi 上限，预留突发流量缓冲
4. 副本高可用：全节点调度，无单点故障
5. 日志存储：容器JSON日志输出至Loki/ELK，留存访问日志

## 三、前置环境校验
1. 集群网络插件正常（Calico/Cilium），NodePort端口30000-32767安全组放行
2. CertManager集群已部署，具备域名SSL自动签发能力
3. 集群StorageClass就绪（日志持久化、缓存临时存储）
4. 域名DNS解析就绪，公网域名指向LB公网IP，内网域名指向内网LB
5. 内核参数调优：文件句柄数、TCP长连接参数适配七层网关

## 四、步骤1：部署Ingress-Nginx Controller（官方标准helm）
### 4.1 添加官方Helm仓库
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx
```

### 4.2 自定义values.yaml（双网关隔离示例，public外网网关）
```yaml
controller:
  replicaCount: 1
  daemonSet: true # 全节点部署
  ingressClassResource:
    name: nginx-public
    default: false
    controllerValue: "k8s.io/ingress-nginx-public"
  service:
    type: LoadBalancer
    annotations:
      # 云厂商LB公网配置
      service.beta.kubernetes.io/alibaba-cloud-loadbalancer-address-type: internet
      service.beta.kubernetes.io/alibaba-cloud-loadbalancer-protocol-port: "http:80,https:443"
  config:
    # 全局配置
    ssl-protocols: "TLSv1.2 TLSv1.3"
    ssl-prefer-server-ciphers: "on"
    proxy-body-size: "100m" # 文件上传大小限制
    enable-real-ip: "true" # 获取真实客户端IP
    use-forwarded-headers: "true"
  resources:
    requests:
      cpu: 500m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 512Mi
  metrics:
    enabled: true # 开启Prometheus监控指标
    serviceMonitor:
      enabled: true
# 禁用默认IngressClass，区分内外网
defaultBackend:
  enabled: false
```

### 4.3 执行helm安装
```bash
kubectl create ns ingress-nginx
# 外网公网网关
helm install ingress-public ingress-nginx/ingress-nginx -n ingress-nginx -f values-public.yaml
# 内网网关（另一份values-internal.yaml，service type内网LB）
helm install ingress-internal ingress-nginx/ingress-nginx -n ingress-nginx -f values-internal.yaml
```

### 4.4 部署后资源校验
```bash
# 校验DaemonSet所有节点Pod Ready
kubectl get ds -n ingress-nginx
# 校验LB公网/内网IP分配完成
kubectl get svc -n ingress-nginx
# 校验IngressClass资源
kubectl get ingressclasses
# 查看Nginx日志无启动报错
kubectl logs -n ingress-nginx ds/ingress-public-controller
```

## 五、步骤2：Ingress路由规则标准编写
### 5.1 公网HTTPS域名（自动CertManager签发证书）
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-public-ingress
  namespace: biz
  annotations:
    # 指定外网网关IngressClass
    kubernetes.io/ingress.class: nginx-public
    # 自动签发SSL证书
    cert-manager.io/cluster-issuer: public-letsencrypt
    # 强制HTTP跳转HTTPS
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    # 获取真实客户端IP
    nginx.ingress.kubernetes.io/enable-real-ip: "true"
    # 限流：单IP每秒10请求
    nginx.ingress.kubernetes.io/limit-rps: "10"
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
              number: 8080
```

### 5.2 内网专用Ingress（仅办公内网访问）
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: nginx-internal
spec:
  rules:
  - host: inner-admin.example.com
```

### 5.3 常用增强注解（安全/性能）
1. IP黑名单封禁攻击源
```
nginx.ingress.kubernetes.io/deny-cidrs: "192.168.1.5/32,203.0.113.0/24"
```
2. 跨域CORS开启
```
nginx.ingress.kubernetes.io/enable-cors: "true"
```
3. 长连接超时调整
```
nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
```
4. WAF简易防护（SQL/XSS拦截）
```
nginx.ingress.kubernetes.io/modsecurity-snippet: |
  SecRuleEngine On
```

## 六、步骤3：高可用与流量优化配置
### 6.1 保留真实客户端源IP
云LB场景必须开启，否则业务日志只能看到LB内网IP
values.yaml控制器配置：
```yaml
controller:
  config:
    enable-real-ip: "true"
  service:
    annotations:
      # 阿里云示例
      service.beta.kubernetes.io/alibaba-cloud-loadbalancer-forward-ip: "true"
```

### 6.2 会话保持（登录态业务）
Ingress注解开启基于Cookie会话保持：
```
nginx.ingress.kubernetes.io/affinity: "cookie"
nginx.ingress.kubernetes.io/session-cookie-name: "SESSIONID"
```

### 6.3 静态资源缓存优化
```
nginx.ingress.kubernetes.io/server-snippet: |
  location ~* \.(jpg|png|js|css)$ {
    expires 7d;
  }
```

## 七、步骤4：监控、日志与告警接入
### 7.1 Prometheus监控指标
helm部署时开启`metrics.serviceMonitor.enabled=true`，自动采集：
- 每秒请求QPS、HTTP状态码分布(200/404/500)
- 请求延迟p50/p90/p99
- 限流拒绝、IP黑名单拦截计数

### 7.2 访问日志持久化
容器日志驱动配置json格式，Loki/ELK采集字段：
客户端IP、域名、请求路径、响应码、耗时、User-Agent

### 7.3 告警规则
1. Ingress Nginx Pod副本异常、节点Pod Crash
2. 5xx错误率持续高于5%（服务异常告警）
3. 单域名QPS突增10倍（CC攻击预警）
4. SSL证书7天内即将过期

## 八、步骤5：全链路连通验收测试
### 1. 公网域名访问
1. HTTP 80自动跳转HTTPS 443
2. SSL证书正常，浏览器无安全警告
3. 接口正常返回业务数据，无403/502

### 2. 内网域名访问
办公网络可访问，公网IP直接访问内网域名被LB拦截

### 3. 限流/黑名单验证
1. 高频请求触发限流，返回429
2. 黑名单IP访问直接403拒绝

### 4. 真实IP校验
业务后端日志打印原始客户端公网IP，非LB代理IP

## 九、高频故障排查
### 故障1：访问域名返回502 Bad Gateway
根因：后端Service无就绪Endpoint、Ingress路径匹配错误、NetworkPolicy拦截网关访问Pod
排查：`kubectl get ep 业务svc`、cilium/iptables FORWARD放行规则

### 故障2：HTTPS证书过期/无效
根因：CertManager签发失败、域名匹配错误、Secret未同步至命名空间
排查：`kubectl get cert -n biz` 证书状态

### 故障3：公网访问正常，内网访问超时
根因：内网Ingress LB仅内网开放，公网无法路由至内网网关

### 故障4：所有访问都显示客户端IP为LB内网地址
根因：未开启real-ip、LB未透传源IP头部

### 故障5：大文件上传返回413 Request Entity Too Large
根因：proxy-body-size默认值过小，修改全局配置或单独Ingress注解

## 十、生产运维规范
1. 强制内外网两套IngressClass网关物理隔离，禁止公网流量进入内网管理后台；
2. 所有公网域名强制HTTPS，自动跳转HTTP，禁用明文80端口对外提供业务；
3. 公网网关统一配置IP黑名单、QPS限流，防御CC、扫描攻击；
4. 证书全部交由CertManager自动签发轮换，禁止手动创建Secret证书；
5. 网关全节点DaemonSet部署，杜绝单点故障，LB开启多可用区；
6. 完整采集七层访问日志，留存至少30天用于故障溯源与安全审计；
7. 禁止业务直接暴露NodePort对公网，所有HTTP/HTTPS流量统一收口Ingress；
8. 集群交付验收纳入Ingress连通性、证书、限流校验（validate-cluster-health.md）。

## 十一、关联文档索引
build-certificate-platform.md CertManager自动SSL证书管理
04-service-ingress.md Service与Ingress流量分层原理
03-network-data-path.md 南北向七层流量完整转发链路
05-network-security.md Ingress七层安全防护、WAF、IP黑白名单
06-network-debug.md Ingress 502/403/证书故障排查流程
validate-cluster-health.md 集群交付Ingress验收标准