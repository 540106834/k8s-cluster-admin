# 06-yaml-management.md
## 一、文档基础信息
- 归属目录：`06-daily-operations/`
- 前置阅读：`00-README.md`、`01-kubectl-usage.md`、`02-resource-management.md`
- 集群基准：Kubernetes v1.32.13、GitOps流水线、准入配置校验、内网Harbor镜像仓库
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心覆盖：K8s资源YAML标准化编写规范、集群资源导出备份、本地YAML与线上集群diff对比、apply/create/patch三种操作选用原则、GitOps完整资源管理流程、YAML故障排查、资源变更管控

## 二、YAML标准化编写统一规范（全环境强制）
### 2.1 基础语法规范
1. 缩进统一2空格，禁止Tab；
2. 字符串无需多余引号，特殊字符/空格使用双引号；
3. 资源顺序固定：apiVersion → kind → metadata → spec；
4. metadata固定五维标准Label、工单Annotation；
5. 禁止行尾空格、多余空行，CI校验自动格式化；
6. 镜像禁止latest标签，必须固定版本tag；
7. 生产Pod完整配置securityContext安全上下文。

### 2.2 标准最小完整Deployment模板示例
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-api
  namespace: prod
  labels:
    env: prod
    business: order
    app: order-api
    tier: backend
    owner: ops-zhangsan
  annotations:
    ops.k8s.io/ticket-id: "T2026070801"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: order-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        env: prod
        business: order
        app: order-api
    spec:
      serviceAccountName: order-backend-sa
      imagePullSecrets:
      - name: harbor-pull-secret
      containers:
      - name: app
        image: harbor.jinshaoyong.com/k8s/order-api:v1.2.0
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true
        envFrom:
        - configMapRef:
            name: order-app-config
        - secretRef:
            name: mysql-cred-prod
        ports:
        - containerPort: 8080
```

### 2.3 禁止写入YAML的内容（准入拦截）
1. 明文数据库密码、仓库密钥、Token；
2. 特权容器 `privileged: true`；
3. hostNetwork/hostPID/hostIPC共享宿主机命名空间；
4. 超大无限制容器资源max cpu/memory；
5. 公网docker.io镜像、latest浮动标签。

## 三、集群资源导出备份操作
### 3.1 单资源导出（用于故障回滚备份）
```bash
# 导出Deployment完整yaml
kubectl get deployment order-api -n prod -o yaml > deploy-order-prod-backup.yaml
```
### 3.2 命名空间全资源批量导出
```bash
# 导出当前ns所有工作负载、网络、存储资源
kubectl get deploy,sts,svc,ingress,pvc,configmap,networkpolicy -n prod -o yaml > ns-prod-full-backup-$(date +%Y%m%d).yaml
```
### 3.3 集群全局资源导出（升级/割接前）
```bash
kubectl get storageclasses,pv,clusterrole,clusterrolebinding -o yaml > cluster-global-backup.yaml
```
### 备份规范
PROD高危变更前必须导出对应资源yaml，同时执行etcd快照，双备份兜底。

## 四、本地YAML与线上集群diff对比（变更前必执行）
### 4.1 diff对比命令
```bash
# 对比本地文件与集群当前资源差异
kubectl diff -f deploy-order-prod.yaml -n prod
```
### 使用场景
1. 修改配置前查看线上已有配置，避免误删字段；
2. Git提交前校验变更内容，防止多余删除配置；
3. 多人协同修改资源，识别冲突字段。
### 安全优势
diff会清晰展示新增/删除/修改行，提前发现误删除PVC、NetworkPolicy等高危字段。

## 五、create / apply / patch 三种操作选用原则
| 操作 | 适用场景 | 风险说明 |
|------|----------|----------|
| `kubectl create` | 全新资源首次创建，不存在集群资源 | 资源已存在会直接报错，不覆盖；仅初次使用 |
| `kubectl apply` | 完整资源YAML更新，合并增量配置 | 完整覆盖顶层字段，数组会被替换，生产优先搭配diff预校验 |
| `kubectl patch` | 局部少量字段更新，不重写完整yaml | 最小变更，不会误删无关配置，生产局部修改推荐首选 |

### 使用规范
1. 全新资源首次创建：`kubectl create -f`；
2. 完整配置大面积修改：先`kubectl diff`确认再`kubectl apply`；
3. 仅修改少量字段（资源、镜像、标签）：统一使用`kubectl patch`；
4. PROD禁止直接apply完整yaml修改RBAC、NetworkPolicy、Secret高危资源，优先patch。

## 六、GitOps 标准化资源管理落地规范
### 6.1 仓库目录分层结构
```
k8s-resources/
├── global/            # 集群全局资源：SC、RBAC、CRD、Webhook
├── fat/
│   ├── workload/     # deploy/sts/svc
│   ├── config/       # ConfigMap
│   ├── storage/      # PVC/LimitRange
│   ├── network/      # NetworkPolicy/Ingress
├── uat/
└── prod/
```
### 6.2 GitOps完整流水线流程
1. 开发/运维修改对应环境YAML提交MR；
2. CI自动校验：YAML语法、明文密钥扫描、镜像tag校验、PSS安全上下文校验；
3. diff对比线上资源，输出变更预览；
4. 双人复核合并代码；
5. ArgoCD/Flux自动同步至集群，下发资源；
6. 观测rollout、events确认资源生效。

### 6.3 禁止行为
1. 禁止本地临时`kubectl apply`绕过Git流水线；
2. 禁止在Git仓库存放明文Secret，Secret独立加密仓库管理；
3. 禁止共用一套YAML多环境复用，各环境独立资源文件。

## 七、DEV/FAT/UAT/PROD 差异化YAML管控基线
### DEV本地
无严格YAML规范，可本地临时创建资源，无需Git管理。
### FAT测试
1. 基础语法规范，无需完整Restricted安全上下文；
2. 可本地临时kubectl apply调试，定时清理废弃资源。
### UAT预生产
1. YAML规范完全对齐生产，完整五维Label、安全上下文；
2. 所有资源必须纳入Git，禁止本地临时操作；
3. 变更前diff对比，留存备份。
### PROD生产（强制约束）
1. 强制完整生产标准YAML模板，缺失安全上下文准入拦截；
2. 所有资源100%由GitOps下发，禁止本地kubectl apply/patch直接操作集群；
3. 变更前必须执行kubectl diff预览差异，双人复核工单；
4. 高危资源（RBAC/NP/Secret/PVC）仅允许patch局部更新，不完整apply覆盖；
5. 月度清理Git仓库废弃无用YAML文件，减少冗余配置。

## 八、核心运维命令汇总
```bash
# 导出资源备份
kubectl get deploy order-api -n prod -o yaml > backup.yaml

# 本地与集群diff对比
kubectl diff -f deploy.yaml -n prod

# 全新资源创建
kubectl create -f deploy.yaml -n prod

# 完整配置更新
kubectl apply -f deploy.yaml -n prod

# 局部字段更新（推荐生产局部变更）
kubectl patch deploy order-api -n prod --type strategic -p '{}'

# 校验YAML语法（无需连接集群）
kubectl apply -f deploy.yaml --dry-run=client
```

## 九、高频YAML管理故障排查
### 1. kubectl apply 报错 validation error: error validating
YAML缩进错误、字段拼写错误、apiVersion不匹配资源kind，使用`kubectl apply --dry-run=client`离线校验语法。

### 2. apply后数组配置被全部清空
使用apply完整覆盖，数组无默认值；局部数组修改改用strategic patch模式。

### 3. Git提交包含明文密码被CI拦截
敏感数据迁移至Secret，CM仅存放非敏感配置。

### 4. diff无输出，但apply后资源大量变更
本地YAML缺少集群自动注入字段（SA、annotations），使用`kubectl get -o yaml`导出线上基准再修改。

### 5. create报错 AlreadyExists
资源已存在，改用apply或patch更新。

### 6. GitOps同步失败，Webhook校验拒绝
YAML缺少标准安全上下文、使用公网镜像latest标签，补齐规范后重新提交。

## 十、生产最佳实践
1. 统一标准化YAML模板，全环境遵循同一书写规范；
2. 资源变更前必做diff对比，提前识别高危删除操作；
3. 区分create/apply/patch使用场景，局部更新优先patch降低风险；
4. 所有线上资源纳入GitOps管理，杜绝本地临时操作集群；
5. CI流水线自动校验YAML语法、安全配置、明文密钥，提前拦截违规资源；
6. 高危存储、网络、权限资源禁止完整apply覆盖，采用局部patch；
7. 定期导出集群资源备份，与Git仓库对比，保证配置一致性。

## 十一、关联文档
1. 客户端工具：`01-kubectl-usage.md` dry-run预校验、权限预校验操作
2. 资源标签管理：`02-resource-management.md` 标准Label/Annotation写入规范
3. 工作负载发布：`03-workload-operations.md` apply下发后滚动发布观测流程
4. 准入控制：`05-security-management/03-admission-control.md` YAML违规配置拦截Webhook
5. 配置管理：`02-workload-management/11-configuration-management.md` ConfigMap YAML编写规范
6. 安全审计：`05-security-management/06-audit-log.md` YAML变更apply操作审计告警
7. 运维巡检：`07-production-checklist.md` 集群资源与Git配置一致性月度巡检项