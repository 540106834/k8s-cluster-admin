# 05-kubeadm-init.md
## 一、文档基础信息
- 前置依赖：03-kubernetes-packages.md 二进制安装kubeadm/kubelet/kubectl完成
- 执行节点：仅 **k8s-master-01（192.168.11.161）** 单Master集群
- K8s版本：v1.32.13
- 容器运行时：containerd v2.1.5-1
- 私有镜像仓库：`harbor.jinshaoyong.com/k8s/`
- 两种初始化方式：
  1. 命令行传参快速初始化
  2. YAML配置文件标准化初始化（生产推荐）
- 下游文档：06-cni-calico.md

## 二、集群全局网段规划
| 网段 | 用途 |
|------|------|
| 10.244.0.0/16 | Pod网段（Calico） |
| 10.96.0.0/12 | Service虚拟网段 |
| 192.168.11.0/24 | 节点物理内网网段 |

## 三、Master节点前置校验（全部通过再执行初始化）
```bash
# 1. 组件版本校验
kubeadm version
kubectl version --client
kubelet --version

# 2. containerd正常运行、CRI连通正常
systemctl status containerd
crictl info

# 3. CNI插件目录完整
ls /opt/cni/bin

# 4. Swap已永久关闭
free -h

# 5. 私有仓库域名解析正常
ping harbor.jinshaoyong.com
# 测试仓库连通
curl -k https://harbor.jinshaoyong.com/v2/_catalog
```

## 四、方式一：kubeadm init 命令行直接传参
```bash
kubeadm init \
  --kubernetes-version=v1.32.13 \
  --apiserver-advertise-address=192.168.11.161 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --cri-socket=unix:///run/containerd/containerd.sock \
  --image-repository=harbor.jinshaoyong.com/k8s \
  --ignore-preflight-errors=NumCPU,Mem
```
### 关键参数说明
1. `--image-repository=harbor.jinshaoyong.com/k8s`
   控制平面组件镜像全部从内网私有仓库拉取，无需访问外网k8s官方镜像源
2. `--apiserver-advertise-address`：单Master本机内网IP
3. `--cri-socket`：指定containerd运行时套接字
4. `--ignore-preflight-errors`：低配机器忽略CPU、内存预检报错

## 五、方式二：YAML配置文件初始化（生产标准推荐）
### 5.1 导出默认模板
```bash
kubeadm config print init-defaults > /usr/local/src/kubeadm-init.yaml
```

### 5.2 完整可执行 kubeadm-init.yaml（适配单Master+内网Harbor）
```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.11.161
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: k8s-master-01
  imagePullPolicy: IfNotPresent
  # 统一systemd cgroup驱动，与containerd配置对齐
  kubeletExtraArgs:
    cgroup-driver: systemd
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.32.13
# 全局镜像仓库替换为内网Harbor k8s项目
imageRepository: harbor.jinshaoyong.com/k8s
controlPlaneEndpoint: 192.168.11.161:6443
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
  podSubnet: 10.244.0.0/16
# 组件监听0.0.0.0，允许节点内网访问
scheduler:
  extraArgs:
    bind-address: 0.0.0.0
controllerManager:
  extraArgs:
    bind-address: 0.0.0.0
# 单Master本地etcd存储
etcd:
  local:
    dataDir: /var/lib/etcd
```

### 5.3 使用yaml文件执行初始化
```bash
kubeadm init --config /usr/local/src/kubeadm-init.yaml --ignore-preflight-errors=NumCPU,Mem
```

## 六、初始化完成后配置kubectl管理员权限（Master必操作）
```bash
# 创建用户kubeconfig目录
mkdir -p $HOME/.kube
# 复制集群管理员证书配置
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
# 赋予当前用户读写权限
chown $(id -u):$(id -g) $HOME/.kube/config

# 验证集群连通
kubectl get nodes
kubectl get cs
```

## 七、保存Worker节点加入命令（供给07-worker-join.md）
初始化成功输出示例，复制保存：
```
kubeadm join 192.168.11.161:6443 --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxx
```
### Token过期重新生成join命令
```bash
# 生成24小时有效期节点接入命令
kubeadm token create --print-join-command
```

## 八、单Master解除控制平面污点，允许调度业务Pod
```bash
kubectl taint nodes k8s-master-01 node-role.kubernetes.io/control-plane:NoSchedule-
```

## 九、集群初始化验收清单
```bash
# 1. 核对集群版本
kubectl version
# 2. 控制平面组件健康状态
kubectl get cs
# 3. 查看已拉取的控制平面镜像（全部来自harbor.jinshaoyong.com/k8s）
crictl images | grep harbor.jinshaoyong.com/k8s
# 4. 节点状态（未部署Calico前为NotReady，正常）
kubectl get nodes
# 5. kubeconfig权限校验
ls -l $HOME/.kube/config
```

## 十、常见故障排查
1. **镜像拉取失败**
   - 确认containerd已配置 `harbor.jinshaoyong.com` 跳过tls校验
   - 确认Harbor仓库存在`k8s`项目，且镜像已提前上传
   - 全节点hosts解析192.168.11.170 harbor.jinshaoyong.com
2. **CRI运行时不匹配报错**
   核对yaml/命令行 `cri-socket` 路径与containerd套接字一致
3. **cgroup驱动冲突**
   确保containerd与kubelet均使用`systemd`驱动
4. **apiserver绑定IP失败**
   advertiseAddress填写本机内网IP `192.168.11.161`
5. **preflight内存/CPU报错**
   添加参数 `--ignore-preflight-errors=NumCPU,Mem`

## 十一、上下游文档关联
- 上游：03-kubernetes-packages.md
- 下游：06-cni-calico.md 部署Calico网络插件
- 节点扩容：07-worker-join.md 使用kubeadm join接入工作节点
- 故障汇总：10-troubleshooting.md kubeadm init初始化失败章节