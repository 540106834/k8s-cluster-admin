# 04-secret-management.md
## 一、文档基础信息
- 归属目录：`05-security-management/`
- 前置阅读：`00-README.md`、`01-authentication.md`、`03-admission-control.md`
- 集群基准：Kubernetes v1.32.13、静态加密etcd、内网Harbor私有镜像仓库、准入Webhook密钥校验
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：Secret三类资源类型、镜像拉取私有仓库密钥配置、etcd静态加密、禁止明文硬编码、密钥轮换流程、RBAC最小权限管控、日志防泄露、Secret销毁规范、故障排查

## 二、Secret底层基础理论
### 2.1 Secret定位
Secret用于存储敏感数据：数据库账号密码、镜像仓库凭证、API密钥、TLS证书、OIDC密钥；
区别于ConfigMap：ConfigMap存放明文非敏感配置，Secret仅用于机密数据，**集群仅Base64编码，不加密存储，必须开启etcd静态加密实现持久加密**。

### 2.2 Secret 三种标准类型
1. **kubernetes.io/service-account-token**
   自动生成，ServiceAccount绑定JWT认证令牌，Pod内部访问API凭证，禁止手动创建/修改。
2. **kubernetes.io/dockerconfigjson**
   私有镜像仓库拉取凭证，用于Pod拉取内网Harbor镜像鉴权。
3. **Opaque（默认通用类型）**
   自定义任意密钥字符串：数据库账号、API密钥、Redis密码等业务敏感凭证。

### 2.3 数据存储风险说明
原生Secret仅Base64编码，Base64可直接解码，不属于加密；
**PROD集群必须开启etcd静态加密**，防止etcd数据泄露导致密钥明文泄漏。

## 三、标准Secret完整模板
### 3.1 Opaque通用业务密钥（数据库账号）
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mysql-cred-prod
  namespace: prod
  labels:
    env: prod
    business: order
type: Opaque
data:
  # 内容需base64编码，禁止明文写入
  MYSQL_ROOT_USER: YWRtaW4=
  MYSQL_ROOT_PASSWORD: cGFzc3dvcmQxMjM=
```
### 容器环境变量挂载方式
```yaml
env:
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: mysql-cred-prod
      key: MYSQL_ROOT_PASSWORD
```
### 容器文件挂载方式（证书/密钥文件）
```yaml
volumeMounts:
- name: cert-secret
  mountPath: /etc/tls
volumes:
- name: cert-secret
  secret:
    secretName: tls-cert-prod
```

### 3.2 私有镜像仓库密钥 dockerconfigjson（内网Harbor）
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-pull-secret
  namespace: prod
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: eyJhdXRocyI6eyJoYXJib3Iuamluc2hhb3l5b25nLmNvbSI6eyJ1c2VybmFtZSI6Im9wZXJhdG9yIiwicGFzc3dvcmQiOiIxMjM0NTYifX19
```
### Pod绑定镜像拉取密钥
```yaml
spec:
  imagePullSecrets:
  - name: harbor-pull-secret
```

## 四、etcd 静态加密配置（PROD强制开启）
### 4.1 apiserver启动参数
```
--encryption-provider-config=/etc/kubernetes/ssl/encryption-config.yaml
```
### 加密配置示例 encryption-config.yaml
```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: ["secrets"]
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: 32位随机加密密钥base64
  - identity: {}
```
### 加密运维规范
1. 加密密钥离线备份，双人保管；
2. 密钥按月轮换，轮换后重启apiserver；
3. 未开启加密的集群，Secret存在明文泄露风险，禁止存放核心生产密钥。

## 五、核心安全管控规范
### 5.1 严格禁止明文硬编码
1. YAML中禁止直接写入明文密码，全部使用Secret；
2. 代码、ConfigMap、环境变量禁止硬编码密钥；
3. 准入Webhook拦截包含明文密码的Pod/Deployment资源创建。

### 5.2 Secret 最小RBAC权限管控
1. 普通开发账号仅允许`get/watch`本NS业务Secret，禁止`update/delete`；
2. 发布运维仅可读取业务Secret，无修改权限；
3. 仅安全/存储运维拥有Secret更新、轮换权限；
4. 禁止绑定集群全局Secret读写权限给开发人员。

### 5.3 日志防泄露约束
1. 应用日志禁止打印完整密钥、数据库密码；
2. 准入控制拦截容器输出密钥至stdout/stderr；
3. 审计日志脱敏Secret内容，不输出完整密钥文本。

### 5.4 Secret 密钥轮换标准流程
1. 生成新密钥，新建Secret并存双份新旧密钥；
2. 滚动重启业务Pod加载新Secret；
3. 业务验证正常，保留旧Secret7天用于回滚；
4. 7天后确认无故障，删除旧Secret；
5. 轮换操作记录工单，双人复核。

## 六、DEV/FAT/UAT/PROD 差异化Secret管控基线
### DEV本地
1. 无需etcd加密，临时测试Secret可短期明文生成；
2. 密钥轮换无强制周期，调试完成可直接删除。

### FAT测试
1. Secret仅存放测试弱密码，禁止线上真实业务密钥；
2. 按月清理废弃Secret，无需长期备份；
3. 准入仅告警明文硬编码，不强制拦截。

### UAT预生产
1. 开启etcd静态加密，对齐生产密钥规范；
2. 密钥按月轮换，禁止长期不更新；
3. 准入拦截明文硬编码配置；
4. 测试密钥不允许同步至PROD。

### PROD生产（强制红线）
1. 全局开启etcd静态加密，无例外；
2. 核心业务密钥按月轮换，数据库、仓库密钥90天强制更新；
3. 所有Secret纳入Git加密仓库管理，禁止明文YAML入库；
4. 开发人员无Secret更新/删除权限，仅运维可操作；
5. 禁止将生产Secret复制至FAT测试环境；
6. Secret删除双人复核，删除前完成业务备份。

## 七、Secret 运维标准操作命令
```bash
# 创建Secret（从文件生成，避免明文写yaml）
kubectl create secret generic mysql-cred-prod -n prod \
--from-literal=MYSQL_ROOT_PASSWORD=xxxx

# 查看Secret基础信息（不输出完整密钥）
kubectl get secret -n prod

# 解码查看密钥（运维临时校验）
kubectl get secret mysql-cred-prod -n prod -o jsonpath="{.data.MYSQL_ROOT_PASSWORD}" | base64 -d

# 导出Secret加密备份
kubectl get secret harbor-pull-secret -n prod -o yaml > secret-backup.yaml

# 批量清理FAT废弃Secret
kubectl delete secret -n fat --field-selector type=Opaque
```

## 八、高频Secret故障排查
### 1. Pod拉取镜像报错 unauthorized: authentication required
imagePullSecrets未配置、Harbor账号密码错误、Secret类型不是dockerconfigjson。

### 2. 容器启动报错 secret not found
Secret名称/命名空间不匹配、Secret被误删除、RBAC无读取Secret权限。

### 3. 密钥更新后Pod未加载新密码
Secret更新不会自动重启Pod，执行滚动重启负载生效。

### 4. 集群未开启etcd加密，Secret存在泄露风险
修改apiserver加密配置，重启控制平面组件全量加密已有Secret。

### 5. 开发人员可修改生产Secret
RBAC权限过大，回收update/delete动词，仅保留只读权限。

### 6. 日志输出数据库密码触发告警
应用日志未脱敏，修改日志输出逻辑，准入规则拦截明文密钥输出。

## 九、生产安全最佳实践
1. 所有敏感凭证统一使用Secret托管，杜绝明文硬编码；
2. PROD集群强制开启etcd静态加密，加固持久化存储密钥；
3. 严格控制Secret RBAC权限，遵循最小只读权限；
4. 建立密钥轮换周期，核心业务按月轮换，降低泄露风险；
5. 禁止测试环境复用生产密钥，隔离两套独立凭证；
6. 变更、删除Secret双人复核，操作留存审计日志；
7. 定期巡检废弃Secret，及时清理减少泄露面。

## 十、关联文档
1. 认证体系：`01-authentication.md` ServiceAccount Token Secret管控
2. 准入控制：`03-admission-control.md` 拦截明文硬编码资源Webhook规则
3. RBAC授权：`02-authorization.md` Secret读写权限角色划分
4. 审计日志：`06-audit-log.md` Secret创建/更新/删除高危操作审计告警
5. 镜像仓库：内网Harbor离线部署文档 镜像拉取密钥配置
6. 安全加固：`07-security-best-practices.md` Secret月度安全巡检清单