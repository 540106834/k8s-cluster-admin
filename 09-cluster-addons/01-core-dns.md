# 01-core-dns.md
# CoreDNS 集群DNS与服务发现完整文档
## 一、组件定位
CoreDNS 是 Kubernetes 集群标准内置DNS附加组件，替代旧版 kube-dns；为集群内Pod、Service提供域名解析、服务发现，是集群通信底层基础依赖。
- 资源类型：Deployment + Service
- 默认命名空间：kube-system
- 监听端口：UDP/TCP 53

## 二、核心能力
1. **集群域名自动解析**
自动感知 Service、Headless Service，生成 A记录、SRV记录；
标准域名格式：`service-name.namespace.svc.cluster.local`
2. **服务发现（SRV）**
Headless Service 场景返回后端Pod域名与端口，支撑etcd、分布式MinIO等有状态集群。
3. **域名转发**
- 集群内部域名：交由kubernetes插件处理；
- 公网域名：转发至上游公共DNS（223.5.5.5、114.114.114.114）；
- 私有内网域（k8s.local）：转发至企业自建权威DNS。
4. **缓存机制**
缓存解析结果，降低上游DNS压力，缩短重复解析耗时。
5. **扩展插件**
日志、错误输出、域名劫持、最小TTL、限速等。

## 三、标准 Corefile 配置模板
```
.:53 {
    errors
    log
    health {
        lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
        ttl 30
    }
    prometheus :9153
    forward . 223.5.5.5 114.114.114.114 {
        max_concurrent 1000
    }
    # 私有域转发至内网权威DNS
    k8s.local:53 {
        forward 192.168.11.10
    }
    cache 30
    loop
    reload
    loadbalance
}
```
插件说明：
- `kubernetes`：同步集群Service/Pod资源；
- `forward`：上游域名转发；
- `cache`：开启解析缓存；
- `loadbalance`：DNS响应随机排序，均衡后端访问；
- `loop`：检测DNS转发环路。

## 四、Pod DNS解析配置（/etc/resolv.conf）
Pod内自动注入配置，由PodSpec dnsPolicy控制：
```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```
- `ndots:5`：域名包含`.`数量≥5，直接发起查询；少于5个先拼接search域搜索。

### dnsPolicy四种策略
1. `ClusterFirst`（默认）：所有域名优先CoreDNS，外部域名由CoreDNS转发上游；
2. `Default`：继承宿主机 `/etc/resolv.conf`，不走CoreDNS；
3. `ClusterFirstWithHostNet`：Pod使用hostNetwork时，依然优先使用CoreDNS；
4. `None`：自定义nameserver、search，完全接管DNS配置。

## 五、完整解析流程（Pod访问 minio.default.svc.cluster.local）
1. 应用发起DNS查询，报文发往CoreDNS ClusterIP UDP 53；
2. Corefile kubernetes插件匹配 `cluster.local`，查询集群内Service资源；
3. 获取Service后端Endpoint IP，构造A记录响应；
4. CoreDNS写入缓存，返回IP给Pod；
5. Pod使用IP通过Service访问后端。

## 六、SRV服务发现示例
```bash
# 查询kubernetes apiserver SRV记录
dig _kubernetes._tcp.default.svc.cluster.local SRV
```
Headless Service自动生成SRV，多用于分布式集群节点自动寻址。

## 七、运维常用操作
```bash
# 查看CoreDNS资源
kubectl get deployment,coredns,svc -n kube-system

# 查看Corefile配置
kubectl get configmap coredns -n kube-system -o yaml

# 重载配置（修改Corefile后）
kubectl rollout restart deployment coredns -n kube-system

# 进入Pod测试解析
kubectl run test-dns --rm -it --image busybox -- nslookup minio.default.svc.cluster.local

# 抓包DNS流量
tcpdump -i any udp port 53 -nn
```

## 八、生产高频故障
1. **Pod无法解析集群内部Service域名**
排查方向：
- Pod resolv.conf nameserver是否指向CoreDNS ServiceIP；
- coredns Pod是否正常运行；
- Service是否存在、是否拥有可用Endpoint。

2. **内网私有域名（k8s.local）解析失败，公网域名正常**
根因：Corefile缺少私有域forward转发规则；
修复：添加 `k8s.local:53 { forward x.x.x.x }`。

3. **大量解析超时、业务接口随机卡顿**
根因：CoreDNS副本不足、并发请求打满；上游DNS服务不可用；
优化：扩容coredns副本，配置双上游DNS容灾。

4. **DNS UDP丢包，部分解析请求失败**
解决方案：开启TCP fallback、调大节点nf_conntrack连接上限。

5. **域名IP更新后长时间不刷新**
多层缓存：CoreDNS缓存、系统缓存、应用进程内置缓存；
优化：缩短记录TTL，必要时重启业务Pod。

6. **ndots导致过多无效DNS请求**
现象：短域名反复拼接search域发起多条查询；
优化：按需调整ndots值，或者使用完整长域名访问。

## 九、生产运维规范
1. CoreDNS至少部署2副本，防止单点故障；
2. 区分公网域名与内网私有域，配置独立forward转发；
3. 开启日志，便于排查解析失败问题；生产高并发可阶段性关闭日志降低开销；
4. 监控coredns查询量、缓存命中率、解析失败指标；
5. 集群内所有组件优先使用完整域名访问，避免search域带来多余DNS查询；
6. hostNetwork模式Pod使用 `ClusterFirstWithHostNet`，保证依旧使用集群DNS。

## 十、依赖关系
CoreDNS是集群基础底层组件，所有业务Pod、Ingress、HPA、监控组件域名解析均依赖；
集群初始化阶段优先部署，再启动其他业务与附加组件。

需要我继续输出 `02-metrics-server.md`，保持文档统一行文风格吗？