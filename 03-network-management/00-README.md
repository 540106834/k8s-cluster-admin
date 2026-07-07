# 03-network-management/00-README.md

## 一、文档基础信息

### 目录归属

路径：`03-network-management/`
前置依赖：`02-workload-management/` 工作负载完整文档、集群初始化、containerd运行时就绪
集群基准：Kubernetes v1.32.13，Calico v3.30.4 CNI，内网Harbor镜像仓库
环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
配套关联：`etcd-backup.md`、`10-troubleshooting.md`、`cluster-upgrade-theory-guide.md`

### 模块核心定位

集群网络是Pod、Service、外部流量互通的底层基础设施，本目录完整覆盖**K8s标准网络模型、CNI插件、服务四层代理、Ingress七层网关、DNS服务发现、网络访问隔离、负载均衡、全链路网络排错**整套标准化运维规范。
统一支撑四层环境：DEV本地自测、FAT功能测试、UAT预生产、PROD生产，区分环境网络隔离、访问权限、流量管控差异化策略。

## 二、子文档功能总览

| 文件名称 | 核心覆盖内容 |
| -------- | ------------ |
| 01-kubernetes-network-model.md | K8s四大网络通信模型、Pod/节点/Service/外部流量互通规范、网段规划设计 |
| 02-cni-overview.md | CNI标准规范、Calico底层原理、部署升级、网段规划、离线部署、集群网络基础配置 |
| 03-service-management.md | Service四种类型、EndpointSlice、Endpoint生命周期、标签选择器、无头Headless Service（适配StatefulSet） |
| 04-ingress-management.md | Ingress资源、IngressController、域名路由、TLS/HTTPS证书、多环境域名隔离、灰度流量路由 |
| 05-dns-service-discovery.md | CoreDNS部署配置、集群内部DNS解析规则、自定义域名、DNS缓存、解析故障排查 |
| 06-network-policy.md | NetworkPolicy访问控制策略、多环境隔离（FAT禁止访问UAT/PROD）、Pod白名单、默认拒绝策略落地 |
| 07-load-balancing.md | ClusterIP/NodePort/LoadBalancer负载均衡对比、节点端口分配、云厂商LB对接、四层流量转发优化 |
| 08-network-troubleshooting.md | 全链路网络故障排查SOP：Pod不通、DNS失败、Service访问异常、Ingress5xx、Policy拦截、CNI异常 |

## 三、核心网络分层理论认知

### 3.1 底层：CNI网络平面

Calico负责Pod跨节点互通、IP分配、路由转发、基础数据包转发，是集群网络底座。

### 3.2 四层服务平面：Service & EndpointSlice

kube-proxy基于iptables/ipvs实现固定虚拟IP，后端绑定Pod集合，提供稳定四层访问入口。

### 3.3 服务发现平面：CoreDNS

集群内部域名解析，提供 `svc.ns.svc.cluster.local` 标准域名，实现无感知服务发现。

### 3.4 七层接入平面：Ingress

七层HTTP/HTTPS网关，统一域名、路由、证书、限流，对外暴露业务服务。

### 3.5 安全隔离平面：NetworkPolicy

基于Pod标签、命名空间做细粒度访问控制，实现多环境网络隔离，阻断非法跨环境访问。

## 四、K8s四大标准通信模型（本模块统一遵循）

1. Pod ↔ Pod（同/跨节点）
2. Pod ↔ Node 宿主机互通
3. Pod ↔ Service 虚拟服务访问
4. Pod ↔ 集群外部（公网/内网第三方服务）

## 五、四层环境网络标准化约束（DEV/FAT/UAT/PROD）

1. **DEV本地**
   本地Kind/Docker自建网络，无NetworkPolicy隔离，仅本地自测，禁止访问集群内网资源。
2. **FAT（功能测试）**
   独立Pod/Service网段，NetworkPolicy默认仅允许同命名空间互通，**禁止主动访问UAT/PROD中间件**；开放测试域名，无正式HTTPS证书。
3. **UAT（预生产）**
   网段与生产隔离，网络策略对齐生产规则；配置完整HTTPS证书，仿真公网流量；仅运维/测试只读访问权限。
4. **PROD（生产）**
   严格NetworkPolicy白名单机制，默认拒绝所有跨ns访问；全站强制HTTPS、域名独立隔离；关闭多余NodePort，仅LoadBalancer/Ingress对外暴露；中间件仅允许业务Pod定向访问。

## 六、标准化运维操作规范（本目录统一约束）

1. 集群网段提前规划固化：PodCIDR、ServiceCIDR三层环境完全隔离，不重叠；
2. 所有网络资源采用 `kubectl apply -f` 声明式管理，纳入Git版本；
3. PROD环境强制开启默认拒绝NetworkPolicy，最小白名单放行业务通信；
4. StatefulSet中间件必须配套Headless Service，保障固定域名解析；
5. 对外业务统一使用Ingress七层网关，禁止直接开放NodePort暴露公网；
6. CoreDNS开启缓存、日志，便于定位解析异常；
7. 网络变更前导出当前网络资源yaml，集群大版本升级前执行etcd快照备份；
8. 网络故障优先使用本目录08排错文档，分层定位CNI/Service/DNS/Ingress/Policy问题。

## 七、推荐阅读&实操顺序

1. 底层基础：01-kubernetes-network-model.md（网段规划前置必看）
2. 网络底座：02-cni-overview.md（Calico部署、集群网络初始化）
3. 四层服务：03-service-management.md（业务基础访问入口）
4. 服务发现：05-dns-service-discovery.md（集群域名解析原理）
5. 七层网关：04-ingress-management.md（对外业务暴露）
6. 负载均衡补充：07-load-balancing.md（四层转发选型）
7. 网络安全隔离：06-network-policy.md（多环境访问控制）
8. 故障兜底：08-network-troubleshooting.md

## 八、上下游文档关联

### 上游前置

1. `00-README.md` 集群规划文档：网段、节点、资源整体规划
2. `02-workload-management/` 全部工作负载文档（Pod/Deployment/StatefulSet网络通信依赖）

### 下游配套

1. `etcd-backup.md` 网络配置变更前置备份规范
2. `cluster-upgrade-theory-guide.md` CNI/Ingress升级兼容规则
3. `cluster-migration.md` 跨集群网络网段迁移适配方案
4. `10-troubleshooting.md` 集群全局故障汇总

## 九、适用业务场景清单

1. 集群内部微服务互通 → Service + CoreDNS
2. 数据库/Redis有状态集群稳定域名 → Headless Service
3. 业务域名、HTTPS、路由分流 → Ingress
4. 多环境隔离、禁止测试直连生产中间件 → NetworkPolicy
5. 公网四层端口转发、云厂商负载均衡 → LoadBalancer
6. Pod跨节点不通、DNS解析失败、Ingress 502、网络拦截 → 08-network-troubleshooting.md
7. 集群网络初始化、Calico升级、网段扩容 → CNI管理文档