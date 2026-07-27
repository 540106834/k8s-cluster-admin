# kubernetes-platform-design/05-network-security.md
## 文档元信息
- 模块：网络安全体系
- 优先级：★★★★★ 租户隔离、流量安全核心底座
- 依赖文档：00-platform-overview.md、02-namespace-resource-governance、04-application-delivery
- 关联模块：11-addon-management、07-observability、10-workload-security、15-compliance-audit
- 适用角色：平台SRE、网络运维、安全工程师、CNI运维、应用架构师

## 1. 模块定位与核心目标
### 1.1 定位
归属三层「集群资源管控域-网络安全域」，覆盖**集群底层CNI网络、Pod东西向通信、Service服务发现、Ingress南北向流量、网络访问控制、流量管控加密**全链路。
依托CNI+NetworkPolicy构建租户网络软隔离，南北网关统一管控公网流量，是多租户安全隔离、流量防泄露、防横向越权攻击关键模块。

### 1.2 核心目标
1. 统一CNI底座标准，集群Pod网络扁平化互通，底层转发性能可控
2. 默认拒绝式网络隔离，基于Namespace/标签实现东西向Pod访问权限管控
3. 南北流量统一收敛Ingress网关，全链路HTTPS加密、限流、WAF防护
4. 服务网格可选标准化流量治理（灰度、熔断、mTLS），无侵入业务代码
5. 集群内外流量分层管控：内网可信流量、公网不可信流量隔离
6. 网络行为全观测、异常访问自动告警，完整流量审计溯源

### 1.3 解决业务痛点
- 多Namespace无隔离，漏洞Pod横向扫描攻击其他业务数据库
- 公网服务裸HTTP暴露，明文传输数据泄露风险
- 无统一流量网关，业务自行开NodePort/LoadBalancer，端口泛滥、无法统一限流
- Pod间无访问控制，违规跨团队数据库直连，权限不可控
- 无网络流量日志，异常访问、端口爆破无法定位溯源
- 服务之间明文通信，内网抓包可窃取接口数据、数据库报文

## 2. 平台网络分层架构（四层流量边界）
```
公网流量 → 四层LB/防火墙 → Ingress网关（南北边界） → Service集群内网 → Pod东西向通信（NetworkPolicy管控）
```
1. **南北边界层**：Ingress Controller、证书、WAF、限流、IP黑白名单（外部入站流量唯一入口）
2. **服务内网层**：Service、CoreDNS、ClusterIP、服务发现、四层负载均衡
3. **Pod东西通信层**：CNI转发、NetworkPolicy访问控制、Pod间mTLS加密
4. **底层基础设施层**：节点网卡、主机防火墙、宿主机内核Netfilter、TC流量整形

## 3. CNI底座标准化设计
### 3.1 CNI选型约束
统一使用Cilium作为集群CNI，放弃Flannel/Calico混合部署，能力收敛：
- 原生支持NetworkPolicy、BPF高性能转发、Pod防火墙、L7策略、流量观测
- 内置节点级防火墙、IP伪装管控、基于身份的Pod访问控制
- 支持服务网格mTLS、透明加密，无需Sidecar额外开销

### 3.2 全局网络基础规范
1. Pod网段、Service网段、节点主机网段三层独立隔离，禁止网段重叠
2. 全局禁用hostNetwork、hostPort（业务Pod，准入控制器拦截）
3. CoreDNS全局统一服务发现，所有Pod强制使用集群内DNS
4. 节点间通信仅开放平台运维、组件通信端口，宿主机防火墙拦截外部直连节点
5. Cilium开启BPF透明转发，关闭iptables大规模规则，降低节点性能损耗

### 3.3 网络资源标签体系
所有NetworkPolicy、Ingress、Service统一注入标签：
```yaml
labels:
  platform.company.com/env: prod
  platform.company.com/team: pay
  platform.company.com/network-scope: east-west/north-south
```

## 4. 东西向安全管控：NetworkPolicy 强制基线
### 4.1 全局默认安全策略（所有Namespace自动下发，不可删除）
**默认拒绝模型**：未显式放行规则，所有Pod入站流量全部阻断
1. 同Namespace内部Pod默认互通（业务内部调用）
2. 全局允许访问CoreDNS、监控采集、日志采集平台组件
3. 禁止跨Namespace主动入站访问，如需跨团队调用必须提交网络放行工单
4. 生产环境禁止宽松全通式NetworkPolicy

### 4.2 标准化放行规则模板
1. 同Namespace应用互访：基于app标签放行
2. 跨Namespace授权访问：白名单Namespace+应用标签精准放行，禁止`*`通配
3. 平台组件白名单：所有租户Pod允许推送指标、日志至monitoring命名空间
4. 数据库/中间件专属规则：仅允许对应业务应用Pod访问，阻断外部Pod直连

### 4.3 多租户联动规则（联动02-namespace-resource-governance）
Namespace创建时GitOps自动部署基线NetworkPolicy；
- dev/test环境可临时放宽策略，需工单审批；
- prod生产环境策略变更双人审批，变更全量审计留存。

## 5. 南北向流量安全管控：Ingress 统一网关
### 5.1 流量收敛约束
1. 业务禁止使用NodePort、LoadBalancer直曝公网，所有外部流量统一走Ingress
2. 集群全局唯一Ingress Controller（Cilium Ingress / Nginx Ingress），统一四层前置LB
3. 域名规范：`{应用}.{环境}.company.com`，环境域名物理隔离，测试域名不可访问生产后端

### 5.2 强制安全配置（准入控制器拦截违规Ingress）
1. 全站强制TLS，cert-manager自动签发/续期证书（11-addon-management），禁用HTTP 80明文
2. TLS版本最低TLS1.2，禁用弱加密套件
3. 统一WAF规则：拦截SQL注入、XSS、路径遍历、恶意UA
4. 全局限流模板：单IP每秒请求上限、单域名并发连接上限
5. IP黑白名单：生产核心接口支持配置IP白名单，限制企业内网访问

### 5.3 流量治理能力
1. 基于权重灰度分流（配合04-application-delivery灰度发布）
2. 请求超时、重试、熔断统一在Ingress配置，业务无感知
3. 请求日志全量落地，记录源IP、请求路径、状态码、耗时

## 6. 服务网格与内网加密（生产强制）
### 6.1 mTLS透明加密
Cilium内置透明mTLS，Pod之间通信自动加密，无需业务修改代码：
1. 生产环境全局开启，dev/test可选关闭
2. 证书由平台CA自动轮换，对接Vault密钥管理（08-secret-management）
3. 防止内网抓包窃取接口、数据库明文数据

### 6.2 可选服务网格能力
复杂微服务集群启用Cilium Service Mesh，提供：
- 细粒度L7访问控制（按接口路径放行/拦截）
- 分布式追踪透传、流量镜像、故障注入测试
- 基于服务身份认证，不依赖IP网段管控

## 7. 流量控制与QoS（TC/BPF）
1. 节点出口带宽限流：防止单个Pod耗尽节点网卡带宽
2. 区分业务流量优先级：生产业务高于测试、日志采集流量
3. 大文件传输、备份流量限制带宽，避免抢占业务接口流量

## 8. 网络安全风险防护矩阵
| 风险类型 | 防护手段 |
|--------|--------|
| Pod横向渗透攻击 | 默认拒绝NetworkPolicy、基于标签精准访问控制、内网mTLS |
| 公网明文数据泄露 | Ingress强制HTTPS、拦截裸HTTP服务 |
| 端口泛滥、无边界暴露 | 禁用NodePort/LoadBalancer，统一Ingress收敛 |
| 跨团队未授权访问数据库 | 跨Namespace访问工单审批、精准白名单Policy |
| 内网流量抓包窃听 | Pod间透明mTLS加密 |
| 单Pod耗尽节点带宽 | BPF TC带宽限流、QoS优先级 |
| 恶意IP高频爆破 | Ingress WAF、IP限流、自动拉黑 |

## 9. 网络可观测与异常告警（联动07-observability-platform）
### 9.1 采集维度
1. 流量指标：Pod入/出带宽、连接数、丢包率、握手失败次数
2. 访问日志：Ingress全量请求日志、Cilium流量审计日志
3. 策略日志：NetworkPolicy拒绝访问事件（核心告警源）

### 9.2 分级告警规则
1. P1：大量跨Namespace访问被拦截、数据库端口异常扫描
2. P2：Ingress 5xx错误突增、TLS证书过期预警、带宽打满
3. P3：单IP高频限流触发、测试环境违规公网Ingress创建

## 10. 审计与合规（联动15-compliance-audit）
1. NetworkPolicy创建/修改/删除全量审计日志，记录操作人、放行规则范围
2. Ingress域名、TLS证书、WAF规则变更留存180天日志
3. 每日网络安全巡检报告：宽松Policy、未加密Ingress、跨Namespace无白名单访问
4. 流量拒绝事件留存审计，满足等保内网访问追溯要求

## 11. 落地强制禁忌规范
1. 禁止业务Pod开启hostNetwork、hostPort、hostIP直通宿主机网络
2. 禁止创建无TLS明文HTTP生产Ingress
3. 禁止绕过Ingress使用NodePort/LoadBalancer暴露业务公网端口
4. 禁止全局宽松NetworkPolicy（允许所有入站流量）
5. 禁止跨Namespace无工单放行规则，禁止Policy使用`*`通配匹配
6. 禁止业务自行管理SSL证书，统一cert-manager签发
7. 禁止生产环境关闭Pod间mTLS加密

## 12. 跨模块协作边界
1. 02-namespace-resource-governance：Namespace自动下发基线NetworkPolicy，环境隔离规则互通
2. 04-application-delivery：应用Ingress、Service统一平台模板，发布前校验网络合规性
3. 08-secret-management：Ingress TLS私钥、网格mTLS CA证书存储Vault
4. 10-workload-security：准入控制器拦截hostNetwork、hostPort等高风险网络配置Pod
5. 11-addon-management：Cilium、Ingress Controller、cert-manager属于平台基础插件统一运维
6. 14-platform-engineering：自助门户提供跨Namespace网络放行工单、域名申请流程
7. 15-compliance-audit：网络策略、Ingress变更、异常访问事件纳入合规审计巡检
8. 07-observability：采集网络流量、拒绝事件、网关日志，统一告警大盘展示