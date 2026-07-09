# 01-kubernetes-network-model.md

## 一、文档基础信息

- 归属目录：`03-network-management/`
- 前置阅读：`03-network-management/00-README.md`、`02-workload-management/02-pod-lifecycle.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4、containerd 2.1.5、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT功能测试、UAT预生产、PROD生产
- 核心覆盖：K8s标准网络模型、四大通信场景、网段分层规划、多环境网段隔离、网络底层约束、落地规范

## 二、K8s 强制网络模型（CNI 统一遵循准则）

### 2.1 四大网络公理（所有CNI插件必须满足）

1. **所有Pod之间无需NAT可直接互通**，同节点/跨节点无区别；
2. **Pod与节点可直接互通**，Pod访问宿主机IP、宿主机访问PodIP无拦截；
3. **Pod访问Service虚拟IP不允许使用NAT**，kube-proxy转发逻辑透明；
4. **节点与外部网络互通**，Pod出网可访问内网/公网第三方服务。

### 2.2 三层网络地址隔离体系
集群网络分为三段独立网段，全程禁止网段重叠：
1. Node CIDR：宿主机物理网卡网段（服务器内网）
2. Pod CIDR：所有Pod分配的独立IP段（Calico统一分配）
3. Service CIDR：Service虚拟ClusterIP网段（kube-proxy管理）

## 三、四大标准通信模型完整拆解
### 3.1 模型1：Pod ↔ Pod（同节点 / 跨节点）
#### 通信逻辑
1. 同节点Pod：共享宿主机网桥，直接二层互通；
2. 跨节点Pod：Calico生成节点路由，数据包经宿主机转发至目标节点；
3. PodIP为唯一标识，Pod重建IP会变更，无固定身份；
4. 有状态应用依靠Headless Service域名屏蔽IP变动。

#### 访问方式
- 直连PodIP：`curl 10.244.1.10:8080`
- 集群域名（推荐）：`pod-name.sts-name.ns.svc.cluster.local`（仅StatefulSet）

#### 分环境约束
- FAT/UAT/PROD Pod网段完全隔离，跨环境Pod默认不通，由NetworkPolicy控制访问权限。

### 3.2 模型2：Pod ↔ Node 宿主机互通
#### 访问场景
1. Pod采集宿主机指标、日志（DaemonSet filebeat/node-exporter）；
2. Pod调用宿主机本地服务、硬件代理；
3. 宿主机调试访问集群内Pod。

#### 特殊访问地址
- Pod访问宿主机：`hostIP` 环境变量、域名 `host.kubernetes.local`
- Pod访问自身Pod：`localhost`
- Pod访问同节点其他Pod：直接PodIP

#### 安全约束
PROD环境限制DaemonSet hostPath/hostNetwork权限，普通业务Pod禁止直接大量访问宿主机端口。

### 3.3 模型3：Pod ↔ Service（四层固定访问入口）
#### 底层原理
1. Service分配固定不变ClusterIP，生命周期内IP永不变化；
2. kube-proxy监听Service/EndpointSlice变更，生成转发规则；
3. 请求到达ClusterIP后转发至后端就绪Pod；
4. 支持负载均衡、会话保持、多后端Pod自动故障摘除。

#### 标准域名格式（CoreDNS解析）
```
# 同命名空间
service-name
# 跨命名空间通用格式
service-name.ns.svc.cluster.local
```

#### 两种Service网络形态
1. 普通ClusterIP Service：无状态Deployment业务使用；
2. Headless Service（clusterIP: None）：无虚拟IP，直接解析所有PodIP，专供StatefulSet中间件。

### 3.4 模型4：Pod ↔ 集群外部流量（出网/入网）
#### 1）Pod 访问外部（出网）
Pod访问内网中间件、第三方公网接口，数据包SNAT为宿主机NodeIP出站；
可通过NetworkPolicy限制Pod出站目标IP/端口。

#### 2）外部访问集群（入网）
三层接入路径：
1. NodePort：节点端口暴露，四层简单测试使用；
2. LoadBalancer：云厂商四层负载均衡；
3. Ingress Controller：七层HTTP/HTTPS标准对外网关（生产强制）。

## 四、标准化网段分层规划规范（FAT/UAT/PROD完全隔离）
### 4.1 全局网段设计原则
1. 三套集群环境PodCIDR、ServiceCIDR互不重叠；
2. Pod网段预留充足IP，支持业务扩容；
3. Service网段地址段缩小，避免占用大量内网路由表；
4. Node宿主机网段统一机房内网，三层环境节点同网段，依靠Pod/Service网段隔离。

### 4.2 网段分配示例
| 环境 | Pod CIDR | Service CIDR |
|------|----------|--------------|
| FAT  | 10.244.0.0/16 | 10.96.0.0/16 |
| UAT  | 10.245.0.0/16 | 10.97.0.0/16 |
| PROD | 10.246.0.0/16 | 10.98.0.0/16 |

### 4.3 网段配置生效位置
1. PodCIDR：kubeadm init/join --pod-network-cidr，Calico配置文件同步；
2. ServiceCIDR：kubeadm init --service-cidr，集群初始化后不可修改；
> 重大提醒：集群上线后禁止修改Pod/Service网段，修改需重建集群。

## 五、DEV/FAT/UAT/PROD 网络分层规范
### DEV本地
本地Kind/minikube独立网段，不接入公司内网集群；无跨环境访问限制，仅本地调试。

### FAT 功能测试
1. PodCIDR 10.244.0.0/16，ServiceCIDR 10.96.0.0/16；
2. 默认NetworkPolicy仅允许fat内部互通；
3. 禁止主动出站访问UAT/PROD网段；
4. 仅开放测试临时NodePort，不配置正式Ingress域名。

### UAT 预生产
1. PodCIDR 10.245.0.0/16，ServiceCIDR 10.97.0.0/16；
2. 网络策略对齐生产白名单规则；
3. 仅允许指定运维IP外部访问Ingress；
4. 可有限访问PROD只读中间件（需单独放开Policy）。

### PROD 生产（最高安全标准）
1. PodCIDR 10.246.0.0/16，ServiceCIDR 10.98.0.0/16；
2. 默认拒绝所有跨Namespace访问，仅白名单业务互通；
3. 关闭所有NodePort，对外流量统一走Ingress HTTPS；
4. 严格限制Pod出站，仅放行业务依赖第三方地址；
5. 禁止FAT环境任何Pod主动访问PROD数据库/缓存。

## 六、网络底层核心约束与限制
1. Service ClusterIP网段初始化后永久不可变更；
2. PodIP由Calico动态分配，Pod重建IP随机变化，不能依赖PodIP通信；
3. 跨节点Pod互通依赖Calico路由，删除CNI会导致全网Pod失联；
4. Service虚拟IP仅集群内部可达，外部无法直接访问ClusterIP；
5. Headless Service无ClusterIP，域名直接解析所有后端PodIP；
6. 同一集群内不同Namespace同名Service不冲突，依靠域名区分。

## 七、常用网络验证调试命令
```bash
# 1. 查看PodIP、宿主机IP、命名空间
kubectl get pods -n prod -o wide

# 2. Pod内测试跨ns Service域名连通
kubectl exec -it app-7f9d654c9b -n fat -- curl mysql.prod.svc.cluster.local:3306

# 3. 查看集群网段配置
kubectl describe node k8s-master | grep CIDR

# 4. 测试Pod出网访问外部地址
kubectl exec -it test-pod -n uat -- curl https://www.baidu.com

# 5. 解析Service域名查看DNS返回IP
kubectl exec -it test-pod -n prod -- nslookup order-svc.prod.svc.cluster.local
```

## 八、高频网络基础故障根因
1. 跨节点Pod不通：Calico Pod异常、节点路由丢失、网段配置不一致；
2. Pod能ping通Node但无法访问其他Pod：CNI插件未正常就绪；
3. Service域名解析失败：CoreDNS崩溃、Policy拦截DNS 53端口；
4. 外部无法访问ClusterIP：ClusterIP仅集群内部生效，需Ingress/NodePort/LB；
5. FAT Pod直连PROD中间件成功：未部署默认拒绝NetworkPolicy。

## 九、关联文档
1. 网络底座：`02-cni-overview.md` Calico部署、IP分配、路由机制
2. 四层服务：`03-service-management.md` Service与Headless完整规范
3. 域名解析：`05-dns-service-discovery.md` CoreDNS域名解析原理
4. 网络隔离：`06-network-policy.md` 多环境网段访问控制落地
5. 网络排错：`08-network-troubleshooting.md` 全网不通、跨环境拦截排查SOP
6. 负载均衡：`07-load-balancing.md` 四层流量转发规则
7. 七层网关：`04-ingress-management.md` 外部流量接入规范