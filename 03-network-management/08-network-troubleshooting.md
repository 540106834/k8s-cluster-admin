# 08-network-troubleshooting.md

## 一、文档基础信息

- 归属目录：`03-network-management/`
- 前置阅读：00~07 全网络管理文档、`02-workload-management/10-workload-troubleshooting.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4、ipvs kube-proxy、Ingress-Nginx、CoreDNS
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心定位：集群网络全链路标准化排错SOP，分层定位CNI底层、Pod互通、DNS、Service四层、Ingress七层、NetworkPolicy拦截类故障，包含定位命令、根因、修复方案、生产应急处置规范

## 二、统一分层排查流程（所有网络故障固定执行顺序）

1. **基础Pod状态校验**

```bash
kubectl get pods -A -o wide
# 重点查看：calico-node、coredns、ingress-controller、业务Pod状态
```
2. **事件定位（调度/IP分配/探针/策略报错核心依据）**

```bash
kubectl describe pod ${pod-name} -n ${ns}
```
3. **底层连通性测试**
```bash
# 进入测试Pod基础调试
kubectl exec -it test-pod -n ${ns} -- sh
# 基础工具：ping/curl/nslookup/telnet/dig
```
4. **CNI/Calico底层校验**
```bash
kubectl logs -n kube-system ds/calico-node
kubectl exec -n kube-system ds/calico-node -- calicoctl node status
```
5. **Service与EndpointSlice校验**
```bash
kubectl get svc,endpointslices -n ${ns}
kubectl describe svc ${svc-name} -n ${ns}
```
6. **DNS解析校验**
```bash
kubectl exec -it test-pod -n ${ns} -- nslookup ${domain}
kubectl logs -n kube-system deploy/coredns -f
```
7. **网络策略拦截校验**
```bash
kubectl get networkpolicy -n ${ns}
kubectl describe networkpolicy -n ${ns}
```
8. **Ingress七层网关日志排查**
```bash
kubectl logs -n kube-system ds/nginx-ingress-controller -f
```

## 三、CNI / Calico 底层网络故障
### 3.1 calico-node CrashLoopBackOff，Pod无法分配IP
**根因**
1. kubeadm `pod-network-cidr` 与Calico IP池网段不匹配；
2. 节点防火墙拦截VXLAN 4789 / BGP 179端口；
3. 内网Harbor calico镜像拉取失败；
4. 多节点BGP邻居建立失败，路由表缺失。
**修复**
1. 核对集群初始化PodCIDR与ippools配置；
2. 放行节点UDP 4789、TCP 179；
3. 离线导入镜像至所有节点containerd；
4. 切换VXLAN隧道模式规避交换机BGP限制。

### 3.2 同节点Pod互通，跨节点Pod完全不通
**根因**
- VXLAN 4789端口被安全组/防火墙拦截；
- 节点间BGP路由未同步，目标Pod网段无路由；
- calico-node进程异常退出。
**修复**
放行4789端口，重启calico-node，查看BGP邻居状态。

### 3.3 Pod创建Pending，报错Failed to allocate IP
**根因** Calico IP池地址耗尽
**修复** 清理闲置Pod释放IP，或扩容IP池CIDR段。

### 3.4 节点状态NotReady，cni未就绪
kubelet等待CNI网络就绪超时，等待calico-node全部Pod就绪后自动恢复节点状态。

## 四、Pod 互通类故障
### 4.1 Pod ping同Namespace其他Pod超时/拒绝
1. NetworkPolicy默认拒绝，缺少同ns互通放行策略；
2. 目标Pod CrashLoop无运行进程；
3. Calico路由规则丢失。

### 4.2 Pod能连通Node，无法访问其他Pod
CNI插件未正常初始化，calico-node异常，重启CNI DaemonSet。

### 4.3 Pod访问宿主机端口被拦截
DaemonSet无对应host权限，或节点本地防火墙拦截内部访问。

## 五、DNS 解析故障（CoreDNS）
### 5.1 nslookup 返回 NXDOMAIN 域名不存在
1. Service名称、命名空间拼写错误；
2. Service selector无就绪Pod，EndpointSlice为空；
3. Headless Service缺失 `clusterIP: None`；
4. 自定义hosts配置错误。

### 5.2 域名解析超时，连接53端口失败
1. NetworkPolicy未放行Pod访问kube-system:53 UDP/TCP；
2. CoreDNS Pod全部异常崩溃；
3. 节点防火墙拦截53端口。

### 5.3 内部域名可解析，外部公网域名解析失败
Corefile forward上游DNS服务器不可达，校验机房DNS连通性。

### 5.4 修改自定义hosts后解析结果不变
DNS缓存未过期，等待cache时长或重启coredns清空缓存。

## 六、Service 四层访问故障
### 6. 访问Service返回502 / Connection refused
1. Service selector标签与Pod不匹配，EndpointSlice为空；
2. 所有Pod readiness探针失败，无就绪后端；
3. NetworkPolicy拦截Pod访问Service后端Pod端口。

### 6. Headless Service 无法解析独立有序Pod域名
缺失 `clusterIP: None`，或StatefulSet `serviceName` 与svc名称不一致。

### 6. NodePort 外部无法访问
机房安全组30000-32767端口拦截、节点防火墙封禁、externalTrafficPolicy配置错误。

### 6. LoadBalancer 四层业务拿不到真实客户端IP
`externalTrafficPolicy: Local` 未配置，流量经过SNAT丢失源IP。

### 6. 扩容Pod后流量不分配至新副本
kube-proxy ipvs规则同步延迟，等待同步周期或重启kube-proxy。

## 七、Ingress 七层网关故障
### 7.1 访问域名404 Not Found
1. Ingress host/path与访问地址不匹配；
2. pathType配置错误（Prefix/Exact混用）；
3. 多条Ingress同域名路由冲突。

### 7.2 访问域名502 Bad Gateway
后端Service无就绪Pod、NetworkPolicy拦截Ingress Controller访问业务Pod、容器端口与service port不匹配。

### 7.3 HTTPS提示不安全证书
TLS Secret证书过期、crt与key不匹配、Ingress未绑定spec.tls规则。

### 7.4 HTTP正常访问，HTTPS 443端口打不开
负载均衡/安全组未放行443端口，Ingress未开启TLS配置。

### 7.5 大量429 Too Many Requests
Ingress限流注解`limit-rps`阈值设置过小，调大限流数值或优化前端请求频率。

### 7.6 Ingress灰度权重分流不生效
canary注解缺失、同域名多条Ingress资源冲突，清理多余Ingress。

## 八、NetworkPolicy 网络拦截故障
### 8.1 同Namespace Pod互相访问超时阻断
部署default-deny-all-ingress，但缺少`allow-same-namespace`放行策略。

### 8.2 FAT环境Pod可以连通PROD数据库
未部署出站IPBlock拦截策略，未阻断10.246.0.0/16生产Pod网段。

### 8.3 所有Pod域名解析失败
NetworkPolicy未放行kube-system coredns 53 UDP/TCP端口。

### 8.4 Ingress网关无法转发流量至业务Pod
未添加Ingress Controller Pod访问业务命名空间的白名单Ingress策略。

### 8.5 Pod无法拉取Harbor镜像
Egress策略未放行镜像仓库IP与443端口。

## 九、分环境故障应急处置规范
### DEV本地
直接删除重建Pod/负载，无备份、无审批流程，快速调试。
### FAT测试
故障优先回滚资源；网络策略可临时删除调试，每日自动清空环境兜底。
### UAT预生产
故障先导出当前网络资源yaml备份，再执行暂停/回滚操作；故障复现用于生产预案验证。
### PROD生产（强约束）
1. 网络故障第一时间阻断流量：暂停滚动更新、临时关闭Ingress路由；
2. 优先回滚上一稳定网络配置，禁止随意删除PVC/中间件类资源；
3. 跨环境访问、Policy、LB变更操作双人复核；
4. 重大网络故障前执行etcd快照备份；
5. 故障复盘输出根因，优化NetworkPolicy/发布规范。

## 十、网络排错万能命令合集
```bash
# 1. 查看全集群网络组件状态
kubectl get ds,deploy -n kube-system -l app in (calico,coredns,nginx-ingress-controller)

# 2. 查看Pod完整调度、网络、探针事件
kubectl describe pod ${pod-name} -n ${ns}

# 3. 连通性测试（跨ns Service域名）
kubectl exec -it test-pod -n fat -- curl mysql.prod.svc.cluster.local:3306

# 4. DNS解析校验
kubectl exec -it test-pod -n prod -- nslookup order-svc.prod.svc.cluster.local

# 5. 查看Calico节点路由与BGP状态
kubectl exec -n kube-system ds/calico-node -- calicoctl node status

# 6. 查看Ingress七层访问日志（5xx/4xx定位）
kubectl logs -n kube-system ds/nginx-ingress-controller -f

# 7. 查看Service后端就绪Pod列表
kubectl get endpointslices -n prod

# 8. 批量查看所有网络策略
kubectl get networkpolicy --all-namespaces

# 9. 临时放行所有网络策略（FAT调试应急）
kubectl delete networkpolicy --all -n fat
```

## 十一、关联文档
1. 网络底层底座：01~07 网络管理全套规范
2. 工作负载基础排错：`02-workload-management/10-workload-troubleshooting.md` Pod通用故障
3. 集群全局故障：集群运维故障汇总文档
4. 备份兜底：`etcd-backup.md` 网络资源变更前置快照规范