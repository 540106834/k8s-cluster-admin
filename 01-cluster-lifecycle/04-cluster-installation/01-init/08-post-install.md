# 08-post-install.md

## 一、文档基础信息

- 前置依赖：
  1. 07-worker-join.md 所有节点加入集群完成
  2. Calico v3.30.4 网络正常
  3. metrics-server 部署完成，`kubectl top` 可用
- 执行节点：仅 `k8s-master-01(192.168.11.161)`
- K8s 版本：v1.32.13
- Pod CIDR：10.32.0.0/16
- 私有镜像仓库：`harbor.jinshaoyong.com/k8s`
- 功能：集群安装后标准化加固、权限、运维工具、验收、优化配置

## 二、集群节点清单

| 主机名 | IP | 角色 |
| -------- | ---- | ------ |
| k8s-master-01 | 192.168.11.161 | 单控制面 |
| k8s-worker-01 | 192.168.11.162 | 工作节点 |
| k8s-worker-02 | 192.168.11.163 | 工作节点 |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库 |

## 三、全集群基础状态总校验（必做）

```bash
# 1. 所有节点状态全部Ready
kubectl get nodes
root@k8s-master-192-168-11-161:~# kubectl get nodes
NAME                        STATUS   ROLES           AGE   VERSION
k8s-master-192-168-11-161   Ready    control-plane   12h   v1.32.13
k8s-node-192-168-11-162     Ready    <none>          93m   v1.32.13
k8s-node-192-168-11-163     Ready    <none>          40s   v1.32.13

# 2. 系统组件Pod全部Running
kubectl get pods -n kube-system
root@k8s-master-192-168-11-161:~# kubectl get pods -n kube-system
NAME                                                READY   STATUS    RESTARTS   AGE                    IP               NODE
calico-kube-controllers-64d54c95d7-kxjrg            true    Running   0          2026-07-04T03:59:38Z   10.32.243.129    k8s-master-192-168-11-161
calico-node-8ffbs                                   true    Running   0          2026-07-04T03:59:38Z   192.168.11.161   k8s-master-192-168-11-161
calico-node-prw8l                                   true    Running   0          2026-07-04T04:11:54Z   192.168.11.162   k8s-node-192-168-11-162
calico-node-xjtz6                                   true    Running   0          2026-07-04T05:44:29Z   192.168.11.163   k8s-node-192-168-11-163
coredns-5d4f6786f8-6m2b2                            true    Running   0          2026-07-03T17:40:55Z   10.32.243.130    k8s-master-192-168-11-161
coredns-5d4f6786f8-jds2h                            true    Running   0          2026-07-03T17:40:54Z   10.32.243.131    k8s-master-192-168-11-161
etcd-k8s-master-192-168-11-161                      true    Running   1          2026-07-03T17:40:49Z   192.168.11.161   k8s-master-192-168-11-161
kube-apiserver-k8s-master-192-168-11-161            true    Running   1          2026-07-03T17:40:49Z   192.168.11.161   k8s-master-192-168-11-161
kube-controller-manager-k8s-master-192-168-11-161   true    Running   1          2026-07-03T17:40:49Z   192.168.11.161   k8s-master-192-168-11-161
kube-proxy-29dsj                                    true    Running   0          2026-07-04T04:11:54Z   192.168.11.162   k8s-node-192-168-11-162
kube-proxy-mh28k                                    true    Running   0          2026-07-04T05:44:29Z   192.168.11.163   k8s-node-192-168-11-163
kube-proxy-nk67x                                    true    Running   1          2026-07-03T17:40:54Z   192.168.11.161   k8s-master-192-168-11-161
kube-scheduler-k8s-master-192-168-11-161            true    Running   1          2026-07-03T17:40:49Z   192.168.11.161   k8s-master-192-168-11-161


# 3. 控制平面组件健康
kubectl get cs
root@k8s-master-192-168-11-161:~# kubectl get cs
Warning: v1 ComponentStatus is deprecated in v1.19+
NAME                 STATUS    MESSAGE   ERROR
controller-manager   Healthy   ok        
scheduler            Healthy   ok        
etcd-0               Healthy   ok

# 4. 资源指标正常（解决Metrics API not available）
kubectl top nodes
kubectl top pods -A

# 5. 网络连通测试
kubectl run test-busybox --image=harbor.jinshaoyong.com/k8s/busybox:latest -- sleep 3600
kubectl get pod test-busybox -o wide
kubectl exec test-busybox -- ping -c 4 10.32.0.10
kubectl delete pod test-busybox
```

## 四、单Master解除控制平面污点（允许业务调度到master）

```bash
root@k8s-master-192-168-11-161:~# kubectl describe node k8s-master-192-168-11-161 | grep Taints
Taints:             node-role.kubernetes.io/control-plane:NoSchedule

# 移除NoSchedule污点，单节点集群必须执行
kubectl taint nodes k8s-master-192-168-11-161 node-role.kubernetes.io/control-plane:NoSchedule-

# 校验污点已清除
kubectl describe node k8s-master-192-168-11-161 | grep Taints
```

## 五、集群默认资源限制配置（防止节点资源耗尽）

### 5.1 创建LimitRange，限制默认Pod资源

```yaml
# /usr/local/src/default-limit-range.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-resource-limit
  namespace: default
spec:
  limits:
  - default:
      cpu: 100m
      memory: 128Mi
    defaultRequest:
      cpu: 50m
      memory: 64Mi
    type: Container
```

```bash
kubectl apply -f /usr/local/src/default-limit-range.yaml
```

### 5.2 全局资源配额（可选，生产多租户）

```yaml
# /usr/local/src/resource-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-resource-quota
  namespace: default
spec:
  hard:
    pods: "100"
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
```

```bash
kubectl apply -f /usr/local/src/resource-quota.yaml
```

## 六、RBAC基础运维账号（只读运维用户）

### 6.1 创建serviceaccount、clusterrolebinding

```yaml
# sa-read-only-user.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: read-user
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: read-user-binding
subjects:
- kind: ServiceAccount
  name: read-user
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f /usr/local/src/read-only-user.yaml
```

### 6.2 提取只读账号kubeconfig（分发运维人员）

```bash
# 解码token
TOKEN=$(kubectl create token read-user -n kube-system)
# 生成独立kubeconfig
cat > read-user-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://192.168.11.161:6443
    insecure-skip-tls-verify: true
  name: k8s-cluster
contexts:
- context:
    cluster: k8s-cluster
    user: read-user
  name: read-user-context
current-context: read-user-context
users:
- name: read-user
  user:
    token: $TOKEN
EOF
```

```bash
root@k8s-manager-192-168-11-6:~# echo $TOKEN | cut -d "." -f2 | base64 -d | jq
{
  "aud": [
    "https://kubernetes.default.svc.cluster.local"
  ],
  "exp": 1783318743,
  "iat": 1783315143,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "cac5b739-22e0-46f9-b2bf-81a0823b65a0",
  "kubernetes.io": {
    "namespace": "kube-system",
    "serviceaccount": {
      "name": "read-user",
      "uid": "1de6afe6-dd76-4f23-8cf3-b2e12f34817c"
    }
  },
  "nbf": 1783315143,
  "sub": "system:serviceaccount:kube-system:read-user"
}
```

## 七、系统内核&kubelet长期优化（全节点执行）

```bash
# 开启内核转发优化
cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
vm.swappiness = 0
EOF
sysctl -p

# 永久关闭swap自检（kubelet兜底）
echo "vm.swappiness=0" >> /etc/sysfs.d/99-swap.conf
```

## 八、Harbor镜像拉取兜底配置校验（全节点核对）

```bash
# 确认containerd跳过harbor证书校验
grep -A5 harbor.jinshaoyong.com /etc/containerd/config.toml

# 测试拉取基础镜像
crictl pull harbor.jinshaoyong.com/k8s/busybox:latest
```

## 九、集群运维快捷工具配置

### 9.1 kubectl 全局别名与补全（已在03配置，校验）

```bash
source /etc/profile
k version
```

### 9.2 集群上下文快捷切换

```bash
# 设置默认上下文
kubectl config use-context kubernetes-admin@kubernetes
# 查看kubeconfig
kubectl config view
```

## 十、集群备份策略（etcd关键数据）

### 10.1 手动备份etcd快照

```bash
# 备份至本地
ETCDCTL_API=3 etcdctl \
--endpoints=https://127.0.0.1:2379 \
--cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
snapshot save /usr/local/src/etcd-snapshot-$(date +%Y%m%d).db
```

### 10.2 定时备份脚本（可选写入crontab）

```bash
# 每日凌晨2点备份etcd
echo "0 2 * * * root ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key snapshot save /data/etcd-backup/etcd-snapshot-\$(date +\%Y\%m\%d).db" >> /etc/crontab
```

## 十一、集群完整验收清单（交付标准）

1. 3台节点全部 Ready，无污点限制调度
2. kube-system 所有组件Pod（etcd、kube-apiserver、calico、metrics-server、coredns）Running
3. `kubectl top nodes / pods` 正常输出资源占用，无Metrics报错
4. Pod跨节点互通，网段10.32.0.0/16
5. 所有系统镜像均从 `harbor.jinshaoyong.com/k8s` 拉取
6. etcd可正常执行快照备份
7. 只读RBAC账号可查看集群资源、无法修改删除
8. 默认Pod资源Limit/Request自动生效

## 十二、常见后期运维故障

1. **Pod无限创建OOM**：检查默认LimitRange资源配置
2. **运维人员无权限查看资源**：使用上文read-user只读kubeconfig
3. **etcd磁盘占用持续上涨**：定期清理旧快照，扩容磁盘
4. **节点重启后网络不通**：核对sysctl bridge iptables转发参数
5. **镜像拉取证书报错**：重新加载containerd `systemctl restart containerd`

## 十三、上下游文档关联

- 上游：07-worker-join.md 节点全部加入、metrics-server部署完成
- 下游：无，集群部署全部完成，进入业务应用部署阶段
- 故障汇总：10-troubleshooting.md 集群后期运维问题章节