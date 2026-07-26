# configure-project-resource-policy.md
# 项目Namespace 资源配额、容器限制、网络策略综合治理手册
## 一、文档定位
本文面向企业多环境项目（DEV/UAT/PROD），标准化配置三类资源管控策略：**ResourceQuota命名空间总资源配额、LimitRange容器默认资源上下限、NetworkPolicy东西向流量隔离基线**；实现资源防雪崩、业务网络零信任隔离，是项目Namespace创建后必配置基线策略。
前置依赖：
create-project-workspace.md｜项目命名空间创建流程
enable-private-image-access.md｜镜像拉取权限配置
deliver-developer-access.md｜开发人员RBAC权限
下游关联：validate-project-environment.md｜项目环境验收标准

## 二、三大资源策略作用与边界说明
### 1. ResourceQuota 命名空间全局总配额
管控整个Namespace所有Pod/存储/Service/控制器总资源上限，防止单项目耗尽集群全部节点资源引发全局雪崩。
管控维度：
1. 计算资源总水位：CPU、内存 requests/limits 总和
2. 资源实例总数：Pod、PVC、Deployment、StatefulSet、Service、ConfigMap、Secret
3. 存储总容量：所有PVC占用存储总量

### 2. LimitRange 容器资源默认约束
针对单个Pod/容器设置资源默认值、最大最小限制，避免业务不写resources导致调度异常、节点内存OOM。
管控维度：
1. 未声明requests/limits的容器自动填充默认值
2. 单容器CPU/内存硬上限，禁止超规格创建Pod抢占节点资源
3. 最小资源规格，杜绝创建0核0内存无效容器

### 3. NetworkPolicy 零信任网络基线
默认拒绝所有东西向流量，仅显式放行业务依赖通信，防止横向渗透、未授权Pod互相访问。
管控维度：
1. Ingress：入站访问白名单
2. Egress：出站访问白名单
3. 支持Pod标签、命名空间、外网CIDR、端口多维过滤

### 三、DEV / UAT / PROD 三套环境策略差异化标准
| 策略 | DEV开发环境 | UAT测试环境 | PROD生产环境 |
|------|------------|------------|-------------|
| ResourceQuota | 配额宽松，预留调试资源 | 中等配额，限制临时大量Pod | 严格配额，预留15%缓冲，硬限制上限 |
| LimitRange | 上限宽松，方便调试大容器 | 中等上限 | 严格单容器CPU/内存上限，禁止超大实例 |
| NetworkPolicy | 默认阻断，但放行同命名空间Pod互通 | 默认阻断，仅放行依赖服务 | 全局默认拒绝，最小权限放行，无默认互通 |

## 四、第一部分：ResourceQuota 配置（分环境模板）
### 4.1 DEV环境模板（dev-demo）
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota-dev
  namespace: dev-demo
spec:
  hard:
    # 计算资源总配额
    requests.cpu: "32"
    requests.memory: "32Gi"
    limits.cpu: "64"
    limits.memory: "64Gi"
    # 实例数量配额
    pods: 200
    deployments.apps: 80
    statefulsets.apps: 20
    services: 50
    persistentvolumeclaims: 80
    configmaps: 200
    secrets: 100
    # 存储总容量
    requests.storage: "500Gi"
```

### 4.2 UAT环境模板（uat-demo）
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota-uat
  namespace: uat-demo
spec:
  hard:
    requests.cpu: "16"
    requests.memory: "16Gi"
    limits.cpu: "32"
    limits.memory: "32Gi"
    pods: 100
    deployments.apps: 40
    statefulsets.apps: 10
    services: 30
    persistentvolumeclaims: 40
    requests.storage: "300Gi"
```

### 4.3 PROD生产环境模板（prod-demo，严格限制）
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota-prod
  namespace: prod-demo
spec:
  hard:
    requests.cpu: "8"
    requests.memory: "8Gi"
    limits.cpu: "16"
    limits.memory: "16Gi"
    pods: 50
    deployments.apps: 20
    statefulsets.apps: 5
    services: 20
    persistentvolumeclaims: 20
    requests.storage: "200Gi"
```

### 4.4 配额生效校验
```bash
# 应用配额资源
kubectl apply -f quota.yaml -n dev-demo
# 查看配额使用情况
kubectl describe resourcequota ns-quota-dev -n dev-demo
# 配额耗尽调度失败测试：创建超配额Pod观察事件提示
kubectl get events -n dev-demo --field-selector reason=FailedCreate
```

## 五、第二部分：LimitRange 容器资源约束（全环境通用基础模板）
### 5.1 通用LimitRange YAML
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: container-limit-base
  namespace: dev-demo
spec:
  limits:
  - type: Container
    # 容器未配置requests自动填充默认值
    default:
      cpu: "200m"
      memory: "256Mi"
    # 容器未配置limits自动填充上限
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    # 单容器硬上限（PROD可下调为cpu:2,memory:2Gi）
    max:
      cpu: "4"
      memory: "4Gi"
    # 最小资源规格，禁止0资源Pod
    min:
      cpu: "10m"
      memory: "16Mi"
```
### 5.2 特殊调整说明
1. PROD环境 `max.cpu=2` `max.memory=2Gi`，禁止单容器占用大量节点资源
2. 大数据中间件（ES、Redis）单独添加自定义LimitRange放开上限

### 5.3 校验生效
创建不携带resources的Deployment，describe Pod查看自动填充的cpu/memory参数。

## 六、第三部分：NetworkPolicy 网络隔离基线（零信任核心）
### 6.1 基线策略1：全局默认拒绝所有流量（全环境必配）
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod-demo
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```
作用：无任何放行规则时，所有Pod入站、出站流量全部阻断。

### 6.2 DEV环境配套放行：同命名空间Pod互通
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-ns
  namespace: dev-demo
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
```

### 6.3 UAT/PROD标准业务放行示例
场景：命名空间内api服务，仅允许本ns frontend标签Pod访问8080端口，出站允许访问集群Service网段与外网数据库。
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-access
  namespace: prod-demo
spec:
  podSelector:
    matchLabels:
      app: api-server
  policyTypes: [Ingress,Egress]
  # 入站放行：同ns frontend应用访问
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  # 出站放行：集群Service网段 + 外部数据库CIDR
  egress:
  - to:
    - ipBlock:
        cidr: 10.96.0.0/16
    - ipBlock:
        cidr: 192.168.10.0/24
    ports:
    - protocol: TCP
      port: 3306
    - protocol: TCP
      port: 8080
```

### 6.4 出站DNS放行（所有环境通用，防止域名解析失败）
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: prod-demo
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - ipBlock:
        cidr: "10.96.0.10/32" # 集群CoreDNS固定IP
    ports:
    - protocol: UDP
      port: 53
```

## 七、批量落地操作流程
1. 切换目标项目命名空间
2. 依次应用 LimitRange → ResourceQuota → 基线NetworkPolicy
```bash
# 批量应用目录下所有策略模板
kubectl apply -f ./resource-policy/ -n dev-demo
```
3. 分层校验三类策略资源正常创建
```bash
kubectl get limitrange,resourcequota,networkpolicy -n dev-demo
```
4. 模拟测试：超配额创建Pod、无resources创建容器、跨Pod访问验证阻断/放行效果

## 八、资源策略日常运维操作
### 8.1 扩容命名空间资源配额
编辑ResourceQuota，上调cpu/memory/pods硬限制，无需重启任何组件即时生效。
```bash
kubectl edit resourcequota ns-quota-prod -n prod-demo
```

### 8.2 新增业务放行网络策略
新增独立NetworkPolicy YAML，按需添加from/to/ports规则，不修改全局default-deny-all。

### 8.3 临时放开限制（业务迁移窗口）
临时注释NetworkPolicy规则，窗口结束后恢复默认拒绝基线，留存操作记录。

## 九、高频故障与根因处理
### 故障1：创建Deployment提示配额不足，FailedCreate
根因：ResourceQuota资源已达hard上限
处理：评估业务容量，上调Quota；清理废弃闲置Pod/PVC释放资源

### 故障2：创建Pod报错 `must specify cpu and memory`
根因：LimitRange配置min资源，Pod未自动填充默认requests
修复：检查LimitRange defaultRequest配置；业务yaml补充resources

### 故障3：Pod无法解析域名，nslookup失败
根因：缺少DNS出站放行NetworkPolicy，UDP53被阻断
修复：应用allow-dns-egress策略

### 故障4：同命名空间Pod互相ping不通
根因：仅部署default-deny-all，未添加同命名空间放行规则（DEV环境高频）

### 故障5：生产Pod占用超大内存，节点OOM
根因：LimitRange max内存上限配置过大，未限制单容器资源
修复：下调PROD环境max内存参数，重启业务Pod生效

### 故障6：业务能访问外网，但无法访问集群内部Service
根因：Egress规则未添加Service网段10.96.0.0/16放行

## 十、生产落地标准化规范
1. 所有项目Namespace创建完成后必须同步部署LimitRange、ResourceQuota、默认拒绝NetworkPolicy三大基线；
2. 三套环境配额严格区分，生产环境资源限制最严格，预留15%资源缓冲；
3. 网络基线默认全局拒绝，禁止全通配放行0.0.0.0/0，仅按需添加业务白名单；
4. 禁止业务Pod无resources配置，LimitRange自动填充兜底资源防止调度异常；
5. 中间件大数据业务单独定制LimitRange，不使用通用模板上限；
6. 每季度巡检所有命名空间资源配额水位，提前扩容避免业务调度失败；
7. 项目交付验收必须校验三类策略完整生效（纳入validate-project-environment.md）。

## 十一、关联文档索引
create-project-workspace.md 项目Namespace初始化基线资源注入流程
validate-project-environment.md 项目资源配额、网络策略验收标准
05-network-security.md NetworkPolicy零信任安全底层原理
03-network-data-path.md Pod流量转发与Policy拦截链路
06-network-debug.md 配额调度失败、网络策略阻断故障排查