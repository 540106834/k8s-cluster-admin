# 02-cni-overview.md
## 一、文档基础信息
- 归属目录：`03-network-management/`
- 前置阅读：`00-README.md`、`01-kubernetes-network-model.md`
- 集群基准：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：CNI标准规范、Calico底层架构、IP分配、路由转发、离线部署、版本升级、网段固化、集群网络初始化配置、分环境调优、CNI故障排查

## 二、CNI 底层标准理论
### 2.1 CNI 定义
CNI（Container Network Interface）容器网络接口，是K8s标准网络插件规范，定义容器创建/销毁时网络配置调用接口，kubelet通过CNI二进制为Pod分配IP、网桥、路由。
### 2.2 CNI 执行流程
1. kubelet创建Pod沙箱容器；
2. 调用 `/opt/cni/bin/` 下CNI插件二进制；
3. 分配PodIP、创建网卡、配置宿主机路由；
4. Pod销毁时执行DEL操作，回收IP地址。
### 2.3 必备组件
1. CNI二进制工具：bridge、calico、ipam、host-local等；
2. CNI配置目录：`/etc/cni/net.d/`，网络策略、IP池、路由规则；
3. IPAM：IP地址管理组件，Calico内置IPAM统一管控PodCIDR。

### 2.4 K8s网络模型强制约束
CNI插件必须满足四大网络公理：
1. Pod之间同/跨节点直接互通，无NAT；
2. Pod与宿主机双向互通；
3. Pod访问Service ClusterIP透明转发；
4. Pod可正常访问集群内外网络。

## 三、Calico 底层架构原理
### 3.1 组件拆分
1. calico/node：每节点DaemonSet，负责IP分配、BGP路由、数据包转发、网络策略执行；
2. calico/kube-controllers：监听K8s资源同步至Calico数据存储；
3. calicoctl：Calico命令行管理工具；
4. calico-apiserver（可选）：CRD方式管理IP池、网络策略。

### 3.2 核心工作机制
1. **IPAM IP地址池**
   基于集群预定义PodCIDR分段分配IP，FAT/UAT/PROD独立IP池互不重叠，自动回收销毁Pod的IP。
2. **BGP路由转发**
   节点间建立BGP邻居，同步各节点Pod网段路由，实现跨节点Pod直连；机房物理交换机可开启BGP路由反射器。
3. **Packet Filter 网络策略**
   内核iptables/ipset实现NetworkPolicy黑白名单流量拦截，底层由calico/node实时同步规则。
4. **VXLAN隧道模式（默认离线集群）**
   节点跨网段无法BGP直连时启用VXLAN封装，Pod数据包封装在宿主机UDP 4789端口传输，适配机房内网隔离场景。

### 3.3 两种转发模式对比
| 模式 | 适用场景 | 优势 | 劣势 |
|------|----------|------|------|
| BGP直连 | 机房交换机支持BGP | 无封装，性能高，延迟低 | 交换机需配置路由反射器 |
| VXLAN隧道 | 通用机房、离线隔离集群 | 无需交换机配置，开箱即用 | 数据包封装，少量性能损耗 |

## 四、集群网段规划与IP池规范（FAT/UAT/PROD隔离）
### 4.1 全局网段固化规则
1. 三套业务环境PodCIDR、ServiceCIDR完全不重叠；
2. 集群初始化`kubeadm init --pod-network-cidr`必须与Calico IP池配置完全一致；
3. 集群部署完成后**禁止修改PodCIDR**，修改需重建集群。

### 4.2 标准网段分配
| 环境 | Pod CIDR | Calico IP池 | Service CIDR |
|------|----------|-------------|--------------|
| FAT  | 10.244.0.0/16 | 10.244.0.0/16 | 10.96.0.0/16 |
| UAT  | 10.245.0.0/16 | 10.245.0.0/16 | 10.97.0.0/16 |
| PROD | 10.246.0.0/16 | 10.246.0.0/16 | 10.98.0.0/16 |

### 4.3 IP池细分优化（生产）
PROD环境拆分多子IP池，按节点标签分配分段IP，便于流量统计与故障隔离，避免单一IP池耗尽。

## 五、Calico 离线部署完整流程（内网Harbor）
### 5.1 前置准备
1. 下载Calico官方yaml，替换镜像地址为内网Harbor；
2. 离线导出镜像tar包，所有节点导入containerd；
3. 确认kubeadm初始化时传入`--pod-network-cidr`匹配Calico IP池；
4. 关闭节点防火墙/放行VXLAN 4789、BGP 179端口。

### 5.2 标准部署命令
```bash
# 应用Calico核心资源
kubectl apply -f calico-offline.yaml -n kube-system

# 等待calico/node全部就绪
kubectl get ds calico-node -n kube-system -w

# 验证网络连通性
kubectl run test-pod --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 3600
kubectl exec test-pod -- ping 10.244.1.10 -c 3
```

### 5.3 离线镜像替换规范
原始镜像 `docker.io/calico/*` 统一替换为 `harbor.jinshaoyong.com/k8s/calico/*`，提前批量推送至内网仓库。

## 六、Calico 版本升级操作规范
### 6.1 升级前置检查
1. 当前Calico所有节点Pod全部Ready，无网络故障；
2. 导出当前Calico yaml、IP池、NetworkPolicy备份；
3. 内网Harbor预上传新版本Calico镜像；
4. 业务低峰窗口执行升级，避免业务网络中断。

### 6.2 滚动升级步骤
1. 应用新版本calico yaml资源：
```bash
kubectl apply -f calico-v3.31-offline.yaml
```
2. 观测calico-node DaemonSet滚动更新进度：
```bash
kubectl rollout status ds calico-node -n kube-system -w
```
3. 全部节点更新完成后，跨Pod连通性验证；
4. 异常回滚：apply旧版本yaml，等待Pod重建恢复网络。

### 6.3 升级约束
禁止跨大版本跳跃升级，采用递进式小版本迭代；升级期间网络策略短暂失效，核心业务建议扩容兜底。

## 七、分环境Calico配置差异化规范
### DEV本地
Kind/minikube内置CNI，无需独立部署Calico，无IP池隔离限制。
### FAT测试
1. VXLAN隧道模式；
2. IP池宽松，不细分子段；
3. NetworkPolicy可临时关闭调试；
4. 升级流程简化，故障可直接重建。
### UAT预生产
1. 对齐PROD VXLAN/BGP配置；
2. IP池分段规划；
3. 强制开启默认拒绝NetworkPolicy；
4. 升级流程完全复刻生产操作。
### PROD生产（强约束）
1. 优先BGP直连模式，机房不支持则使用VXLAN；
2. IP池按业务标签拆分多段，精细化管控；
3. 永久开启全局默认拒绝网络策略；
4. calico-node资源配置requests/limits，防止抢占节点资源；
5. 升级双人复核，升级前etcd快照备份；
6. 监控calico-node Pod状态、IP分配耗尽告警。

## 八、Calico 日常运维操作命令
```bash
# 查看Calico节点状态
kubectl get ds calico-node -n kube-system
kubectl describe ds calico-node -n kube-system

# 查看IP地址池
kubectl get ippools.crd.projectcalico.org

# 查看节点BGP邻居状态
kubectl exec -n kube-system ds/calico-node -- calicoctl node status

# 查看Pod路由分配
kubectl exec -it test-pod -n prod -- ip route

# 查看Calico日志（网络不通排错）
kubectl logs -n kube-system calico-node-xxxx calico-node
```

## 九、高频CNI/Calico故障根因与修复
### 1. calico-node Pod CrashLoopBackOff
- PodCIDR与IP池网段不匹配；
- 节点4789/179端口被防火墙拦截；
- 内网Harbor镜像拉取失败；
修复：核对pod-network-cidr、放行防火墙端口、同步离线镜像。

### 2. 同节点Pod互通，跨节点Pod无法访问
- VXLAN 4789端口拦截；
- BGP邻居未建立，路由缺失；
修复：放行UDP 4789，检查BGP交换机配置。

### 3. Pod创建Pending，报错Failed to allocate IP
Calico IP池地址耗尽，扩容IP池或清理闲置Pod释放IP。

### 4. 部署Calico后节点NotReady
kubelet等待CNI就绪超时，等待calico-node全部启动后自动恢复。

### 5. 网络策略不生效
calico-node重启未同步规则、Policy标签匹配错误；重启calico-node重建过滤规则。

### 6. 升级Calico后全网Pod断网
新旧版本CRD不兼容，回滚至旧稳定版本，采用递进式升级。

## 十、生产最佳实践
1. 集群初始化pod-network-cidr与Calico IP池严格一一对应；
2. 离线环境全量镜像托管内网Harbor，禁止外网拉取；
3. PROD环境拆分多IP池，避免单一网段IP耗尽；
4. 监控calico-node Pod状态、IP池剩余地址告警；
5. 网络变更、Calico升级前导出yaml备份并执行etcd快照；
6. 机房条件允许优先使用BGP模式降低网络延迟；
7. 定期清理废弃IP、无效路由，保持网络表整洁。

## 十一、关联文档
1. 网络模型基础：`01-kubernetes-network-model.md` Pod/Service网段规划规范
2. 四层服务：`03-service-management.md` Service转发依赖CNI底层互通
3. 网络安全隔离：`06-network-policy.md` Calico NetworkPolicy落地细则
4. 网络故障排查：`08-network-troubleshooting.md` CNI异常、跨节点不通完整排错SOP
5. 集群部署：集群初始化文档 kubeadm pod-network-cidr配置
6. 集群升级：`cluster-upgrade-theory-guide.md` CNI插件版本升级兼容要求