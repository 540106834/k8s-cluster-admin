# 03-cluster-planning.md
## 一、文档基础信息
- 归属：前置集群规划文档（部署01~10全流程前置设计）
- 集群类型：单控制平面 Kubernetes v1.32.13
- OS：Ubuntu 22.04 LTS x86_64
- 容器运行时：containerd 2.1.5
- CNI：Calico v3.30.4 BGP模式
- 私有镜像仓库：Harbor 内网独立节点
- 文档用途：资源、网段、域名、端口、存储、高可用、权限整体规划，部署前统一标准

## 二、硬件资源规划

### 2.1 节点清单与配置标准

| 主机名 | IP地址 | 角色 | CPU | 内存 | 系统盘 | 数据盘 | 用途说明 |
| -------- | -------- | ------ | ----- | ------ | -------- | -------- | ---------- |
| k8s-master-01 | 192.168.11.161 | 单控制平面 | ≥2C | ≥4G | 100G SSD | 无 | apiserver/etcd/controller/scheduler，单节点管控集群 |
| k8s-worker-01 | 192.168.11.162 | 业务工作节点 | ≥2C | ≥4G | 100G SSD | 可选 | 运行业务Pod、DaemonSet |
| k8s-worker-02 | 192.168.11.163 | 业务工作节点 | ≥2C | ≥4G | 100G SSD | 可选 | 业务负载冗余，支持Pod跨节点调度 |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库 | ≥2C | ≥4G | 100G | ≥500G HDD/SSD | 存储K8s组件、Calico、业务镜像 |

### 2.2 硬件选型约束

1. 全节点CPU支持x86_64，开启虚拟化可选（用于KVM离线打包镜像）
2. 磁盘优先SSD，etcd/containerd镜像目录IO敏感，禁止机械盘单独承载
3. Harbor数据盘独立挂载，存放镜像层，避免系统盘占满导致仓库宕机
4. 内存最低4G，单Master集群建议master内存6G防止etcd OOM

## 三、网络整体网段规划

### 3.1 主机物理网段

节点管理网段：`192.168.11.0/24`
网关：192.168.11.1
DNS：内网DNS / 公共DNS 223.5.5.5

### 3.2 Pod 网络网段（Calico）

- 全局Pod CIDR：`10.32.0.0/16`
- 单节点Pod子网：`10.32.<节点ID>.0/24`
- 网关模式：IPIP隧道（内网跨主机互通）
- 禁止与主机网段、Service网段冲突

### 3.3 Service 集群网段

- Service CIDR：`10.96.0.0/16`
- ClusterIP默认网关：10.96.0.1（apiserver内部服务）
- DNS Service固定IP：10.96.0.10（coredns）

### 3.4 网段冲突校验规则

1. 192.168.11.0/24（主机）
2. 10.32.0.0/16（Pod）
3. 10.96.0.0/16（Service）
三段完全隔离，无路由重叠。

## 四、域名与 hosts 规划（全节点统一配置 /etc/hosts）

```bash
192.168.11.161 k8s-master-01
192.168.11.162 k8s-worker-01
192.168.11.163 k8s-worker-02
192.168.11.170 harbor.jinshaoyong.com
```

规范：

1. Harbor使用完整域名，不使用IP直连，统一tls跳过配置
2. 节点主机名短名，内部通信使用主机名解析
3. 无内网DNS场景全部依赖hosts静态解析

## 五、端口开放规划（节点防火墙放行）

### 5.1 Master节点入站端口

| 端口 | 协议 | 用途 |
|------|------|------|
| 6443 | TCP | K8s APIServer |
| 2379-2380 | TCP | etcd |
| 10250 | TCP | kubelet |
| 10259 | TCP | kube-scheduler |
| 10257 | TCP | kube-controller-manager |
| 179 | TCP | Calico BGP |
| 4789 | UDP | Calico IPIP隧道 |

### 5.2 Worker节点入站端口
| 端口 | 协议 | 用途 |
|------|------|------|
| 10250 | TCP | kubelet |
| 179 | TCP | Calico BGP |
| 4789 | UDP | Calico IPIP隧道 |
| 30000-32767 | TCP/UDP | NodePort业务端口 |

### 5.3 Harbor节点端口
- 80/443：仓库页面与镜像推拉

## 六、系统目录标准化规划（全节点统一）
```
# 部署源码、离线包、yaml清单统一存放
/usr/local/src/
├── harbor/            # Harbor docker-compose部署目录
├── k8s-deb/           # K8s离线deb安装包
├── k8s-images/        # 离线镜像tar包
├── calico/            # Calico yaml清单
├── metrics-server/    # metrics-server部署文件
├── kubeconfig/        # 所有用户kubeconfig配置文件
├── etcd-backup/       # etcd定时快照备份
└── post-install/      # 集群后运维yaml（RBAC、LimitRange等）

# CRI与CNI标准路径
/opt/cni/bin           # CNI二进制插件
/var/lib/containerd    # containerd镜像/容器数据
/run/containerd        # containerd socket

# K8s系统配置
/etc/kubernetes/       # 集群证书、kubelet配置
/var/lib/kubelet/      # kubelet工作目录
~/.kube/               # 当前用户kubectl配置
```

## 七、软件版本锁定规划（全局统一标准）
1. OS：Ubuntu 22.04 LTS
2. Kubernetes：v1.32.13（全组件kubeadm/kubelet/kubectl版本对齐）
3. containerd：2.1.5
4. runc：v1.3.5
5. crictl：v1.32.0
6. CNI Plugins：v1.5.0
7. Calico：v3.30.4
8. metrics-server：v0.7.2
9. Harbor：稳定生产版（镜像仓库独立维护）

## 八、存储规划
### 8.1 控制平面etcd
- 存储路径：`/var/lib/etcd`
- 要求：SSD，独立磁盘最佳，禁止共享系统盘
- 备份策略：每日定时快照存放 `/usr/local/src/etcd-backup/`，保留7天快照

### 8.2 Containerd镜像存储
路径：`/var/lib/containerd`
磁盘阈值预警：占用80%执行镜像清理+Harbor垃圾回收

### 8.3 Harbor镜像存储
独立数据盘挂载，定期清理废弃Tag、执行registry垃圾回收释放空间

## 九、集群调度与污点规划
1. 单Master集群：部署完成后移除control-plane NoSchedule污点，允许业务调度至master节点
2. 无专用存储节点，业务PV使用本地存储/后续扩展存储类
3. 资源保护：全局LimitRange限制容器默认CPU/内存，防止节点资源耗尽

## 十、认证与权限规划
1. APIServer认证：客户端证书为主，ServiceAccount Token用于集群内部组件
2. 权限分层：
   - admin.conf：cluster-admin 最高权限（仅管理员）
   - 自定义用户：view只读权限（运维查看）
   - ServiceAccount：绑定最小权限ClusterRole（监控、自动化工具）
3. kubeconfig文件权限强制600，禁止明文对外分发

## 十一、集群扩容规划
1. Worker节点横向扩容：新增节点仅执行系统初始化+containerd+k8s deb包，kubeadm join加入集群
2. 镜像扩容：Harbor扩容磁盘，新增镜像项目隔离业务/系统镜像
3. 控制平面扩容（后期升级高可用）：新增master节点，etcd集群扩展三节点

## 十二、安全规划前置标准
1. 全节点永久关闭swap
2. 内核转发参数统一开启iptables bridge转发
3. Harbor内网仓库跳过tls校验，不对外暴露
4. 不使用unsafe私有镜像源，所有镜像内网统一托管
5. 禁用节点防火墙公网暴露端口，仅内网192.168.11.0/24放行集群端口

## 十三、部署流程对应关系
1. 本规划文档为**所有部署操作前置依据**
2. 01-os-init.md：落地系统网段、hosts、内核、目录规划
3. 02-containerd.md：落地CRI目录、镜像仓库规划
4. 04-harbor.md：落地镜像仓库硬件、存储、版本规划
5. 05-kubeadm-init.md：落地Pod/Service网段、API端口规划
6. 06-cni-calico.md：落地Calico网段、端口规划
7. 05-kubeconfig-management/：落地权限、kubeconfig分发规划

## 十四、验收核对清单（部署前确认）
- [ ] 节点IP、主机名、hosts统一规划无冲突
- [ ] Pod/Service/主机三段网段完全隔离不重叠
- [ ] 硬件资源满足最低配置标准
- [ ] 软件版本全部锁定，无浮动latest标签
- [ ] 存储目录、备份路径标准化定义
- [ ] 防火墙端口放行清单确认
- [ ] 权限分层、证书认证方案确认