# 02-resource-management.md
## 一、文档基础信息
- 归属目录：`06-daily-operations/`
- 前置阅读：`00-README.md`、`01-kubectl-usage.md`
- 集群基准：Kubernetes v1.32.13、GitOps资源管理、多环境隔离、RBAC权限体系
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心覆盖：Label标准化标签体系、Annotation注解使用场景、kubectl patch三种更新模式、标签筛选/批量操作、资源分组运维、标签清理规范、故障排查

## 二、Label & Annotation 底层区分
### 2.1 Label（标签）
1. 作用：**资源筛选、匹配、调度绑定**，可用于Selector匹配（Service、HPA、NetworkPolicy、PVC模板等）；
2. 格式限制：字母/数字/`-_.`，首尾只能数字字母；
3. 核心特性：可被K8s控制器用于关联匹配，业务筛选唯一标准。

### 2.2 Annotation（注解）
1. 作用：存放**描述性附加元数据**，不能用于Selector匹配；
2. 适用内容：发布记录、工单编号、责任人、变更时间、镜像构建信息、备注说明；
3. 无严格字符限制，支持长文本，仅做人工查阅、审计溯源。

## 三、全局标准化Label标签规范（全集群统一）
### 固定五维标签强制落地（所有资源必须携带）
```yaml
labels:
  env: prod          # 环境：dev/fat/uat/prod
  business: order    # 业务线：order/pay/user/storage
  app: mysql         # 应用名称
  tier: database     # 分层：frontend/backend/database/cache
  owner: ops-zhangsan # 责任人OIDC账号
```

### 扩展可选标签
- `version: v1.2.0`：应用版本
- `storage-type: ssd`：存储介质（PV/SC专用）
- `network: shared`：网络分类（NetworkPolicy专用）

### 标签查询筛选示例
```bash
# 筛选prod环境订单业务所有Pod
kubectl get pods -n prod -l env=prod,business=order

# 筛选所有数据库StatefulSet
kubectl get sts -A -l tier=database
```

## 四、Annotation 标准注解清单
```yaml
annotations:
  # 发布工单编号
  ops.k8s.io/ticket-id: "T2026070801"
  # 构建镜像CI流水线地址
  ci.k8s.io/build-url: "https://ci.example.com/build/12345"
  # 变更操作人
  ops.k8s.io/operator: "oidc:user:zhangsan@example.com"
  # 资源创建时间
  ops.k8s.io/create-time: "2026-07-08 10:30:00"
  # 业务备注、特殊说明
  ops.k8s.io/remark: "订单核心库，禁止随意删除PVC"
  # 准入控制/安全相关注解
  pod-security.kubernetes.io/enforce: restricted
```

### 使用红线
1. 禁止将Selector依赖的匹配字段写入Annotation；
2. 敏感密钥、密码不存入Annotation，统一使用Secret；
3. 注解不宜过长，超大文本存入独立ConfigMap。

## 五、kubectl patch 三种更新模式完整说明
### 5.1 patch 三种类型对比
| 类型 | 参数 | 适用场景 | 更新逻辑 |
|------|------|----------|----------|
| StrategicMergePatch | `--type strategic` | 工作负载Deployment/StatefulSet，自动合并数组、容器列表 | 智能合并，不覆盖完整数组 |
| MergePatch | `--type merge` | 通用资源ConfigMap/Service/PVC，简单键值覆盖 | 顶层key直接覆盖，数组全替换 |
| JSONPatch | `--type json` | 精准局部字段增删改，精细控制 | JSON路径原子操作（add/replace/remove） |

### 5.2 StrategicMergePatch（Deployment新增环境变量示例）
```bash
kubectl patch deployment order-api -n prod --type strategic -p '
spec:
  template:
    spec:
      containers:
      - name: app
        env:
        - name: NEW_FEATURE_SWITCH
          value: "true"
'
```
特点：原有env数组保留，追加新变量，不会清空全部环境变量。

### 5.3 MergePatch（修改PVC存储容量）
```bash
kubectl patch pvc file-share-pvc -n uat --type merge -p '
resources:
  requests:
    storage: 150Gi
'
```

### 5.4 JSONPatch（精准删除指定label）
```bash
kubectl patch deployment order-api -n prod --type json -p '[
  {"op":"remove","path":"/metadata/labels/old-deprecated"}
]'
```
常用op：`add`新增、`replace`覆盖、`remove`删除。

### Patch安全优势
相比`kubectl apply`完整重写yaml：仅修改目标字段，不会误删遗漏配置，生产变更优先使用patch。

## 六、资源批量筛选与分组运维操作
### 6.1 按Label批量查看资源
```bash
# 全集群筛选prod数据库所有资源
kubectl get deploy,sts,pvc,svc --all-namespaces -l env=prod,tier=database

# 筛选FAT环境所有待清理PVC
kubectl get pvc -n fat -l env=fat
```

### 6.2 批量添加标签
```bash
# 给命名空间下所有Pod统一新增owner标签
kubectl label pods -n prod owner=ops-lisi --all
```

### 6.3 批量删除带指定标签资源（FAT专用）
```bash
kubectl delete all -n fat -l env=fat,temp=true
```

### 6.4 按Namespace分组管理规范
1. 单一业务所有资源放入同一NS；
2. 依靠`env`标签区分环境，不跨NS混用业务；
3. NetworkPolicy、RBAC、SC集群资源依靠标签做环境分组管控。

## 七、DEV/FAT/UAT/PROD 差异化标签管控基线
### DEV本地
标签无强制规范，可随意自定义，无需统一五维标签。
### FAT测试
1. 必须携带`env=fat`基础标签，其余标签宽松；
2. 临时调试资源增加`temp=true`标签，用于批量自动清理；
3. Annotation无需完整工单记录。
### UAT预生产
1. 强制完整五维标准Label；
2. 所有变更必须携带工单ticket-id注解；
3. 废弃资源及时清理冗余标签。
### PROD生产（强制约束）
1. 所有资源（Pod/Deploy/STS/PVC/SC/NP/RBAC）必须完整五维Label；
2. 任何资源变更必须填写工单、操作人Annotation；
3. 禁止随意批量删除带生产标签资源，操作双人复核；
4. 每月巡检无标签、标签缺失资源，统一补全。

## 八、核心运维命令汇总
```bash
# 批量给资源打标签
kubectl label sts mysql -n prod owner=ops-wang --overwrite

# 查看资源完整标签、注解
kubectl describe deployment order-api -n prod

# 筛选缺少owner标签的Pod
kubectl get pods -n prod --selector '!owner'

# patch修改资源（三种模式）
kubectl patch ${resource} ${name} -n ${ns} --type strategic -p '{}'

# 导出带标签过滤的资源备份
kubectl get pvc -n prod -l env=prod -o yaml > prod-pvc-backup.yaml

# 删除过期临时标签资源（FAT）
kubectl delete all -n fat -l temp=true
```

## 九、高频故障排查
### 1. Service无法匹配后端Pod，流量404
Pod Label与Service `spec.selector` 标签不匹配，统一修正标签。
### 2. HPA无法采集目标Pod指标
缺少`tier/app`标准标签，selector匹配失败。
### 3. patch执行后数组配置被全部清空
使用`merge`模式操作数组，改用`strategic`策略智能合并。
### 4. Annotation写入敏感密码触发安全告警
密钥统一迁移Secret，禁止存入注解。
### 5. 批量打标签报错 label already exists
增加`--overwrite`参数覆盖原有标签。
### 6. StatefulSet扩容后PVC标签缺失
volumeClaimTemplates内补充标准labels，新扩容Pod自动携带标签。

## 十、生产最佳实践
1. 全集群统一五维Label标准，所有业务资源强制落地；
2. 区分Label用于匹配筛选、Annotation用于备注溯源，不混用；
3. 生产资源局部变更优先使用kubectl patch，减少完整yaml覆盖风险；
4. 临时测试资源统一标记`temp=true`，定时批量清理；
5. 所有生产变更携带工单、操作人Annotation，审计可追溯；
6. 每月巡检无标签、标签缺失、冗余废弃标签资源统一整理。

## 十一、关联文档
1. 客户端基础：`01-kubectl-usage.md` kubectl筛选、patch操作前置权限校验
2. 工作负载发布：`06-daily-operations/03-workload-operations.md` 发布前后标签核对规范
3. 网络安全：`05-security-management/05-network-security.md` NetworkPolicy基于Label白名单匹配
4. 存储管理：`04-storage-management/02-persistent-volume-claim.md` PVC标签环境隔离规范
5. 准入控制：`05-security-management/03-admission-control.md` 校验必填标准标签Webhook规则
6. 运维巡检：`06-daily-operations/07-production-checklist.md` 标签完整性月度巡检项