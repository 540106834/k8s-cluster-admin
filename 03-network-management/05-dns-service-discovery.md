# 05-dns-service-discovery.md
## 一、文档基础信息
- 归属目录：`03-network-management/`
- 前置阅读：`00-README.md`、`01-kubernetes-network-model.md`、`03-service-management.md`
- 集群基准：Kubernetes v1.32.13、Calico v3.30.4、CoreDNS、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：CoreDNS架构与部署、集群标准DNS域名规则、自定义外部域名、缓存调优、上游DNS转发、分环境配置、解析故障排查

## 二、CoreDNS 底层理论
### 2.1 定位
CoreDNS 是K8s集群内置DNS服务发现组件，部署于`kube-system`，为Pod提供集群内部Service、Headless、Pod域名解析，同时支持转发外部域名至机房上游DNS。
所有Pod默认DNS配置自动注入`nameserver: coredns.kube-system.svc.cluster.local`。

### 2.2 组件架构
1. CoreDNS Deployment：多副本高可用，提供DNS UDP/TCP 53端口；
2. Corefile：配置文件（ConfigMap存储），控制解析规则、缓存、上游转发、Pod域名支持；
3. kube-proxy：将dns服务ClusterIP转发至CoreDNS Pod；
4. Service `kube-dns` 兼容旧版名称，底层指向coredns服务。

### 2.3 解析优先级
1. 集群内部域名（*.svc.cluster.local）优先本地解析；
2. 非集群域名转发至上游机房DNS服务器；
3. 自定义静态域名hosts直接匹配返回，不转发上游。

## 三、集群标准DNS域名解析规则（强制统一格式）
### 3.1 同命名空间访问 Service
```
service-name
# 示例：order-svc
```

### 3.2 跨命名空间标准完整域名（推荐，无环境耦合）
```
service-name.ns.svc.cluster.local
# 示例：mysql.prod.svc.cluster.local
```

### 3.3 StatefulSet Headless 固定Pod域名
```
pod-name.sts-name.ns.svc.cluster.local
# 示例：mysql-0.mysql-headless.prod.svc.cluster.local
```

### 3.4 Pod直连域名（动态PodIP映射，极少使用）
```
<pod-ip-with-dots-replace-dash>.<ns>.pod.cluster.local
# 示例：10-246-1-10.prod.pod.cluster.local
```

### 3.5 域名解析范围约束
- FAT/UAT/PROD Pod网段隔离，但DNS全局可解析所有环境Service域名；
- 多环境网络隔离依靠NetworkPolicy阻断TCP/UDP业务端口，而非DNS拦截。

## 四、标准CoreDNS Corefile配置模板（PROD）
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        # 集群K8s资源解析
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods verified
           fallthrough in-addr.arpa ip6.arpa
           ttl 5
        }
        # 静态自定义域名（内部第三方服务）
        hosts /etc/coredns/custom-hosts {
           fallthrough
        }
        # 缓存，生产延长缓存减少查询压力
        cache 30
        # 转发机房上游DNS
        forward . 192.168.1.1 192.168.1.2 {
          max_concurrent 1000
        }
        # 健康检查、监控、日志
        health
        prometheus :9153
        log
        errors
        reload 10s
    }
```

### 关键配置说明
1. `cache 30`：DNS记录缓存30秒，减少重复查询；
2. `kubernetes pods verified`：开启Pod域名解析校验；
3. `hosts`：自定义静态内部域名，无需外部DNS；
4. `forward`：外部域名转发企业内网DNS；
5. `reload`：配置变更自动重载，无需重启Pod。

### 自定义静态域名 hosts 示例
```yaml
# 新增custom-hosts文件挂载
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom-hosts
  namespace: kube-system
data:
  custom-hosts: |
    192.168.10.10  harbor.jinshaoyong.com
    192.168.10.11  gitlab.jinshaoyong.com
```
挂载至coredns容器 `/etc/coredns/custom-hosts`。

## 五、分环境CoreDNS标准化配置
| 环境 | cache缓存时长 | 副本数 | 日志级别 | 自定义域名 |
|------|---------------|--------|----------|------------|
| DEV本地 | 5s | 1 | 简化日志 | 本地hosts不依赖集群DNS |
| FAT测试 | 10s | 2 | 完整日志便于调试 | 仅测试内部静态域名 |
| UAT预生产 | 30s | 3 | 标准生产日志 | 对齐生产自定义域名 |
| PROD生产 | 30s | ≥3高可用 | 标准日志，开启监控指标 | 完整内网第三方静态域名 |

### 生产强制约束
1. CoreDNS副本≥3，避免单点解析故障；
2. 开启缓存降低查询压力；
3. 配置双上游DNS，防止单一DNS宕机；
4. 保留完整查询日志，用于解析故障溯源；
5. 不使用公共外网DNS，统一内网机房上游DNS。

## 六、CoreDNS 运维标准操作
### 6.1 查看CoreDNS资源
```bash
# 查看coredns deployment与pod
kubectl get deploy,pods -n kube-system -l k8s-app=coredns

# 查看DNS服务
kubectl get svc kube-dns -n kube-system

# 查看Corefile配置
kubectl get cm coredns -n kube-system -o yaml
```

### 6.2 修改DNS配置
1. 编辑ConfigMap更新Corefile/自定义hosts；
2. CoreDNS自动10s重载配置，无需重启；
3. 若未生效，手动滚动重启coredns：
```bash
kubectl rollout restart deploy coredns -n kube-system
```

### 6.3 域名解析测试（排错核心命令）
```bash
# 进入测试Pod内解析同ns服务
kubectl exec -it test-pod -n prod -- nslookup order-svc

# 跨命名空间完整域名解析
kubectl exec -it test-pod -n fat -- nslookup mysql.prod.svc.cluster.local

# 解析Headless StatefulSet Pod域名
kubectl exec -it test-pod -n prod -- dig mysql-0.mysql-headless.prod.svc.cluster.local

# 解析外部自定义静态域名
kubectl exec -it test-pod -n prod -- nslookup harbor.jinshaoyong.com
```

### 6.4 查看DNS查询日志
```bash
kubectl logs -n kube-system deploy/coredns -f
```

## 七、DNS 高频故障排查
### 1. nslookup 解析返回 NXDOMAIN 域名不存在
1. Service名称/命名空间拼写错误；
2. Service selector无就绪Pod，EndpointSlice为空；
3. Headless Service未配置`clusterIP: None`；
4. 自定义hosts域名写入错误。

### 2. 域名解析超时、无法连接53端口
1. NetworkPolicy拦截Pod访问kube-system 53 UDP/TCP；
2. CoreDNS Pod全部CrashLoopBackOff；
3. 节点防火墙拦截53端口。

### 3. 内部域名能解析，外部公网域名失败
上游DNS服务器不可达，检查forward配置内DNS地址连通性。

### 4. 修改自定义hosts后解析不更新
缓存未过期，等待cache时长或重启coredns Pod清空缓存。

### 5. StatefulSet Pod域名无法解析
缺失Headless Service，或sts.spec.serviceName与svc名称不匹配。

### 6. 大量DNS请求延迟高
CoreDNS副本过少、cache缓存时长太短，扩容副本并调大cache参数。

## 八、生产最佳实践
1. PROD环境CoreDNS多副本高可用，杜绝单点；
2. 统一内网上游DNS，禁止转发8.8.8.8等公网DNS；
3. 内部中间件、镜像仓库、Git等固定地址写入自定义hosts，不依赖外部DNS；
4. 开启DNS查询日志，监控NXDOMAIN异常请求；
5. 网络策略放开所有命名空间Pod访问kube-system:53；
6. CoreDNS配置变更前备份ConfigMap，集群升级前执行etcd快照；
7. 区分环境域名仅靠NetworkPolicy做业务端口拦截，DNS全局互通便于调试。

## 九、关联文档
1. 网络模型：`01-kubernetes-network-model.md` Service通信模型
2. 四层服务：`03-service-management.md` Service/Headless域名生成规则
3. 网络隔离：`06-network-policy.md` 放开DNS 53端口访问策略
4. 七层网关：`04-ingress-management.md` 外部业务域名解析配置
5. 网络排错：`08-network-troubleshooting.md` DNS解析超时、NXDOMAIN完整排错SOP