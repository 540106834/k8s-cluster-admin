# create-project-workspace.md

## K8s 多环境项目工作空间（Namespace）标准化创建手册

## 一、文档定位

本文为企业平台多环境项目命名空间交付SOP，统一规范**DEV开发、UAT测试、PROD生产**三套隔离环境创建流程；包含命名空间标准化标签、资源配额、默认ServiceAccount、镜像拉取密钥、网络策略基线、环境隔离规范，是业务项目上线前置必备操作。  
前置依赖：  
build-kubernetes-cluster.md｜集群基础就绪  
build-harbor-registry.md｜私有镜像仓库机器人账号就绪  
build-storage-platform.md｜集群StorageClass就绪  
下游关联：enable-private-image-access.md、configure-project-resource-policy.md、validate-project-environment.md  

## 二、企业多环境标准规范设计

### 2.1 环境分层定义

企业统一三套隔离运行环境，环境之间完全网络、资源、权限隔离，禁止跨环境直接访问：

1. `dev`：开发环境，研发日常调试、自测，资源配额宽松，允许重启/调试
2. `uat`：验收测试环境，模拟生产配置，供测试、产品验收，禁止随意删改实例
3. `prod`：生产环境，高可用、严格资源限制、网络零信任、操作审计、禁止随意变更

### 2.2 命名空间命名标准

格式：`{环境标识}-{业务项目名}`
示例：

- dev-user-api  用户服务开发环境
- uat-user-api  用户服务测试验收环境
- prod-user-api  用户服务生产环境

### 2.3 统一标准化标签（所有命名空间强制添加）

用于资源筛选、监控大盘区分、网络策略、RBAC权限隔离

```yaml
labels:
  env: dev / uat / prod
  project: user-api
  department: business-group # 所属业务部门
  owner: dev-team # 负责人团队
```

### 2.4 环境隔离约束

1. 网络隔离：默认NetworkPolicy全局阻断跨命名空间流量，仅显式放行指定依赖服务
2. 镜像隔离：DEV使用开发镜像仓库，PROD仅允许拉取稳定发布镜像
3. 权限隔离：开发人员仅拥有dev/uat读写权限，prod仅运维管理员操作
4. 资源隔离：三套环境独立ResourceQuota，互不抢占集群资源
5. 存储隔离：PVC按命名空间目录分层，禁止跨环境挂载存储卷

## 三、前置准备清单（创建命名空间前确认）

1. 项目基础信息：项目名称、所属部门、负责人、环境类型(dev/uat/prod)
2. Harbor机器人账号：对应环境只读拉取账号（dev机器人、prod机器人分离）
3. 集群全局基线资源模板：LimitRange、ResourceQuota、默认拒绝NetworkPolicy
4. 集群存储、监控、日志平台全部就绪
5. 运维管理员具备cluster-admin集群超级权限

## 四、步骤1：创建标准Namespace基础资源

### 4.1 namespace.yaml 标准模板

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev-user-api
  labels:
    env: dev
    project: user-api
    department: business-group
    owner: dev-team
```

### 4.2 执行创建并校验

```bash
# 创建命名空间
kubectl apply -f namespace.yaml
# 校验标签与状态
kubectl get ns dev-user-api --show-labels
# 查看命名空间详情
kubectl describe ns dev-user-api
```

## 五、步骤2：注入全局基线资源（命名空间初始化核心）

创建命名空间后，批量注入该环境强制基线资源，实现环境自动管控：

1. LimitRange：容器默认CPU/内存限制，防止无限制占用节点资源
2. ResourceQuota：命名空间总资源上限，限制Pod/Deployment/PVC最大数量
3. 基础NetworkPolicy：默认拒绝所有入出站流量，构建零信任基线
4. default ServiceAccount：绑定镜像拉取密钥，业务Pod无需单独配置imagePullSecrets

### 5.1 LimitRange 容器默认资源模板

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-container-limit
  namespace: dev-user-api
spec:
  limits:
  - default: # 未配置limits自动填充
      cpu: "500m"
      memory: "512Mi"
    defaultRequest: # 未配置requests自动填充
      cpu: "100m"
      memory: "128Mi"
    max: # 单容器资源上限，禁止超配
      cpu: "500m"
      memory: "1Gi"
    type: Container
```

### 5.2 ResourceQuota 命名空间总资源配额模板

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-resource-quota
  namespace: dev-user-api
spec:
  hard:
    # 计算资源总配额
    requests.cpu: "2"
    requests.memory: "4Gi"
    limits.cpu: "2"
    limits.memory: "4Gi"
    # 资源数量配额
    pods: 50
    persistentvolumeclaims: 50
    services: 30
    deployments.apps: 40
    statefulsets.apps: 10
```

### 5.3 基线默认拒绝NetworkPolicy（零信任基础）

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dev-user-api
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

作用：无任何放行规则，命名空间内所有Pod默认无法收发任何流量，后续按需添加放行策略。

### 5.4 批量注入基线资源脚本

将上述资源保存为基线模板，一键批量创建：

```bash
# 批量创建limitrange、quota、默认网络策略
kubectl apply -f ./ns-baseline/ -n dev-user-api
# 校验资源全部创建成功
kubectl get limitrange,resourcequota,networkpolicy -n dev-user-api
```

## 六、步骤3：配置私有镜像仓库拉取权限（关联 enable-private-image-access.md）

1. 在新建命名空间创建`imagePullSecret`，存储Harbor机器人账号密码
2. 修改命名空间默认ServiceAccount，自动绑定imagePullSecrets
3. 业务Deployment无需单独配置镜像拉取密钥，自动生效
完整操作详见 `enable-private-image-access.md`

## 七、步骤4：环境差异化配置（DEV/UAT/PROD区分）

### 7.1 DEV开发环境

1. ResourceQuota资源配额宽松，允许更多Pod调试
2. NetworkPolicy放开命名空间内Pod互通，仅阻断外网未授权访问
3. 镜像允许拉取dev临时构建镜像，无镜像版本强制校验
4. 开发人员RBAC具备完整读写、删除Pod权限

### 7.2 UAT验收测试环境

1. 资源配额中等，禁止超大资源占用
2. 网络策略严格，仅允许依赖服务互通，禁止直接访问生产环境
3. 镜像仅允许测试稳定版本，禁止临时开发镜像
4. 测试人员仅允许查看、重启Pod，禁止删除核心服务

### 7.3 PROD生产环境（最严格基线）

1. ResourceQuota严格管控，预留20%资源缓冲，防止资源耗尽集群雪崩
2. 零信任网络策略，最小权限放行，禁止跨环境主动访问
3. 镜像仅允许生产稳定版本，禁止开发测试镜像
4. 仅运维管理员具备操作权限，开发人员仅只读查看
5. 强制高可用部署，副本数≥2，禁止单实例Deployment

## 八、步骤5：命名空间交付前置校验（复用validate-project-environment.md）

标准化校验项，全部通过才算工作空间创建完成：

1. 命名空间标签完整规范，env/project/department标签齐全
2. LimitRange、ResourceQuota、默认拒绝NetworkPolicy全部就绪
3. imagePullSecret存在，默认ServiceAccount已绑定镜像拉取密钥
4. 资源配额无超限，节点资源充足承载该项目业务
5. 网络基线策略生效，默认阻断全部未授权流量
6. 监控、日志自动采集该命名空间资源与容器日志

## 九、多项目/多环境批量自动化创建方案

企业平台建议基于GitOps/平台管理API自动化创建，标准化模板统一下发：

1. 维护三套环境基线YAML模板（dev/uat/prod）
2. 平台前端录入项目信息，自动渲染namespace、quota、limitrange、policy
3. 自动创建Harbor对应项目机器人账号，同步生成imagePullSecret
4. 自动交付开发人员RBAC kubeconfig权限文件

## 十、高频故障与处理方案

### 1. 创建Pod提示资源不足，调度失败

根因：ResourceQuota总配额耗尽，达到命名空间资源上限
处理：评估业务容量，调高对应命名空间ResourceQuota配额

### 2. Pod拉取镜像返回401鉴权失败

根因：imagePullSecret未创建、默认ServiceAccount未绑定密钥
处理：参照enable-private-image-access.md重新配置镜像拉取密钥

### 3. Pod启动无任何网络连通，无法ping网关/访问Service

根因：基线default-deny-all NetworkPolicy全局阻断流量
处理：按需添加业务放行NetworkPolicy规则

### 4. 容器未配置resources，启动被LimitRange拦截

根因：LimitRange设置max限制，容器未自动填充默认requests/limits
处理：LimitRange配置default、defaultRequest自动填充资源，或业务补充resources配置

### 5. 开发人员无法操作命名空间资源，返回403无权限

根因：未配置对应环境RBAC权限，参照deliver-developer-access.md交付权限

## 十一、生产落地运维规范

1. 所有业务项目必须按`env-project`规范创建独立命名空间，禁止多业务混用一个ns
2. 每个命名空间强制注入全套基线资源：LimitRange、ResourceQuota、默认拒绝NetworkPolicy
3. 三套环境严格隔离，禁止DEV直接访问PROD数据库、中间件
4. 生产环境命名空间操作权限最小化，开发人员禁止拥有prod写权限
5. 项目下线废弃时，完整删除Namespace资源，同步清理PV、Secret、配额规则
6. 新建命名空间完成后执行全套项目环境验收（validate-project-environment.md）
7. 定期巡检所有命名空间标签、基线资源完整性，修复缺失基线的命名空间

## 十二、关联文档索引

enable-private-image-access.md 命名空间镜像拉取密钥、ServiceAccount配置
configure-project-resource-policy.md 资源配额、网络策略精细化配置
deliver-developer-access.md 开发人员RBAC权限、kubeconfig交付
validate-project-environment.md 项目命名空间交付验收标准
build-harbor-registry.md Harbor机器人账号创建规范
build-storage-platform.md PVC存储资源配额管控


```