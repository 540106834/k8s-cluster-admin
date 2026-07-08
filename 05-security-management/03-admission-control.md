# 03-admission-control.md
## 一、文档基础信息
- 归属目录：`05-security-management/`
- 前置阅读：`00-README.md`、`01-authentication.md`、`02-authorization.md`
- 集群基准：Kubernetes v1.32.13、内置准入控制器、PodSecurity标准、自定义准入Webhook、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：准入控制完整链路、内置准入控制器链、PSS三级安全标准、PodSecurityContext/容器安全上下文、镜像准入校验、资源配额准入、自定义准入Webhook部署、违规拦截故障排查

## 二、准入控制底层原理
### 2.1 定位
Admission Control（准入控制）执行在**认证、授权全部通过之后，资源持久化写入etcd之前**，是集群资源创建/更新的最后一道拦截关卡。
分为两类控制器：
1. **Mutating（变更型）**：自动修改资源配置（自动注入ServiceAccount、默认资源限制、自动挂载Secret等）；
2. **Validating（校验型）**：仅校验规则，违规直接拒绝创建/更新，返回403。

### 2.2 完整API请求处理链路
客户端请求 → 认证(Authentication) → 授权(RBAC) → Mutating准入 → 重新校验认证授权 → Validating准入 → 写入etcd

### 2.3 集群必开启内置准入控制器（apiserver配置）
```
--enable-admission-plugins=NamespaceLifecycle,LimitRanger,ResourceQuota,PodSecurity,ValidatingAdmissionWebhook,MutatingAdmissionWebhook
```
关键插件作用：
1. NamespaceLifecycle：禁止删除存在资源的命名空间；
2. LimitRanger：强制Pod设置CPU/内存requests/limits；
3. ResourceQuota：校验命名空间存储/资源配额；
4. PodSecurity：全局落地PodSecurity Standards三级安全基线；
5. Validating/MutatingAdmissionWebhook：支持自定义外部准入校验。

## 三、PodSecurity Standards（PSS）三级安全标准核心规范
### 3.1 三级标准对比（全环境强制落地）
| 等级 | 适用环境 | 核心限制规则 |
|------|----------|--------------|
| Privileged | DEV本地仅 | 无任何容器安全限制，允许特权容器、root运行、hostPath/hostNetwork |
| Baseline | FAT测试 | 屏蔽高危特权能力，允许基础业务容器，禁止特权容器、hostPID/hostIPC |
| Restricted | UAT/PROD强制 | 最严格安全基线，非root运行、禁止权限提升、强制只读根文件系统、限制Linux Capabilities |

### 3.2 命名空间绑定PSS模式（PodSecurity配置示例）
通过Namespace标签全局生效，无需每个Pod重复配置：
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    # 运行模式
    pod-security.kubernetes.io/enforce: restricted
    # 违规警告（日志/审计）
    pod-security.kubernetes.io/warn: restricted
    # 审计日志记录违规操作
    pod-security.kubernetes.io/audit: restricted
```
- enforce：违规Pod直接拒绝创建；
- warn/audit：仅记录日志不拦截，用于FAT过渡调试。

## 四、PodSecurityContext & ContainerSecurityContext 标准模板（Restricted生产规范）
### 4.1 全局Pod安全上下文（Pod级）
```yaml
securityContext:
  runAsNonRoot: true          # 禁止root用户运行容器
  runAsUser: 1000             # 固定普通运行UID
  runAsGroup: 3000
  fsGroup: 3000               # 持久存储目录权限统一
  seccompProfile:
    type: RuntimeDefault      # 启用默认seccomp系统调用过滤
```

### 4.2 容器安全上下文（容器级，生产强制）
```yaml
containers:
- name: app
  image: xxx
  securityContext:
    allowPrivilegeEscalation: false # 禁止权限提升（关键红线）
    capabilities:
      drop: ["ALL"]                 # 删除所有Linux特权能力
    readOnlyRootFilesystem: true    # 根目录只读，临时数据仅用emptyDir
```

### 4.2 禁止配置高危项（生产拦截）
1. privileged: true 特权容器；
2. hostNetwork/hostPID/hostIPC: true 共享宿主机命名空间；
3. allowPrivilegeEscalation: true；
4. 未drop全部Linux capabilities；
5. runAsNonRoot: false 以root运行业务容器。

## 五、内置准入校验规则详解
### 5.1 LimitRanger 资源准入强制校验
拦截未配置CPU/内存 requests/limits 的Pod，避免节点资源抢占。
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: pod-limit-range
  namespace: prod
spec:
  limits:
  - type: Container
    default:
      cpu: 200m
      memory: 256Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    max:
      cpu: 4000m
      memory: 4Gi
```

### 5.2 ResourceQuota 配额准入
PVC存储、Pod数量、CPU内存总配额超限直接拒绝创建，参考`02-workload-management/07-resource-management.md`。

### 5.3 镜像准入策略（ValidatingWebhook实现）
自定义准入Webhook校验镜像规则：
1. 仅允许内网Harbor仓库镜像，拦截公网docker.io镜像；
2. 拦截高危漏洞镜像（Harbor扫描高危漏洞）；
3. 禁止latest浮动标签，必须使用固定版本Tag。
拦截示例：创建Pod使用`nginx:latest`直接返回拒绝信息。

## 六、自定义准入Webhook完整落地规范
### 6.1 两种Webhook区分
1. MutatingWebhookConfiguration：自动修正资源（自动注入安全上下文、补充资源限制）；
2. ValidatingWebhookConfiguration：纯校验，违规直接拒绝。

### 6.2 Webhook 核心配置示例（镜像校验校验型）
```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-policy-webhook
webhooks:
- name: image.check.example.com
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE","UPDATE"]
    resources: ["pods"]
    scope: Namespaced
  clientConfig:
    service:
      name: image-policy-webhook
      namespace: kube-system
      path: /validate/pod
    caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==
  admissionReviewVersions: ["v1"]
  sideEffects: None
  timeoutSeconds: 5
  failurePolicy: Fail # Webhook服务不可用则拒绝所有Pod创建（生产强制）
```
关键参数说明：
- failurePolicy: Fail：Webhook异常时阻断资源创建，防止绕过校验；
- sideEffects: None：Webhook无副作用，仅纯校验；
- timeoutSeconds: 5：超时快速失败，避免API阻塞。

### 6.3 Webhook离线部署要求
1. Webhook镜像上传内网Harbor；
2. CA证书离线自签，写入caBundle；
3. 网络策略放行kube-system访问Webhook服务端口。

## 七、DEV/FAT/UAT/PROD 分层准入基线
### DEV本地
1. PSS模式：Privileged，无严格安全限制；
2. LimitRanger可选，允许无资源限制Pod；
3. 不部署镜像准入Webhook，可拉取公网镜像。

### FAT测试
1. PSS模式：Baseline，拦截特权容器、host共享命名空间；
2. 强制LimitRanger，必须配置资源上下限；
3. 镜像准入仅告警，不拦截，允许临时公网镜像调试。

### UAT预生产
1. PSS enforce=restricted，违规Pod直接拒绝；
2. 完整安全上下文强制校验（runAsNonRoot、只读根、删所有cap）；
3. 镜像准入Webhook强制拦截公网镜像、latest标签；
4. failurePolicy=Fail，Webhook宕机阻断Pod创建。

### PROD生产（强制红线）
1. 所有Namespace enforce: restricted，不允许降级Baseline/Privileged；
2. 全部业务容器完整配置安全上下文，准入自动校验拦截缺失配置；
3. 镜像仅允许内网Harbor，禁止latest标签，高危漏洞镜像拦截；
4. LimitRanger+ResourceQuota双准入，无资源限制Pod直接拒绝；
5. 自定义Webhook故障策略Fail，杜绝绕过安全校验；
6. 禁止任何特权容器、hostNetwork/hostPID业务Pod。

## 八、准入控制标准运维命令
```bash
# 查看集群准入插件开启列表
kubectl describe apiserver -n kube-system | grep admission-plugins

# 查看Webhook配置
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations

# 查看命名空间PSS标签
kubectl get ns --show-labels | grep pod-security

# 模拟创建违规Pod测试准入拦截
kubectl run test-priv --image=nginx --privileged -n prod

# 查看准入拒绝事件日志
kubectl get events -n prod --sort-by=.metadata.creationTimestamp
```

## 九、高频准入故障排查
### 1. 创建Pod报错：violates PodSecurity "restricted" policy
缺少完整securityContext、开启特权容器、root运行、保留Linux capabilities，补全生产标准安全上下文。

### 2. 创建Pod报错：must set cpu/memory limits
命名空间LimitRanger准入开启，Pod未配置resources limits，补充资源限制。

### 3. Webhook unavailable, failure policy fail
准入Webhook服务Pod崩溃、网络策略拦截apiserver访问Webhook、证书caBundle不匹配；重启Webhook并校验证书。

### 4. 镜像准入拒绝：only harbor internal images allowed
镜像仓库为公网docker.io，替换为内网Harbor镜像地址。

### 5. Pod使用latest标签被Webhook拦截
修改镜像Tag为固定版本号，禁止浮动latest标签。

### 6. 准入Mutating插件未自动注入配置
Webhook配置缺失匹配规则、apiserver未重启加载准入配置。

## 十、生产安全最佳实践
1. UAT/PROD全局启用PSS restricted模式，从源头拦截高权限容器；
2. 所有命名空间部署LimitRanger+ResourceQuota双层资源准入；
3. 镜像准入Webhook强制限制内网仓库、固定版本Tag，阻断漏洞镜像；
4. Webhook统一配置failurePolicy: Fail，防止安全校验旁路；
5. 区分Mutating自动补全配置、Validating拦截违规资源；
6. 准入拒绝事件接入告警，及时发现违规部署行为；
7. 集群升级前备份Webhook、LimitRange、Namespace PSS标签配置。

## 十一、关联文档
1. 认证授权：`01-authentication.md` / `02-authorization.md` 准入前置校验链路
2. 工作负载安全：`02-workload-management/` Pod安全上下文完整规范
3. 密钥管理：`04-secret-management.md` 准入拦截明文Secret硬编码资源
4. 网络安全：`05-network-security.md` 准入拦截开放全部端口的高危Pod
5. 审计日志：`06-audit-log.md` 准入拦截、违规Pod创建全量审计记录
6. 安全加固：`07-security-best-practices.md` PSS月度安全巡检清单