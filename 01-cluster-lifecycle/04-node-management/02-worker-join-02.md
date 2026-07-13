# Kubernetes Node 节点加入集群完整流程

这是 Kubernetes 生命周期中非常重要的一部分。**`kubeadm join`****一个 Node 加入集群，并不仅仅是执行了一条  命令，而是完成了从"一台普通 Linux 主机"到"Kubernetes Worker 节点"的一系列初始化。**  
整个过程可以分为 **控制面（API Server）** 和 **Node 本地** 两部分来看。

## 整体流程

```text
kubeadm join
      │
      ▼
Node 注册到 API Server
      │
      ▼
获取集群证书
      │
      ▼
启动 kubelet
      │
      ▼
Node 对象注册
      │
      ▼
Controller 为 Node 分配 PodCIDR
      │
      ▼
CNI DaemonSet 调度到该 Node
      │
      ▼
CNI 配置网络
      │
      ▼
kube-proxy 调度到该 Node
      │
      ▼
Node Ready
```

## 第一阶段：执行 kubeadm join

示例命令：

```bash
kubeadm join 192.168.11.10:6443 \
  --token xxxx \
  --discovery-token-ca-cert-hash sha256:xxxx
```

核心完成三项工作：

### ① 校验 Token

向 API Server 发起节点入网认证，校验三项核心信息：

- 集群 Token
- CA 证书哈希
- 集群基础信息

### ② 下载集群配置

从控制面拉取核心配置并持久化至本地：集群配置、kubelet 配置、CA 证书、API Server 访问地址。

### ③ 生成 kubelet 本地配置

生成 kubelet 连接集群的核心配置文件：

- `/var/lib/kubelet/config.yaml`
- `/var/lib/kubelet/kubeconfig`

后续 kubelet 依托该配置与 API Server 建立长期通信。

## 第二阶段：启动 kubelet

启动 kubelet 服务：`systemctl start kubelet`  
服务启动后自动执行逻辑：kubelet 主动连接 API Server → 提交节点注册请求 → 集群生成 Node 资源对象。  
执行 `kubectl get nodes` 可查询到新增工作节点，但此时节点状态为 **NotReady**，核心原因：节点网络尚未初始化完成。

## 第三阶段：Controller Manager 工作

控制面 Controller Manager 监测到新增 Node 后，由 NodeController 自动为节点分配专属 **PodCIDR**，标记节点可使用的 Pod 网段。  
可通过 `kubectl describe node worker01` 查看分配结果，示例：`PodCIDR: 10.244.3.0/24`。  
**核心作用**：该网段下所有 `10.244.3.x` 网段 Pod，均归属当前节点管理，是集群 Pod 网络互通的基础。

## 第四阶段：DaemonSet 自动调度

节点基础注册完成后，DaemonSet Controller 识别新节点，自动调度集群网络核心组件至该节点：

- 网络插件 Pod（calico\-node / flannel）
- kube\-proxy Pod

执行 `kubectl get pods -n kube-system -o wide`，可查询到对应组件 Pod 运行在当前新节点。

## 第五阶段：CNI 网络初始化

以 Flannel 插件为例，核心流程：

1. 启动 flanneld 守护进程
2. 从 API Server 读取当前节点 Node 信息与 PodCIDR 网段
3. 本地创建虚拟网卡：`cni0`（节点 Pod 网关）、`flannel.1`（隧道网卡）
4. 配置节点路由规则，打通集群各节点 Pod 网段互通

完成后，集群内不同节点的 `10.244.x.0/24` 网段可相互通信。

## 第六阶段：kube\-proxy 初始化

kube\-proxy 启动后持续监听集群 Service、EndpointSlice 资源变化，根据集群网络模式（iptables / IPVS）自动生成转发规则。  
执行 `iptables -t nat -L` 可看到集群专属规则：`KUBE-SERVICES`、`KUBE-NODEPORTS`，实现 Service 流量转发能力。

## 第七阶段：Node 状态就绪（Ready）

网络与代理组件初始化完成后，节点状态更新：

- 节点条件：`NetworkUnavailable=False`、`Ready=True`
- 集群调度器（Scheduler）正式将该节点纳入调度池，可正常调度、运行业务 Pod

## 节点加入：本地机器变更

原有基础组件：containerd、kubelet

新增核心内容：

- 目录：`/var/lib/kubelet/`、`/etc/cni/net.d/`、`/opt/cni/bin/`
- 虚拟网卡：`cni0`、`flannel.1`、`vxlan.calico`、`tunl0`
- 路由规则：新增节点专属 Pod 网段路由（10\.244\.x\.x 系列）
- 防火墙规则：KUBE 系列 Service、CNI 网络转发 iptables 规则

## 节点加入：API Server 集群变更

- 新增 Node 资源对象，状态标记为 Ready
- 新增节点 Lease 租约资源，用于节点心跳保活
- 自动创建 calico\-node、kube\-proxy 等 DaemonSet 核心 Pod

## 整体时序总结

```text
kubeadm join
      │
      ▼
与 API Server 建立信任（Token、证书校验）
      │
      ▼
启动 kubelet，完成 Node 对象集群注册
      │
      ▼
Controller Manager 为节点分配专属 PodCIDR
      │
      ▼
DaemonSet 调度 CNI 网络组件、kube-proxy 至当前节点
      │
      ▼
CNI 初始化宿主机网络（网桥、隧道、路由、虚拟网卡）
      │
      ▼
kube-proxy 生成 Service 流量转发规则
      │
      ▼
Node 状态变为 Ready，集群调度器可正常调度业务 Pod
```

## 组件职责划分

- **kubeadm**：负责节点入网认证、集群配置拉取、节点初始化基础工作
- **kubelet**：节点注册、节点状态上报、全生命周期 Pod 管理
- **controller\-manager**：为新节点分配 PodCIDR 网段
- **CNI 插件**：初始化宿主机网络，打通集群 Pod 内网互通
- **kube\-proxy**：维护 Service 转发规则，实现集群服务访问
- **Scheduler**：仅节点 Ready 后，对其进行业务 Pod 调度
- 