# build-loadbalancer-platform.md
# K8s 四层负载均衡平台部署运维手册（MetalLB）
## 一、文档定位
本文面向自建机房、裸金属、无云厂商原生LB的企业K8s集群，部署 **MetalLB** 实现集群LoadBalancer类型Service；提供二层ARP模式、BGP路由模式两套部署方案，完整覆盖IP地址池规划、Service四层转发、高可用、故障排查、与Ingress/Nodeport协同、安全管控；
前置依赖：
build-kubernetes-cluster.md｜基础集群就绪
build-ingress-platform.md｜七层Ingress网关配套
03-network-data-path.md｜集群南北向四层流量链路
validate-cluster-health.md｜集群交付验收标准
下游关联：04-service-ingress.md、06-network-debug.md

## 二、平台架构与两种工作模式选型
### 2.1 MetalLB 组件构成
1. **metallb-controller**：集群控制器，监听Service变更，分配LB公网IP、管理IP地址池
2. **metallb-speaker**：DaemonSet，每个节点部署，负责ARP广播（二层）/BGP路由推送（三层）

### 2.2 模式1：二层ARP模式（中小型机房、无交换机BGP支持，推荐测试/小规模）
- 原理：给LoadBalancer Service分配静态内网/公网IP，speaker通过ARP广播，将LB IP绑定到存活节点
- 流量路径：客户端 → LB IP(ARP指向集群节点) → PREROUTING DNAT → 后端Pod
- 优势：部署简单，无需交换机配置
- 短板：单LB IP同一时间仅能绑定一个节点，存在单点瓶颈，无负载分担

### 2.3 模式2：BGP路由模式（大型生产机房、三层网络，企业生产首选）
- 原理：集群所有节点与机房交换机建立BGP邻居，把LB地址段发布至全网路由
- 流量路径：客户端通过交换机等价路由ECMP分流至所有节点，多节点同时承接流量
- 优势：多节点负载均衡、无单点、吞吐高、支持会话保持
- 短板：机房交换机需支持BGP配置

### 2.4 场景选型标准
1. 测试集群、小型机房、交换机不支持BGP → 二层ARP
2. 生产裸金属机房、大规模四层TCP业务（数据库、消息队列）→ BGP ECMP
3. 公有云集群：直接使用云厂商LB，无需部署MetalLB

## 三、前置资源规划
### 3.1 IP地址池规划
提前划分独立不冲突IP段，分为内网业务LB、公网业务LB两组：
示例：
- 内网LB地址池：`192.168.30.0/24`（内网客户端访问数据库）
- 公网LB地址池：`203.0.113.0/24`（对公暴露TCP四层服务）
约束：该网段不能被机房DHCP、其他服务器占用，路由可达集群所有节点。

### 3.2 网络前置校验
1. 二层模式：机房网关/交换机允许ARP广播，无ARP防火墙拦截
2. BGP模式：交换机放行TCP 179端口，提前规划BGP AS号（集群AS 64500，机房交换机AS 64501）
3. 集群节点安全组/防火墙放行MetalLB所需端口：7946（speaker通信）
4. 内核arp/ip转发已开启 `sysctl net.ipv4.ip_forward=1`

### 3.3 资源规划
- 命名空间：`metallb-system` 独立隔离
- metallb-speaker：DaemonSet，全节点调度
- metallb-controller：2副本高可用，防止单点故障

## 四、方案A：二层ARP模式部署（L2 ARP）
### 4.1 Helm 部署 MetalLB
```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
kubectl create ns metallb-system
helm install metallb metallb/metallb -n metallb-system
```

### 4.2 配置IP地址池 IPAddressPool
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lb-public-pool
  namespace: metallb-system
spec:
  addresses:
  - 203.0.113.10-203.0.113.50 # 公网LB地址段
  autoAssign: true
  # 仅匹配带指定annotation的Service
  serviceAllocation:
    serviceSelectors:
    - matchLabels:
        lb-type: public
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lb-inner-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.30.10-192.168.30.50
  autoAssign: true
  serviceAllocation:
    serviceSelectors:
    - matchLabels:
        lb-type: inner
```

### 4.3 配置二层ARP通告 L2Advertisement
```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: all-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - lb-public-pool
  - lb-inner-pool
  # 可选：指定节点承担LB流量，空=所有节点均可
  # nodeSelectors:
  #   matchLabels:
  #     role: lb-gateway
```

### 4.4 部署校验
```bash
# 查看控制器、speaker全部就绪
kubectl get pods -n metallb-system
# 查看地址池状态
kubectl get ipaddresspools -n metallb-system
```

## 五、方案B：BGP三层路由模式部署（生产推荐）
### 5.1 Helm 基础安装同上，跳过L2Advertisement，改用BGP配置
### 5.2 IPAddressPool 同上，地址池规划一致
### 5.3 BGP邻居配置 BGPPeer
```yaml
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: switch-bgp
  namespace: metallb-system
spec:
  # 机房交换机BGP地址
  peerAddress: 192.168.1.1
  peerASN: 64501 # 交换机AS号
  myASN: 64500   # 集群本地AS
  # 开启ECMP多节点负载分担
  allowECMP: true
  # 密码认证（机房BGP防劫持）
  password: "BGP@Pass2026"
```

### 5.4 BGP路由通告 BGPAdvertisement
```yaml
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: bgp-lb-adv
  namespace: metallb-system
spec:
  ipAddressPools:
  - lb-public-pool
  - lb-inner-pool
  # 路由优先级
  localPref: 100
```

### 5.5 交换机配套配置（简要示例）
1. 与集群所有节点建立BGP邻居
2. 开启ECMP等价路由，负载均衡至多节点
3. 放行TCP 179，配置MD5密码认证

## 六、Service 使用LoadBalancer 标准示例
### 6.1 公网四层数据库服务
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql-lb
  namespace: db
  labels:
    lb-type: public # 匹配公网IP池
spec:
  type: LoadBalancer
  ports:
  - port: 3306
    targetPort: 3306
    protocol: TCP
  selector:
    app: mysql
  # 本地流量策略，保留客户端真实源IP
  internalTrafficPolicy: Local
```

### 6.2 内网中间件服务
```yaml
metadata:
  labels:
    lb-type: inner
spec:
  type: LoadBalancer
```

### 6.3 固定指定LB IP（不自动分配）
```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: "203.0.113.20"
```

## 七、高可用、流量优化配置
### 7.1 会话保持（TCP长连接数据库）
Service开启源IP会话保持：
```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600
```

### 7.2 保留客户端真实源IP
全局推荐开启 `internalTrafficPolicy: Local`，流量仅转发本机Pod，无需跨节点SNAT，业务日志可获取真实客户端IP。

### 7.3 多可用区调度（BGP模式）
给不同机房节点打标签，配合nodeSelector实现LB流量跨机房冗余。

## 八、与Ingress、NodePort协同规范
1. **七层HTTP/HTTPS**：统一使用Ingress-Nginx，Ingress Controller配套LoadBalancer暴露公网，禁止直接业务NodePort对公网；
2. **四层TCP/UDP长连接**（MySQL、Redis、Kafka）：使用MetalLB LoadBalancer；
3. NodePort仅用于测试环境，生产四层业务全部使用MetalLB LB；
4. 内外网流量通过IPAddressPool标签隔离，互不复用地址池。

## 九、监控、日志与告警
### 9.1 Prometheus 监控指标
MetalLB内置metrics，helm开启serviceMonitor采集：
1. IP地址池已分配/空闲IP数量
2. BGP邻居连接状态（up/down）
3. LB Service流量、连接数
4. ARP广播异常、路由撤回计数

### 9.2 告警规则
1. metallb-controller/speaker Pod异常重启
2. BGP邻居断开，路由无法发布
3. IP地址池剩余IP低于5个（地址耗尽预警）
4. LB Service无法分配外部IP

## 十、全链路验收测试
### 1. IP分配验证
创建LoadBalancer Service，自动从对应地址池分配外部IP，或固定IP生效。
### 2. 连通性测试
客户端访问LB IP+端口，正常转发至后端Pod，双向流量无丢包。
### 3. 二层ARP模式故障转移
关闭承载LB IP的节点，ARP自动切换至其他节点，业务中断<3s。
### 4. BGP模式ECMP负载均衡
多节点同时承接流量，机房路由表存在多条等价下一跳。
### 5. 源IP保留校验
开启Local流量策略，业务Pod日志可见真实客户端IP。

## 十一、高频故障排查
### 故障1：LoadBalancer Service一直处于Pending，无法分配IP
根因：IPAddressPool标签不匹配、地址池IP耗尽、metallb-controller崩溃
排查：kubectl describe svc xxx 查看事件；检查IPAddressPool地址段剩余数量

### 故障2：二层模式访问LB IP超时，内网不通
根因：ARP广播被交换机拦截；当前节点无存活后端Pod
排查：arping LB_IP 查看ARP解析是否正常；检查节点Endpoint就绪状态

### 故障3：BGP模式路由无法发布，客户端无法访问LB IP
根因：BGP邻居断开、TCP179端口拦截、AS号/密码不匹配
排查：kubectl logs -n metallb-system ds/metallb-speaker 查看BGP日志；检查交换机BGP状态

### 故障4：后端Pod日志源IP均为节点IP，丢失真实客户端
根因：未配置 internalTrafficPolicy: Local，流量跨节点触发SNAT
修复：Service添加本地流量策略

### 故障5：BGP单节点故障后流量全部中断
根因：未开启allowECMP，路由仅发布至单节点；交换机未启用ECMP
修复：BGPPeer资源开启allowECMP，交换机配置等价路由

## 十二、生产运维落地规范
1. 严格区分内网、公网两套独立IP地址池，通过Service标签隔离；
2. 四层长连接数据库、中间件统一使用BGP ECMP模式，杜绝二层ARP单点瓶颈；
3. 所有公网LB IP纳入机房安全管控，仅放行业务端口，关闭高危端口；
4. BGP邻居强制MD5密码认证，防止路由劫持；
5. 监控IP地址池剩余容量，提前扩容网段，避免新Service无法分配IP；
6. 七层HTTP业务收口Ingress，四层TCP业务使用MetalLB LB，分层流量管理；
7. 集群交付验收增加LoadBalancer连通性校验，纳入validate-cluster-health.md。

## 十三、关联文档索引
build-kubernetes-cluster.md｜集群基础网络前置配置
build-ingress-platform.md｜七层Ingress网关配套LB部署
04-service-ingress.md｜Service四种类型流量对比
03-network-data-path.md｜四层LB南北向流量转发链路
06-network-debug.md｜MetalLB IP分配、BGP邻居故障排查
validate-cluster-health.md｜集群交付LoadBalancer验收标准