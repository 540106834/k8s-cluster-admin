# Kubernetes 核心组件清单

|组件名称|归属|资源类型|运行位置|核心作用|底层原理/实现方法|
|---|---|---|---|---|---|
|kube-apiserver|控制面|静态Pod（kubeadm托管）|Master节点|集群统一API入口，负责认证、鉴权、资源CRUD，是所有组件的通信中枢|基于HTTPS+REST/gRPC协议，后端存储对接etcd，内置完整的认证、授权、准入控制链路|
|etcd|控制面|静态Pod（kubeadm托管）|Master节点|分布式键值数据库，持久化存储集群所有资源状态数据，集群唯一数据源|基于Raft分布式一致性算法，MVCC多版本并发控制，磁盘持久化，保证数据强一致性|
|kube-controller-manager|控制面|静态Pod（kubeadm托管）|Master节点|集成各类控制器，持续监听资源变化，调谐集群实际状态与期望状态一致|通过Informer监听apiserver资源事件，循环执行Reconcile逻辑，无限调谐资源状态|
|kube-scheduler|控制面|静态Pod（kubeadm托管）|Master节点|为未调度的Pod筛选、打分、择优分配最优Worker节点，完成Pod调度|监听未绑定Pod，通过预选策略过滤节点、优选算法打分排序，选出最优调度节点|
|kubelet|工作节点组件|系统守护进程（systemd）|Worker节点|节点代理，全权管理本机Pod，负责镜像拉取、容器启停、健康探针、资源管控|基于CRI协议对接容器运行时，自动创建网络/存储命名空间，上报节点与Pod状态至apiserver|
|kube-proxy|工作节点组件|DaemonSet|Worker节点|维护节点内核转发规则，实现Service四层负载均衡、流量转发与隔离|监听Service、Endpoint变更，动态更新iptables/IPVS内核规则，实现内核级流量分发|
|containerd|工作节点组件|系统守护进程（systemd）|Worker节点|容器运行时，负责镜像管理、容器创建、启动、销毁、生命周期管理|遵循OCI/CRI标准，调用runc创建容器，通过cgroup/namespace实现资源与网络隔离|
|CoreDNS|集群附加组件|Deployment|任意节点（Pod运行）|集群内部DNS服务，提供Service/Pod域名解析、服务发现、域名转发|Go语言开发，通过k8s插件同步集群域名记录，支持缓存、递归查询、SRV服务发现记录|
|Ingress Controller|集群附加组件|Deployment/DaemonSet|任意节点（Pod运行）|七层流量网关，实现域名/路径路由、TLS终止、限流、灰度、访问控制|监听Ingress资源动态生成Nginx/HAProxy配置，解析HTTP/HTTPS应用层报文完成精细路由|
|Metrics Server|集群附加组件|Deployment|任意节点（Pod运行）|采集节点、Pod的CPU/内存资源指标，为HPA、kubectl top提供数据支撑|定时轮询各节点kubelet监控接口，聚合资源指标，对外提供标准Metrics API|
|kube-state-metrics|集群附加组件|Deployment|任意节点（Pod运行）|监听集群各类资源状态，输出k8s原生资源指标，用于监控告警|通过Informer监听全量集群资源，将资源状态转换为Prometheus指标格式对外暴露|
|Calico/Cilium|集群网络组件|DaemonSet|所有节点（Pod运行）|CNI网络插件，实现Pod网络互通、IP分配、网络策略隔离、流量管控|Calico基于BGP/IPIP/VXLAN隧道+Netfilter；Cilium基于eBPF，实现高性能网络转发与微隔离|

**补充说明**：

1. 静态Pod：由kubelet直接管理，不经过apiserver调度，集群核心常驻组件；
2. DaemonSet：集群每个节点自动运行一个副本，适配节点级组件；
3. Deployment：可弹性扩缩容，调度至集群任意节点，适配集群公共服务组件。
