# 06-cni-calico.md
## 一、文档基础信息
- 前置依赖：`05-kubeadm-init.md` Master节点kubeadm初始化完成，kubectl可正常连接集群
- 执行节点：仅 **k8s-master-01（192.168.11.161）**
- K8s版本：v1.32.13
- Calico固定版本：v3.30.4
- Pod全局网段：`10.32.0.0/16`
- 节点Pod子网段：`10.32.X.0/24`
- 私有镜像仓库：harbor.jinshaoyong.com/k8s
- 下游文档：07-worker-join.md

## 二、集群全局信息
| 主机名 | IP | 角色 |
|--------|----|------|
| k8s-master-01 | 192.168.11.161 | 单控制面 |
| k8s-worker-01 | 192.168.11.162 | 工作节点 |
| k8s-worker-02 | 192.168.11.163 | 工作节点 |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库 |

## 三、前置校验（Master节点执行）
```bash
# 1. 集群连通正常
kubectl get cs
kubectl get nodes
# 预期节点状态 NotReady（未部署CNI）

# 2. 内网Harbor可正常解析
ping harbor.jinshaoyong.com

# 3. CNI插件目录存在（所有节点统一部署）
ls /opt/cni/bin

# 4. 确认集群Pod网段为10.32.0.0/16，与kubeadm初始化参数保持一致
kubectl cluster-info dump | grep 10.32
# 输出关键信息：
# --cluster-cidr=10.32.0.0/16
# podCIDR: "10.32.0.0/24"
```

## 四、Calico镜像离线前置说明

官方Calico yaml默认拉取 `docker.io/calico/*` 外网镜像，内网环境无法访问，处理方案：

1. 提前将 calico v3.30.4 全套镜像上传至 `harbor.jinshaoyong.com/k8s`
   - harbor.jinshaoyong.com/k8s/calico-node:v3.30.4
   - harbor.jinshaoyong.com/k8s/calico-kube-controllers:v3.30.4
   - harbor.jinshaoyong.com/k8s/calicoctl:v3.30.4
2. 下载官方标准yaml，全局替换镜像地址为内网Harbor，同时修改IP池CIDR为`10.32.0.0/16`

## 五、下载并修改Calico部署清单

### 5.1 获取官方标准Calico v3.30.4 manifest

```bash
cd /usr/local/src
# 下载官方BGP模式部署文件
wget https://raw.githubusercontent.com/projectcalico/calico/v3.30.5/manifests/calico.yaml
```

### 5.2 全局替换镜像仓库为内网Harbor

```bash
# 替换 docker.io/calico → harbor.jinshaoyong.com/k8s
sed -i 's|docker.io/calico|harbor.jinshaoyong.com/k8s|g' calico.yaml

# 校验替换结果
grep harbor.jinshaoyong.com/k8s calico.yaml
root@k8s-master-192-168-11-161:~# cat calico.yaml | grep harbor
          image: harbor.jinshaoyong.com/k8s/cni:v3.30.5
          image: harbor.jinshaoyong.com/k8s/cni:v3.30.5
          image: harbor.jinshaoyong.com/k8s/node:v3.30.5
          image: harbor.jinshaoyong.com/k8s/node:v3.30.5
          image: harbor.jinshaoyong.com/k8s/kube-controllers:v3.30.5
```

### 5.3 修改Calico IP池CIDR，匹配集群10.32.0.0/16

```bash
# 将默认10.244.0.0/16替换为集群实际Pod网段10.32.0.0/16
sed -i 's|10.244.0.0/16|10.32.0.0/16|g' calico.yaml

# 校验修改结果
grep CALICO_IPV4POOL_CIDR calico.yaml
# 预期输出：value: "10.32.0.0/16"
```

## 六、部署Calico网络插件

```bash
kubectl apply -f calico.yaml

root@k8s-master-192-168-11-161:~# kubectl  get pods -A | grep calico
kube-system   calico-kube-controllers-64d54c95d7-kxjrg            1/1     Running   0             4m1s
kube-system   calico-node-8ffbs                                   1/1     Running   0             4m1s
root@k8s-master-192-168-11-161:~# kubectl get nodes
NAME                        STATUS   ROLES           AGE   VERSION
k8s-master-192-168-11-161   Ready    control-plane   10h   v1.32.13
```

## 七、部署状态监控

```bash
# 实时查看calico Pod启动状态
kubectl get pods -n kube-system -w

# 等待所有calico-node、calico-kube-controllers状态变为Running
# 全部就绪后，节点状态由NotReady变为Ready
kubectl get nodes
```

## 八、Calico基础验证

```bash
# 1. 查看网络组件运行状态
kubectl get ds calico-node -n kube-system
kubectl get deploy calico-kube-controllers -n kube-system

root@k8s-master-192-168-11-161:~# kubectl get ds calico-node -n kube-system
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
calico-node   1         1         1       1            1           kubernetes.io/os=linux   14m

root@k8s-master-192-168-11-161:~# kubectl get deploy calico-kube-controllers -n kube-system
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
calico-kube-controllers   1/1     1            1           14m


# 2. 测试Pod跨节点通信
# 快速创建测试Pod
kubectl run test --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 3600
kubectl get pod test -o wide
# ping Pod IP验证互通（IP段为10.32.x.x）
kubectl exec test -- ping -c 4 10.32.x.x
```

## 九、calicoctl 工具安装（Master节点运维）

```bash
# 下载calicoctl二进制 v3.30.4
wget https://github.com/projectcalico/calicoctl/releases/download/v3.30.4/calicoctl-linux-amd64
chmod +x calicoctl-linux-amd64
mv calicoctl-linux-amd64 /usr/local/bin/calicoctl

# 配置kubeconfig连接集群
export KUBECONFIG=$HOME/.kube/config
echo "export KUBECONFIG=$HOME/.kube/config" >> /etc/profile

# 验证
calicoctl version
calicoctl get nodes
```

## 十、离线兜底方案（外网无法wget下载calico.yaml/calicoctl）

1. 联网机器下载 `calico.yaml`、`calicoctl-linux-amd64`，上传Master节点 `/usr/local/src`
2. 依次执行镜像替换、网段替换sed命令，再kubectl apply部署

## 十一、验收清单（全部通过再执行节点加入）

1. kube-system下所有calico Pod全部Running，镜像tag为v3.30.4
2. 所有集群节点状态为 Ready
3. Pod网段统一为`10.32.0.0/16`，节点子网`10.32.X.0/24`
4. Pod之间可正常跨节点互通
5. Calico镜像均从 `harbor.jinshaoyong.com/k8s` 拉取
6. calicoctl 版本v3.30.4，可正常查询集群网络资源

## 十二、常见故障排查

1. **calico-node Pod 镜像拉取失败 ImagePullBackOff**
   - 检查镜像是否提前上传 harbor.jinshaoyong.com/k8s，tag为v3.30.4
   - 确认containerd配置harbor跳过tls校验
2. **节点一直 NotReady**
   - 查看calico-node日志：`kubectl logs -n kube-system ds/calico-node`
   - 核对Calico IP池CIDR是否与kubeadm `--pod-network-cidr=10.32.0.0/16` 完全一致
3. **Pod无法跨节点通信**
   - 检查内核模块 overlay、br_netfilter 是否加载
   - 确认sysctl net.bridge.bridge-nf-call-iptables=1
4. **calico-node CrashLoopBackOff**
   - 检查节点防火墙/安全组是否放行IPIP/BGP端口

## 十三、上下游文档关联

- 上游：05-kubeadm-init.md 集群控制面初始化完成
- 下游：07-worker-join.md 工作节点加入集群
- 故障汇总：10-troubleshooting.md CNI网络异常章节