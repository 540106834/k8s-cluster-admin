# kubernetes-platform-design/02-namespace-resource-governance.md
## 文档元信息
- 模块：命名空间与多租户资源治理
- 优先级：★★★★★ 多租户隔离核心底座
- 依赖文档：00-platform-overview.md（分层、最小权限、标准化原则）、01-cluster-access-management.md（RBAC权限绑定）
- 关联模块：04-application-delivery、05-network-security、07-observability、14-platform-engineering、15-compliance-audit
- 适用角色：平台SRE、多租户架构师、资源管控运维、平台自助门户开发、安全审计

## 1. 模块定位与核心目标
### 1.1 定位
归属三层「集群资源管控域-租户资源域」，是平台多租户软隔离核心实现层。
基于K8s原生Namespace构建**环境隔离+团队隔离**双维度租户边界，配套资源配额、限流、标签规范、生命周期管控，配合RBAC、NetworkPolicy形成完整租户隔离体系。
所有业务应用、中间件、配置、密钥均运行在独立Namespace，禁止集群级无隔离业务资源。

### 1.2 核心目标
1. 标准化租户划分规则，统一环境/团队Namespace命名规范
2. 强制资源容量管控，杜绝单租户抢占集群全局计算、存储资源
3. 多维度软隔离：权限隔离、资源隔离、网络隔离、日志指标隔离
4. 自动化Namespace生命周期管理（申请→创建→扩容→回收→销毁）
5. 统一租户资源标签体系，实现分团队/分环境计量、账单、审计
6. 杜绝无配额、无限制裸Namespace，消除资源雪崩风险

### 1.3 解决业务痛点
- 测试环境无限创建Pod，耗尽集群节点内存CPU，冲击生产业务
- 多团队共用Namespace，误删其他业务Deployment/数据库PVC
- 无资源上限约束，突发流量导致集群全局调度拥堵
- 环境混杂（测试/预发/生产同NS），配置、流量、日志无法区分
- 闲置Namespace长期占用存储、IP配额，资源浪费无回收机制
- 资源使用无分层计量，无法按业务线分摊集群成本

## 2. 租户分层划分模型（双维度隔离）
### 2.1 环境分层（一级隔离维度）
全局固定4类环境，集群内统一前缀区分，不允许自定义环境标识
| 环境类型 | 前缀标识 | 使用场景 | 资源约束强度 |
|--------|--------|--------|------------|
| dev | dev-{team} | 开发自测、本地联调 | 宽松，配额可自助扩容 |
| test | test-{team} | 自动化测试、QA验证 | 中等，每日资源回收闲置Pod |
| staging | staging-{team} | 预发布、性能压测 | 严格，配额变更需审批 |
| prod | prod-{team} | 线上生产业务 | 极严格，配额、网络、权限强管控 |

### 2.2 团队/业务线分层（二级隔离维度）
namespace完整命名规范：`{env}-{business-team}`
示例：prod-pay、test-user、dev-order

### 2.3 禁止混合模式
1. 禁止单Namespace承载多业务团队；
2. 禁止同一Namespace混合生产+测试负载；
3. 禁止全局共享Namespace（default/kube-system除外系统命名空间）。

### 2.4 系统保留Namespace（禁止业务占用）
kube-system、kube-public、kube-node-lease、platform-addons、cert-manager、monitoring、harbor-operator
平台系统组件统一归集至platform-addons，与业务租户完全隔离。

## 3. Namespace 标准化生命周期管理
### 3.1 全流程自动化（依托14-platform-engineering自助门户）
1. **申请阶段**：研发提交工单，选择环境、业务团队、基础资源配额；
2. **自动创建**：审批通过后GitOps自动生成Namespace、RBAC绑定、Quota、LimitRange、NetworkPolicy基线；
3. **运维扩容**：租户自助提交配额提升工单，生产环境人工审批；
4. **闲置检测**：平台巡检任务识别90天无工作负载、无PVC的Namespace；
5. **回收销毁**：闲置通知后30天未使用，自动归档备份并删除Namespace；
6. **销毁兜底**：删除前自动备份所有ConfigMap/Secret/PVC清单，留存180天审计快照。

### 3.2 Namespace 强制固定标签（统一计量、筛选、告警）
所有租户NS创建自动注入不可修改Label：
```yaml
labels:
  platform.company.com/env: prod
  platform.company.com/team: pay
  platform.company.com/owner: dev@pay-team.com
  platform.company.com/resource-quota: standard-prod
  platform.company.com/lifecycle: active
```
Annotation扩展字段：创建时间、申请工单ID、配额审批人、过期回收时间。

## 4. 资源管控核心组件：ResourceQuota + LimitRange
### 4.1 LimitRange（容器默认资源约束，强制所有NS绑定）
作用：防止容器不配置requests/limits导致节点资源超配，统一设置默认值与最大值。
#### 全局标准化模板（区分环境）
1. Dev/Test默认模板
```yaml
default:
  cpu: 100m
  memory: 256Mi
defaultRequest:
  cpu: 50m
  memory: 128Mi
max:
  cpu: "4"
  memory: 4Gi
```
2. Staging/Prod默认模板
```yaml
default:
  cpu: 200m
  memory: 512Mi
defaultRequest:
  cpu: 100m
  memory: 256Mi
max:
  cpu: "8"
  memory: 16Gi
```
#### 强制约束
所有Pod必须声明requests/limits，超出LimitRange最大值准入控制器直接拦截创建。

### 4.2 ResourceQuota（租户总容量天花板，NS必带）
按环境预置4套标准配额模板，禁止自定义Quota参数：
1. dev-small / dev-medium
2. test-standard
3. staging-basic
4. prod-large

#### Quota管控资源范围
1. 计算资源总限额：requests.cpu、requests.memory、limits.cpu、limits.memory
2. 对象数量限额：Pods、Deployments、StatefulSets、Services、Ingresses、ConfigMaps、Secrets
3. 存储资源：PersistentVolumeClaims、标准存储总容量
4. 特殊资源：负载均衡Ingress数量、外部IP占用

#### 生产环境增强约束
- 限制PVC总容量，防止数据库日志无限扩容占用存储池；
- 限制高权限工作负载数量（特权容器、hostNetwork Pod）。

### 4.3 资源超限防护机制
1. 配额使用率80%：触发P2告警推送团队负责人；
2. 配额100%满额：拒绝新建Pod、PVC，平台推送扩容工单提醒；
3. 夜间自动回收：测试环境闲置副本数缩容至0，释放资源。

## 5. 多租户四层隔离体系（联动其他模块）
### 5.1 权限隔离（联动01-cluster-access-management）
1. NS创建时自动绑定对应团队OIDC分组RoleBinding，仅本团队可读写；
2. 跨Namespace访问默认无权限，跨业务读取/修改资源需单独审批；
3. 集群级ClusterRole仅运维可见，研发无任何集群全局操作权限。

### 5.2 资源容量隔离（本模块核心）
LimitRange管控单Pod上限，ResourceQuota管控租户总资源池，租户之间资源不抢占。

### 5.3 网络隔离（联动05-network-security）
每个Namespace自动下发基线NetworkPolicy：
1. 默认拒绝外部NS主动入站访问；
2. 仅允许同一Namespace内部Pod互通；
3. 允许访问平台基础组件CoreDNS、监控采集端；
4. 如需跨NS调用，需自助提交网络放行工单，自动更新Policy。

### 5.4 观测数据隔离（联动07-observability-platform）
日志、指标、告警自动携带namespace/env/team标签：
1. 研发仅能查看自身团队Namespace大盘与日志；
2. 生产环境告警单独分组推送，避免测试环境噪音干扰；
3. 支持按团队维度统计资源使用账单。

## 6. 准入控制器全局校验规则（联动10-workload-security）
所有Namespace资源创建时统一校验，不满足规则直接拦截：
1. 校验Pod是否配置requests/limits，无配置拒绝创建；
2. 校验资源用量是否超出当前Namespace ResourceQuota上限；
3. 校验Pod资源规格是否超出LimitRange单容器最大值；
4. 校验工作负载标签是否补全env/team/owner规范标签；
5. 校验禁止在prod命名空间创建无状态临时测试Pod。

## 7. 系统租户与业务租户差异化管控
### 7.1 系统Namespace（platform-addons、monitoring等）
1. 独立超大ResourceQuota，不受业务资源池限制；
2. 仅平台SRE具备编辑权限，研发无访问权限；
3. 独立网络策略，允许跨NS采集指标、日志。

### 7.2 业务Namespace（dev/test/staging/prod）
严格执行配额、网络、权限三重隔离，所有变更走GitOps流水线，禁止kubectl直改。

## 8. 资源计量与成本分摊
1. 采集维度：namespace、team、env、workload类型；
2. 统计指标：CPU/内存请求总量、PVC存储占用、Pod运行时长；
3. 输出月度资源账单，区分开发/测试/预发/生产成本；
4. 闲置Namespace资源单独统计，推动业务清理释放集群资源。

## 9. 安全与合规约束（联动15-compliance-audit）
1. 所有Namespace创建、配额修改、销毁操作全量记录审计日志；
2. 定期巡检：无Quota命名空间、无LimitRange租户、权限越权绑定；
3. 生产Namespace变更双人审批，操作日志留存180天；
4. 禁止prod命名空间对外开放无认证Ingress，准入控制器拦截。

## 10. 落地强制禁忌规范
1. 禁止创建无ResourceQuota、无LimitRange的Namespace；
2. 禁止多人多团队共用同一业务Namespace；
3. 禁止生产环境手动扩容配额，必须走审批工单；
4. 禁止删除平台自动注入的Namespace标准标签；
5. 禁止业务负载部署至kube-system、platform-addons等系统NS；
6. 禁止手动修改租户NetworkPolicy基线，跨NS通信统一走自助工单；
7. 禁止长期闲置Namespace不回收（超过90天无负载必须归档）。

## 11. 跨模块协作边界
1. 01-cluster-access-management：Namespace创建自动绑定团队RBAC权限；权限巡检联动NS归属校验；
2. 04-application-delivery：所有应用资源强制部署至业务NS，禁止集群级资源；
3. 05-network-security：基于Namespace自动下发隔离型NetworkPolicy；
4. 07-observability：按Namespace标签分片日志、指标、告警权限；
5. 14-platform-engineering：提供Namespace自助申请、配额扩容门户；GitOps托管所有NS资源定义；
6. 15-compliance-audit：Namespace生命周期变更、配额调整纳入审计巡检范围。