# validate-cluster-health.md
# Kubernetes 集群交付验收 & 全维度健康校验标准手册
## 一、文档定位
本文为企业K8s集群交付、扩容、节点替换、变更后的标准化验收SOP，覆盖**基础设施层、控制平面、数据平面、存储、网络、安全、资源、监控备份**八大维度校验项；适用于新建集群交付、节点扩容、故障节点替换、版本升级后的集群健康验收，是平台运维上线必走校验流程。
前置依赖：build-kubernetes-cluster.md、expand-worker-nodes.md、replace-worker-node.md、backup-etcd-cluster.md

## 二、校验前置准备
### 2.1 环境工具依赖
所有校验操作在集群管理节点执行，预装工具清单：
```bash
# 集群基础工具
kubectl、kubectl describe、kubectl get、kubectl top
# 基础设施工具
etcdctl、openssl、curl、wget、ip、ss、tcpdump、ethtool
# 存储校验工具
csi工具、rbd/nfs客户端（按存储类型）
# 监控/日志工具
prometheusctl、grafana-api、journalctl
# 安全校验工具
cfssl、kube-bench
```

### 2.2 前置环境确认
1. 管理员kubeconfig权限完整，具备cluster-admin集群超级权限
2. 集群监控系统（Prometheus+Grafana）正常运行，指标采集无中断
3. 集群日志系统（ELK/Loki）可正常采集组件日志
4. ETCD备份脚本/定时任务已部署，可手动触发备份验证可用性
5. 集群网络插件（Calico/Cilium/Flannel）DaemonSet全部就绪

### 2.3 校验执行顺序规范
严格分层校验，由底层基础设施至上层业务资源，分层定位故障：
1. 宿主机基础设施层（CPU/内存/磁盘/网卡/内核）
2. 控制平面组件（Master节点静态组件、ETCD集群）
3. 集群基础资源调度（节点状态、污点、调度器）
4. 网络数据平面（CNI、Pod互通、Service、网络策略）
5. 存储CSI持久化（PV/PVC读写、快照、扩容）
6. 集群安全校验（证书、权限、基线安全）
7. 集群备份与高可用校验（ETCD、组件多副本故障转移）
8. 监控、日志、告警观测校验
9. 压测模拟验证（可选，企业生产集群强制）

## 三、第一层：宿主机基础设施健康校验（所有Master/Worker节点）
批量遍历所有节点执行校验，可通过ansible批量下发检测脚本。
### 3.1 硬件资源负载校验
```bash
# 查看节点CPU、内存负载，5分钟负载不能超过CPU核心数
uptime
# 实时资源占用，无持续100%CPU、内存OOM
top/htop
# 内存可用充足，无大量Swap占用
cat /proc/meminfo
# 磁盘使用率，系统盘/数据盘阈值<85%
df -h
# 磁盘IO负载，无长期100%IO等待
iostat -x 1
# 磁盘坏块、挂载异常检查
dmesg | grep -i error
```
**验收标准**
1. 节点5分钟平均负载 < CPU核心数量
2. 磁盘使用率 < 85%，无只读挂载、IO报错
3. Swap使用率 < 10%，无持续大量内存交换
4. 无硬件IO故障、内存硬件报错日志

### 3.2 网络硬件与内核校验
```bash
# 网卡速率、双工模式正常，无硬件丢包
ethtool 主网卡名
# 网卡硬件收发错误、FIFO溢出丢包为0
ethtool -S 主网卡名
# 网络软中断均衡分配，无单核软IRQ打满100%
cat /proc/softirqs
# 内核网络转发开启
sysctl net.ipv4.ip_forward
# 防火墙内核模块无冲突，隧道端口放通（VXLAN/Geneve）
# 主机端口无异常大量监听，无高危对外暴露端口
ss -ltnp
```
**验收标准**
1. 网卡无rx_fifo_errors、tx_errors硬件丢包
2. 网络软中断均衡分布至多CPU核心
3. 内核转发参数全部符合集群调优标准
4. 云主机安全组/物理防火墙放通集群所需端口

### 3.3 系统内核与容器运行时校验
```bash
# 内核版本符合集群要求（Cilium需≥5.4，标准集群4.19+）
uname -r
# containerd/crio运行正常，无容器创建报错
systemctl status containerd
# 容器日志磁盘分区不与系统盘共用，防止日志打满系统
# 宿主机时间同步chronyd正常，所有节点时间误差<1s
chronyc tracking
# 系统日志无OOM、内核panic、容器运行时崩溃日志
journalctl -p err -b
```
**验收标准**
1. 所有节点内核版本统一、满足CNI/组件最低要求
2. 容器运行时无异常崩溃、镜像拉取报错
3. 全集群节点时间同步误差小于1秒
4. 无系统级错误日志、内核崩溃记录

## 四、第二层：控制平面高可用校验（Master节点）
适用于3/5 Master高可用集群，单Master集群跳过副本高可用校验。
### 4.1 核心控制组件副本状态校验
```bash
# 查看控制平面静态Pod，全部状态Ready
kubectl get pods -n kube-system -l tier=control-plane -owide
# 组件：kube-apiserver、kube-controller-manager、kube-scheduler、etcd
# 检查组件副本数量，3Master集群各组件副本数=3
kubectl get sts -n kube-system etcd
# 查看组件日志，无报错、重启事件
kubectl logs -n kube-system kube-apiserver-master-0 --previous
# 控制器、调度器多主选举正常，存在leader节点无多主冲突
kubectl get endpoints kube-controller-manager -n kube-system
kubectl get endpoints kube-scheduler -n kube-system
```
**验收标准**
1. 所有控制平面Pod状态Running/Ready，无CrashLoopBackOff重启
2. 多Master集群组件副本数量与Master节点数一致
3. 控制器、调度器正常完成主从选举，无锁竞争报错
4. 组件日志无鉴权失败、连接超时、数据库读写错误

### 4.2 ETCD集群健康与备份校验（核心数据存储）
```bash

cat << 'EOF' >> ~/.bashrc

# ETCDCTL 默认连接配置
export ETCDCTL_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
export ETCDCTL_CERT="/etc/kubernetes/pki/etcd/server.crt"
export ETCDCTL_KEY="/etc/kubernetes/pki/etcd/server.key"
export ETCDCTL_ENDPOINTS="https://127.0.0.1:2379"
EOF
source .bashrc

# 1. ETCD集群整体健康
ETCDCTL_API=3 etcdctl endpoint health
# 2. 查看集群成员，所有节点状态正常
ETCDCTL_API=3 etcdctl member list
# 3. 查看集群告警，无空间不足、碎片告警
ETCDCTL_API=3 etcdctl alarm list
# 4. 手动执行一次全量备份，验证备份脚本可用性
sh /opt/etcd-backup/etcd-backup.sh
# 5. 校验备份文件完整性，可正常读取快照
ls /data/etcd-backup/
etcdctl snapshot status 备份文件.db
# 6. ETCD磁盘使用率阈值<80%，及时碎片整理
```
**验收标准**
1. ETCD所有节点endpoint health返回healthy，无节点失联
2. 集群无任何告警（空间、碎片、节点断开）
3. 定时备份任务执行正常，手动备份可生成完整快照文件
4. ETCD磁盘占用低于80%，无大量碎片导致性能衰减

### 4.3 集群证书与鉴权校验
```bash
# 检查所有证书有效期（至少剩余365天）
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text | grep Not After
# 检查ServiceAccount、RBAC权限无异常集群绑定
kubectl get clusterroles,clusterrolebindings
# 验证管理员、组件ServiceAccount鉴权正常无403
kubectl auth can-i create pods --all-namespaces
```
**验收标准**
1. 所有集群证书有效期剩余≥1年，无即将过期证书
2. RBAC权限分配符合最小权限规范，无全局开放匿名访问
3. 各组件ServiceAccount具备所需操作权限，无鉴权拒绝日志

## 五、第三层：集群节点与调度能力校验
### 5.1 节点全局状态校验
```bash
# 所有节点状态Ready，无NotReady、SchedulingDisabled污点
kubectl get nodes
# 查看节点污点、容忍，扩容/替换节点污点配置和集群标准一致
kubectl describe node 节点名 | grep Taints
# 节点资源分配，CPU/内存分配率<85%，无资源耗尽节点
kubectl top nodes
# 节点内核、容器运行时版本统一
kubectl describe node | grep ContainerRuntimeVersion
```
**验收标准**
1. 全部Master、Worker节点状态为Ready，无隔离、不可调度节点
2. 节点污点、标签统一标准化，新增节点标签与存量一致
3. 节点资源分配水位预留15%以上缓冲，避免调度失败

### 5.2 调度器功能校验
1. 测试普通无状态Deployment正常调度至Worker节点
2. 测试带节点亲和、反亲和、污点容忍的Pod正常调度
3. 资源配额超限场景Pod调度失败，事件提示清晰
4. 节点宕机后，控制器自动驱逐Pod至其他健康节点（模拟故障）

## 六、第四层：集群网络全维度健康校验（核心数据面）
### 4.1 CNI网络组件基础校验
```bash
# CNI DaemonSet全部副本Ready，无重启报错
kubectl get ds -n kube-system calico-node cilium flannel -owide
# 查看CNI节点日志，无隧道创建失败、规则下发失败
kubectl logs -n kube-system ds/calico-node
# 宿主机校验网桥、隧道设备UP，无丢包
ip link show cni0 flannel.1 cilium_geneve
# 内核转发开启，MASQUERADE SNAT规则正常存在
iptables-save | grep MASQUERADE
```
### 4.2 四类流量连通性测试（必测）
1. **同节点Pod互通**
   同一节点两个测试Pod互相ping，双向连通无丢包
2. **跨节点Pod互通**
   不同节点测试Pod互通，隧道报文无丢包、无分片超时
3. **Pod访问Service ClusterIP**
   创建标准ClusterIP服务，Pod内正常访问负载均衡后端
4. **Pod访问外网/NodePort**
   Pod可正常访问互联网；外部客户端通过NodePort访问集群服务

### 4.3 网络安全策略校验
1. 标准NetworkPolicy黑白名单策略生效，阻断/放行符合预期
2. 跨命名空间流量、外网IP访问管控正常
3. Cilium Hubble/Calico日志可捕获策略丢弃流量

**验收标准**
1. CNI所有节点Pod无崩溃重启，隧道设备工作正常
2. 四类流量全部双向100%连通，无丢包、访问超时
3. 网络策略精准生效，无全部放行/全部阻断异常
4. 跨节点隧道端口（UDP8472/6081）防火墙放通

## 七、第五层：存储CSI持久化校验
### 7.1 CSI存储组件状态
```bash
# CSI控制器、节点DaemonSet全部Ready
kubectl get pods -n kube-system -l app=csi
# StorageClass配置正常，默认存储类存在
kubectl get storageclasses.storage.k8s.io
# 无异常PV/PVC，状态全部Bound
kubectl get pv,pvc --all-namespaces
```
### 7.2 持久化功能测试用例
1. 静态PVC、动态PVC自动创建绑定存储卷
2. Pod写入文件，重建Pod后数据持久保留
3. PVC扩容功能正常，无需重启Pod完成容量扩展
4. 存储快照、快照恢复功能可用（企业生产必备）
5. 多节点读写存储卷无锁冲突、数据错乱

**验收标准**
1. 无未绑定PVC、异常Released无法回收PV
2. 数据持久、扩容、快照恢复功能全部正常
3. 存储后端无IO报错、挂载失败日志

## 八、第六层：集群安全基线校验
### 8.1 集群安全基线扫描
```bash
# kube-bench 执行CIS K8s安全基线检测，高危项全部修复
kube-bench master
kube-bench node
```
### 8.2 安全配置校验项
1. 禁用匿名访问、关闭apiserver未认证端口
2. Pod安全上下文：禁止root运行、禁止特权容器
3. 宿主机端口最小化暴露，关闭高危端口
4. 网络策略默认拒绝所有未授权东西向流量
5. Secret资源加密存储，不使用明文配置

**验收标准**
CIS基线高危漏洞清零，中危漏洞有修复方案记录。

## 九、第七层：监控、日志、告警系统校验
### 9.1 监控指标采集校验
1. Prometheus正常采集节点、组件、Pod、容器全量指标
2. Grafana内置大盘无断图、指标缺失
3. 集群资源使用率、网络流量、ETCD性能指标展示正常

### 9.2 日志采集校验
1. 所有命名空间容器日志、控制平面组件日志正常采集至Loki/ELK
2. 日志包含Pod名称、命名空间、节点标签，可过滤检索

### 9.3 告警通知校验
1. 模拟节点NotReady、ETCD告警、Pod崩溃，告警可推送至短信/钉钉/邮件
2. 告警分级清晰，无大量无效告警风暴

## 十、第八层：高可用故障模拟校验（生产集群强制）
### 模拟1：单Master节点下线
关闭其中一台Master节点，校验：
1. apiserver、控制器、调度器自动切换Leader
2. 集群调度、创建Pod、访问Service完全不受影响
3. ETCD集群剩余节点保持健康，无数据丢失

### 模拟2：单Worker节点隔离
节点防火墙阻断集群通信，校验：
1. 节点自动标记NotReady
2. 超过驱逐阈值后Pod被重新调度至其他节点
3. 集群监控触发节点异常告警

### 模拟3：ETCD单节点故障
停止单个ETCD实例，集群读写正常，无数据写入失败。

## 十一、交付验收输出物
集群校验全部通过后，输出《集群健康验收报告》，包含：
1. 集群基础信息（版本、节点数量、CNI、存储类型）
2. 八大维度校验项逐项结果、截图/命令输出日志
3. 发现的风险项、缺陷清单及修复方案
4. ETCD备份可用性验证记录
5. 高可用故障模拟测试记录
6. CIS安全基线扫描报告
7. 验收结论：集群健康，具备业务上线条件

## 十二、故障判定与阻断上线标准
出现以下任意一项，判定集群不健康，禁止交付/业务上线：
1. Master/Worker节点存在NotReady状态
2. ETCD集群节点失联、存在告警、备份失效
3. 控制平面核心组件频繁重启CrashLoopBackOff
4. 跨节点Pod/Service访问不通，网络丢包超时
5. CSI存储PVC无法绑定、数据丢失、扩容失效
6. 监控/日志全量指标采集中断，无告警能力
7. CIS安全基线存在高危未修复漏洞
8. 内核/宿主机持续硬件错误、磁盘空间耗尽风险

## 十三、关联文档索引
build-kubernetes-cluster.md 全新集群部署流程
expand-worker-nodes.md 集群节点扩容操作手册
replace-worker-node.md 故障节点替换恢复流程
backup-etcd-cluster.md ETCD定时备份与快照恢复操作
03-network-data-path.md 集群网络流量连通测试底层原理