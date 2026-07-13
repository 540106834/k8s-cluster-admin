# 10-troubleshooting.md
## 一、文档基础信息
本文档汇总整套部署流程全链路故障排查方案，覆盖：
01-os-init、02-containerd、03-kubernetes-packages、04-harbor、05-kubeadm-init、06-cni-calico、07-worker-join、08-post-install、09-upgrade
集群基础信息：
- K8s：v1.32.13 单Master
- containerd：2.1.5-1（离线deb）
- runc：v1.3.5 二进制、crictl v1.32.0 二进制
- CNI-Plugins：v1.5.0 wget部署 /opt/cni/bin
- Calico：v3.30.4，Pod网段 10.32.0.0/16
- 私有仓库：harbor.jinshaoyong.com/k8s 192.168.11.170
- cgroup驱动统一：systemd

## 二、01-os-init.md 系统初始化故障
### 1. swap 关闭后重启恢复
```bash
# 永久关闭swap
sed -i '/swap/s/^/#/' /etc/fstab
swapoff -a
```
### 2. iptables/bridge转发异常，Pod网络不通
```bash
# 临时生效
sysctl -w net.bridge.bridge-nf-call-iptables=1
sysctl -w net.bridge.bridge-nf-call-ip6tables=1
sysctl -w net.ipv4.ip_forward=1
# 永久写入
cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl -p
```
### 3. hosts 域名解析失败（harbor/节点名无法ping）
核对 `/etc/hosts` 存在：
```
192.168.11.161 k8s-master-01
192.168.11.162 k8s-worker-01
192.168.11.163 k8s-worker-02
192.168.11.170 harbor.jinshaoyong.com
```

## 三、02-containerd.md 运行时故障
### 1. containerd 启动失败
1. 检查配置语法
```bash
containerd config default > /etc/containerd/config.toml
systemctl restart containerd
```
2. 查看详细日志
```bash
journalctl -u containerd -f
```
### 2. 拉取Harbor镜像报tls证书错误
核心配置缺失/未生效：
```toml
[plugins.cri.registry.configs."harbor.jinshaoyong.com".tls]
  insecure_skip_verify = true
```
修改后重载：`systemctl restart containerd`
### 3. cgroup驱动不匹配报错
containerd config.toml 必须：
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```
### 4. crictl info 连接超时
检查socket权限：`ls /run/containerd/containerd.sock`，确保containerd正常running
### 5. CNI插件找不到
确认文件存在 `/opt/cni/bin/`，权限755，重新执行解压wget命令

## 四、03-kubernetes-packages.md K8s组件安装故障
### 1. apt 找不到 v1.32 版本
旧源 `kubernetes/apt` 最高1.28，切换新版分版本源：
```bash
rm -f /etc/apt/sources.list.d/kubernetes.list
apt install ca-certificates curl gnupg
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.32/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt update
apt-cache madison kubeadm
```
### 2. 外网无法下载deb，安装失败
使用离线包方案，上传deb到 `/usr/local/src/k8s-deb`
```bash
cd /usr/local/src/k8s-deb
apt install -y ./*.deb
apt-mark hold kubeadm kubelet kubectl
```
### 3. kubelet 反复重启
未执行 `kubeadm init/join`，缺少节点配置文件，属于正常现象，无需处理
### 4. kubectl 别名k不生效
```bash
source /etc/profile
```

## 五、04-harbor.md 镜像仓库故障（仅镜像维护）
### 1. kubeadm拉取镜像404
1. Harbor项目 `k8s` 为公开
2. 对应tag镜像已上传 `harbor.jinshaoyong.com/k8s/*:v1.32.13`
3. 镜像tag严格匹配集群版本
### 2. curl访问harbor接口超时
关闭节点防火墙 `systemctl stop ufw && systemctl disable ufw`
### 3. 磁盘空间不足
执行垃圾回收：
```bash
cd /usr/local/src/harbor
docker-compose down
docker run --rm -v /data/harbor:/data/harbor -v ./config/registry.yml:/etc/registry/config.yml goharbor/registry-photon:v2.11.0 garbage-collect /etc/registry/config.yml
docker-compose up -d
```

## 六、05-kubeadm-init.md 集群初始化故障

### 1. 镜像拉取 ImagePullBackOff

1. kubeadm `imageRepository: harbor.jinshaoyong.com/k8s`
2. 全套控制平面镜像提前上传Harbor k8s项目
3. containerd 配置跳过tls校验

### 2. CRI socket 不匹配
命令行/yaml 统一使用 `unix:///run/containerd/containerd.sock`
### 3. 内存/CPU预检报错
追加参数 `--ignore-preflight-errors=NumCPU,Mem`
### 4. apiserver无法绑定IP
`advertiseAddress` 填写本机内网IP `192.168.11.161`
### 5. init输出join token过期
```bash
kubeadm token create --print-join-command
```

## 七、06-cni-calico.md 网络插件故障 v3.30.4
### 1. calico-node ImagePullBackOff
提前上传 `harbor.jinshaoyong.com/k8s/calico-node:v3.30.4` 全套镜像
### 2. 节点长期 NotReady
1. 查看calico日志：`kubectl logs -n kube-system ds/calico-node`
2. 核对CIDR：`CALICO_IPV4POOL_CIDR: "10.32.0.0/16"`
3. 内核转发参数开启
### 3. Pod跨节点不通
检查节点防火墙放行IPIP/BGP；内核模块overlay、br_netfilter加载
### 4. calico-node CrashLoopBackOff
节点防火墙拦截4789、179端口

## 八、07-worker-join.md 节点加入集群故障
### 1. CA hash 校验失败
Master重新生成完整join命令：`kubeadm token create --print-join-command`
### 2. token 过期
```bash
kubeadm token create --ttl 24h --print-join-command
```
### 3. join后节点NotReady
Calico未正常部署，查看calico Pod状态
### 4. kubectl top nodes 报错 Metrics API not available
缺少metrics-server，部署组件并添加 `--kubelet-insecure-tls` 参数

## 九、08-post-install.md 集群运维常见问题
### 1. Pod OOM频繁被杀
补充全局LimitRange资源限制，给业务Pod增加内存request/limit
### 2. 只读账号无权限查看资源
重新生成ServiceAccount与ClusterRoleBinding view权限
### 3. etcd备份失败
核对etcd证书路径、etcdctl API版本3、本地2379端口监听正常
### 4. 单Master无法调度业务Pod
移除控制平面污点：
```bash
kubectl taint nodes k8s-master-01 node-role.kubernetes.io/control-plane:NoSchedule-
```

## 十、09-upgrade.md 集群升级故障
### 1. apt找不到目标升级版本
切换kubernetes-new分版本源，清理旧kubernetes.list
### 2. 升级后控制平面镜像404
提前上传新版本全套k8s、calico镜像至Harbor k8s项目
### 3. Worker升级后节点NotReady
重启kubelet、检查calico镜像tag版本
### 4. 升级后top无指标
同步升级metrics-server对应兼容版本
### 5. 升级异常回滚
1. 降级kubeadm/kubelet/kubectl至旧版本
2. 重启kubelet
3. 严重故障使用升级前etcd快照恢复集群

## 十一、通用集群排查命令大全
### 1. 节点基础状态
```bash
kubectl get nodes -o wide
kubectl describe node <节点名>
systemctl status containerd kubelet
crictl info
```
### 2. Pod异常排查
```bash
kubectl get pods -n kube-system
kubectl logs -n kube-system <pod-name>
kubectl describe pod <pod-name>
```
### 3. 网络排查
```bash
calicoctl get nodes
kubectl exec <pod> -- ping <其他PodIP>
ls /opt/cni/bin
```
### 4. 镜像拉取排查
```bash
crictl images
crictl pull harbor.jinshaoyong.com/k8s/pause:3.10
grep harbor /etc/containerd/config.toml
```
### 5. 集群版本&组件健康
```bash
kubectl version
kubeadm version
kubectl get cs
kubectl top nodes
```
### 6. 重置节点（重装场景）
```bash
kubeadm reset -f
rm -rf /etc/kubernetes /var/lib/kubelet $HOME/.kube
systemctl restart kubelet
```