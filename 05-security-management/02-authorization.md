# 02-authorization.md
## 一、文档基础信息
- 归属目录：`05-security-management/`
- 前置阅读：`00-README.md`、`01-authentication.md`
- 集群基准：Kubernetes v1.32.13、OIDC身份体系、离线RBAC资源Git托管、内网Harbor
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：RBAC四层资源模型、Role/ClusterRole/RoleBinding/ClusterRoleBinding完整模板、Node授权、Webhook外部授权、多环境权限分级、运维/开发/测试账号权限隔离、权限巡检与清理、越权故障排查

## 二、授权底层核心理论
### 2.1 授权定位
Authorization（授权）发生在**认证Authentication通过之后**，核心作用：判定已认证用户/ServiceAccount是否拥有对指定资源执行对应操作的权限。
集群默认开启RBAC授权器，禁用ABAC、AlwaysAllow等不安全模式。
判定逻辑四元组：`用户/ServiceAccount + 资源组/资源 + 操作动词 + 命名空间`。

### 2.2 RBAC四大核心资源分层模型
1. **Role**：命名空间级权限，仅作用于单个NS，不能跨命名空间管控资源；
2. **ClusterRole**：集群全局权限，跨所有Namespace，可管控集群级资源（Node、PV、StorageClass、ClusterRole等）；
3. **RoleBinding**：绑定User/ServiceAccount/Group到同命名空间Role；
4. **ClusterRoleBinding**：全局绑定User/Group/ServiceAccount到ClusterRole，全集群生效。

### 2.3 内置系统ClusterRole（生产禁止直接绑定给普通用户）
- `cluster-admin`：全集群万能最高权限，仅紧急运维临时使用，禁止长期绑定；
- `cluster-admin`、`cluster-view`、`cluster-edit`、`admin`、`edit`、`view` 为系统预制角色，业务按需拆解最小权限，不直接复用内置粗粒度角色。

### 2.4 两种绑定作用域对比
| 资源 | 作用范围 | 适用场景 |
|------|----------|----------|
| Role + RoleBinding | 单一Namespace | 开发、测试仅操作自身业务命名空间 |
| ClusterRole + ClusterRoleBinding | 全集群所有NS/集群资源 | 集群运维、CSI、Ingress控制器、备份Operator |

## 三、标准RBAC完整模板示例
### 3.1 命名空间级Role（FAT开发只读权限）
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-viewer
  namespace: fat
  labels:
    env: fat
    permission: read-only
rules:
- apiGroups: ["","apps","batch","networking.k8s.io"]
  resources: ["pods","deployments","statefulsets","services","ingress","jobs"]
  verbs: ["get","list","watch"]
```

### 3.2 RoleBinding 绑定OIDC用户至Role
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-dev-user-view
  namespace: fat
subjects:
- kind: User
  name: oidc:user:zhangsan@example.com # OIDC用户唯一标识
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: app-viewer
  apiGroup: rbac.authorization.k8s.io
```

### 3.3 全局ClusterRole（集群存储运维权限）
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-storage-admin
rules:
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses","volumesnapshots","volumesnapshotclasses"]
  verbs: ["get","list","watch","create","update","delete"]
- apiGroups: [""]
  resources: ["persistentvolumes","persistentvolumeclaims"]
  verbs: ["*"]
```

### 3.4 ClusterRoleBinding 绑定运维组全局权限
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bind-storage-admin-group
subjects:
- kind: Group
  name: oidc:group:storage-ops
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-storage-admin
  apiGroup: rbac.authorization.k8s.io
```

### 3.5 ServiceAccount专用RBAC（备份Operator最小权限）
```yaml
# Role
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: backup-operator-rules
  namespace: prod
rules:
- apiGroups: ["","apps","batch"]
  resources: ["pods","pvc","jobs"]
  verbs: ["get","list","watch","create","delete"]
---
# RoleBinding绑定SA
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-backup-sa
  namespace: prod
subjects:
- kind: ServiceAccount
  name: backup-operator-sa
  namespace: prod
roleRef:
  kind: Role
  name: backup-operator-rules
```

## 四、Node授权机制（Node鉴权器）
### 4.1 作用场景
kubelet节点代理API请求（Pod调度、挂载存储、节点状态上报），Node授权器自动授予kubelet仅操作本机Pod/Volume的权限，无需手动配置RBAC。
### 4.2 配套约束
1. 自动创建 `system:nodes` 组，所有kubelet证书归属该组；
2. 禁止手动修改Node内置权限规则；
3. 节点异常越权操作通过审计日志告警。

## 五、Webhook 外部授权（企业自定义权限校验）
### 5.1 适用场景
企业内部权限平台、自研权限系统，在RBAC前二次拦截API请求，实现自定义权限逻辑（数据权限、工单审批校验）。
### 5.2 apiserver启动参数
```
--authorization-webhook-config-file=/etc/kubernetes/ssl/auth-webhook.yaml
--authorization-mode=RBAC,Webhook
```
### 5.3 执行顺序
Webhook授权优先校验 → 校验通过进入RBAC授权，任一拒绝直接返回403 Forbidden。

## 六、DEV/FAT/UAT/PROD 四层环境权限分级标准
### DEV本地
1. 内置`cluster-admin`权限无限制，用于本地调试；
2. 不做精细RBAC拆分，无需权限工单审批。

### FAT测试（开发人员权限）
1. 开发仅拥有自身业务NS只读+更新权限，禁止删除PVC/StatefulSet；
2. 禁止绑定任何ClusterRole全局权限；
3. 无集群节点、存储类操作权限；
4. 不允许跨Namespace访问其他业务资源。

### UAT预生产（测试/运维只读）
1. 测试人员仅全量只读权限，无删除/创建权限；
2. 运维操作员拥有发布更新权限，无PVC/PV删除权限；
3. 集群级资源（SC、PV、Node）仅专职存储运维可操作；
4. 禁止开发人员绑定全局ClusterRole。

### PROD生产（强最小权限约束）
1. **严禁普通员工绑定cluster-admin**，仅应急故障临时授予，事后立即回收；
2. 按岗位拆分细粒度ClusterRole：存储运维、网络运维、发布运维、审计管理员；
3. 开发人员仅可查看业务Pod日志，无任何修改/删除权限；
4. 删除有状态负载、PVC、修改NetworkPolicy、变更RBAC属于高危操作，需双人复核工单；
5. 所有业务Pod独立ServiceAccount，仅绑定完成自身工作所需最小权限；
6. OIDC分组严格隔离：开发组无法获取生产写权限，运维组按职能拆分权限。

## 七、运维账号权限分层划分
1. **开发账号（OIDC开发组）**
   FAT：读写Deployment/Service/Ingress；UAT/PROD：仅get/list/watch只读；
2. **测试账号（OIDC测试组）**
   全环境只读，无任何修改、删除动词权限；
3. **发布运维账号（OIDC deploy组）**
   拥有Deployment/StatefulSet滚动更新权限，禁止删除PVC/PV；
4. **存储运维账号（OIDC storage组）**
   全局SC/PV/PVC/快照管理权限，无Ingress/网络策略权限；
5. **网络运维账号（OIDC network组）**
   Ingress、Service、NetworkPolicy全局操作权限；
6. **超级应急账号（仅2名集群管理员持有）**
   临时cluster-admin，故障恢复后立即解绑ClusterRoleBinding。

## 八、RBAC标准运维操作
```bash
# 查看命名空间下所有Role/RoleBinding
kubectl get role,rolebinding -n prod

# 查看全局集群权限
kubectl get clusterrole,clusterrolebinding

# 校验用户是否拥有对应资源操作权限（权限预校验工具）
kubectl auth can-i delete statefulset mysql -n prod --as=oidc:user:zhangsan@example.com

# 查看账号绑定的所有权限
kubectl describe clusterrolebinding | grep ${user-name}

# 批量导出全集群RBAC资源备份
kubectl get role,rolebinding,clusterrole,clusterrolebinding -o yaml > all-rbac-backup.yaml
```

## 九、高频授权故障排查
### 1. API请求返回 403 Forbidden
1. 未绑定对应Role/RoleBinding，缺少资源操作动词权限；
2. 仅绑定命名空间Role，尝试操作集群级资源(Node/SC/PV)；
3. 权限绑定的subject用户名/组名与OIDC解析不一致；
4. Webhook外部授权拦截请求。
### 2. Pod内ServiceAccount调用API 403
SA绑定Role缺少对应资源verbs，补充规则或拆分细粒度角色。
### 3. 开发账号可删除生产PVC高危资源
错误绑定全局cluster-edit ClusterRole，拆解为最小粒度自定义Role。
### 4. kubelet无法上报节点状态
Node授权器异常，重启apiserver，检查kubelet证书归属system:nodes组。
### 5. RBAC变更后权限不生效
缓存同步延迟，等待1min或重启kube-apiserver；核对subject用户名/组名拼写。

## 十、生产安全最佳实践
1. 严格遵循最小权限原则，拒绝直接绑定cluster-admin/cluster-edit内置粗粒度角色；
2. 所有RBAC资源纳入Git版本管理，变更必须工单审批；
3. 定期巡检冗余ClusterRoleBinding、离职人员账号绑定，每月清理无效权限；
4. 区分命名空间Role与全局ClusterRole，业务开发仅分配NS内权限；
5. 业务控制器、备份任务使用独立ServiceAccount，禁止复用default SA；
6. 高危删除、存储操作权限专人管控，双人复核；
7. 开启审计日志监控403越权访问，持续告警异常权限尝试。

## 十一、关联文档
1. 身份认证：`01-authentication.md` OIDC用户/组、ServiceAccount身份体系
2. 准入控制：`03-admission-control.md` 拦截高权限Role、特权SA创建
3. 审计日志：`06-audit-log.md` RBAC变更、403越权操作全量审计告警
4. 安全加固：`07-security-best-practices.md` RBAC月度巡检清单
5. 网络安全：`05-network-security.md` 网络策略操作权限管控规范