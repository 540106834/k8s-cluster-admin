# 02-workload-management/11-configuration-management.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`04-secret-management.md`、`05-security-management/03-admission-control.md`
- 集群基准：Kubernetes v1.32.13、准入Webhook配置校验、GitOps配置管理、内网Harbor
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：ConfigMap完整规范、配置注入三种方式、配置热更新机制、明文配置安全校验、环境隔离配置、GitOps配置流水线、配置变更发布流程、配置故障排查

## 二、配置管理底层核心理论
### 2.1 ConfigMap 定位
ConfigMap 用于存放**非敏感明文配置**：应用配置文件、启动脚本、环境变量、静态静态资源；
与Secret严格区分：
1. 明文普通配置 → ConfigMap；
2. 密码、密钥、证书等敏感数据 → Secret，禁止混用。

### 2.2 配置注入三种方式
1. 环境变量注入：`envFrom / env.valueFrom.configMapKeyRef`；
2. 挂载文件卷：`volumeMounts` 完整配置文件/脚本目录；
3. 命令行参数：`command/args` 读取ConfigMap内容。

### 2.3 配置更新两种生效机制
1. 挂载文件卷：ConfigMap更新后，容器内文件**10秒左右自动同步**，无需重启Pod；
2. 环境变量注入：ConfigMap更新**不会自动刷新容器环境变量**，必须滚动重启负载生效。

## 三、标准ConfigMap模板
### 3.1 键值对环境变量配置
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-app-config
  namespace: prod
  labels:
    app: order-api
    env: prod
data:
  LOG_LEVEL: "info"
  MAX_CONCURRENT: "1000"
  REDIS_TIMEOUT: "3000"
```
#### Pod注入环境变量
```yaml
envFrom:
- configMapRef:
    name: order-app-config
```

### 3.2 完整配置文件挂载（nginx.conf/启动脚本）
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-conf-prod
  namespace: prod
data:
  nginx.conf: |
    server {
      listen 8080;
      location / {
        root /usr/share/nginx/html;
      }
    }
```
#### Pod挂载文件
```yaml
volumes:
- name: nginx-conf
  configMap:
    name: nginx-conf-prod
volumeMounts:
- name: nginx-conf
  mountPath: /etc/nginx/conf.d
```

### 3.3 启动脚本ConfigMap（备份/初始化脚本）
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-backup-script
  namespace: prod
data:
  backup.sh: |
    #!/bin/sh
    mysqldump -h $DB_ADDR --all-databases > /backup/mysql-$(date +%Y%m%d).sql
    find /backup -mtime +7 -delete
```

## 四、配置热更新与生效管控规范
1. 文件挂载模式：修改CM后自动同步，无需重启Pod；
2. 环境变量模式：更新CM后必须执行滚动重启负载：
```bash
kubectl rollout restart deployment order-api -n prod
```
3. 生产变更规范：配置修改避开业务高峰，灰度分批重启Pod，防止批量服务不可用。

## 五、安全准入校验规则（准入Webhook拦截违规配置）
### 5.1 禁止行为清单（准入拦截）
1. ConfigMap中写入数据库密码、仓库密钥等敏感明文；
2. 超大体积ConfigMap（超过1Mi）拆分至独立文件存储；
3. 配置文件包含高危系统命令、提权脚本；
4. 生产环境配置硬编码测试地址、测试数据库地址。
### 5.2 安全区分红线
- 所有账号密码、API密钥、TLS私钥必须存入Secret；
- 禁止在ConfigMap、Deployment env硬编码任何敏感凭证。

## 六、多环境配置隔离规范（DEV/FAT/UAT/PROD）
### 隔离原则
三套业务环境独立ConfigMap，配置参数差异化，禁止共用同一CM资源：
1. 数据库连接地址、缓存地址、日志级别、并发参数按环境区分；
2. PROD禁用调试日志、开启严格日志脱敏；FAT可开启debug调试日志。

| 环境 | 配置规范 | 变更审批 | 留存周期 |
|------|----------|----------|----------|
| DEV本地 | 临时简易ConfigMap，无严格规范 | 无需审批 | 本地调试后删除 |
| FAT测试 | 宽松配置，允许debug日志 | 开发自行变更 | 每日清理废弃CM |
| UAT预生产 | 配置参数对齐生产，仅调试日志放开 | 运维确认即可变更 | 业务下线人工清理 |
| PROD生产（强制） | 日志info级别、无调试开关、独立生产地址 | 双人复核+Git提交记录 | 永久留存，下线工单清理 |

## 七、GitOps 配置流水线标准化落地
1. 所有ConfigMap YAML纳入Git仓库，按环境目录拆分 `config/fat/`、`config/uat/`、`config/prod/`；
2. 代码提交触发CI校验：扫描ConfigMap是否包含明文敏感密钥，违规直接阻断合并；
3. Git提交合并后自动同步至集群，实现配置变更可追溯、可回滚；
4. 禁止直接kubectl apply 本地临时yaml，所有配置必须走Git流水线下发集群。

## 八、配置变更标准发布流程（生产）
1. 修改Git仓库对应环境ConfigMap；
2. CI自动执行安全扫描，校验无明文密钥；
3. 提交合并工单，双人复核配置变更内容；
4. 流水线自动下发至集群；
5. 若为环境变量注入模式，自动触发负载滚动重启；
6. 观测Pod就绪、业务日志无报错，验证配置生效；
7. 留存Git提交记录、操作审计日志，便于回滚。

## 九、标准运维操作命令
```bash
# 创建/更新配置
kubectl apply -f cm-order-prod.yaml -n prod

# 查看命名空间所有ConfigMap
kubectl get configmap -n prod

# 查看完整配置内容
kubectl describe configmap nginx-conf-prod -n prod

# 查看CM挂载同步事件
kubectl get events -n prod | grep ConfigMap

# 滚动重启负载刷新环境变量配置
kubectl rollout restart deployment order-api -n prod

# 批量清理FAT废弃ConfigMap
kubectl delete configmap -n fat --field-selector metadata.env=fat
```

## 十、高频配置故障排查
### 1. 修改ConfigMap后业务配置不生效
注入方式为环境变量，CM更新不会自动刷新，执行rollout restart重启Pod。
### 2. Pod启动报错 configmap not found
CM名称/命名空间不匹配、CM被误删除。
### 3. 准入Webhook拒绝创建ConfigMap
CM内包含明文密码、密钥等敏感内容，迁移至Secret管理。
### 4. 挂载配置文件内容为空/权限不足
ConfigMap键名拼写错误、Pod securityContext运行用户不匹配文件权限。
### 5. 配置文件实时更新，但业务未读取新配置
应用未实现文件热重载，重启Pod或应用自身重载配置文件。
### 6. 批量更新CM后大量Pod重启，业务卡顿
批量一次性重启所有副本，拆分分批滚动重启，业务低峰操作。

## 十一、生产配置最佳实践
1. 严格区分ConfigMap（明文配置）与Secret（敏感密钥），杜绝明文密钥存CM；
2. 业务配置全部纳入GitOps管理，禁止本地临时kubectl操作；
3. 文件挂载优先使用ConfigMap，便于热更新，减少Pod重启次数；
4. 多环境独立CM，隔离FAT/UAT/PROD配置参数，避免测试地址污染生产；
5. 准入Webhook扫描CM明文敏感字段，提前拦截配置泄露风险；
6. 配置变更避开业务高峰，分批滚动重启负载，降低业务抖动；
7. 定期清理废弃无用ConfigMap，减少集群配置冗余。

## 十二、关联文档
1. 密钥管理：`04-secret-management.md` Secret与ConfigMap使用边界区分
2. 准入控制：`05-security-management/03-admission-control.md` 配置明文敏感内容拦截Webhook
3. 工作负载发布：`02-workload-management/08-deployment-rollout.md` 滚动重启刷新配置流程
4. 审计日志：`05-security-management/06-audit-log.md` ConfigMap创建/更新/删除审计告警
5. 安全加固：`05-security-management/07-security-best-practices.md` 配置明文泄露巡检清单
6. 网络管理：`03-network-management/04-ingress-management.md` Nginx配置CM挂载规范