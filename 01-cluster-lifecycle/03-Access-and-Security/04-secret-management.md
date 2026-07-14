# cluster‑deploy‑docs/secret‑management.md
## 一、文档基础信息
- 文件路径：`cluster‑deploy‑docs/secret‑management.md`
- 前置文档：`authentication.md`、`authorization.md`
- K8s版本：Kubernetes‑1.32.13
- 文档范围：Secret资源类型、创建方式、底层存储、加密配置、挂载方式、镜像拉取Secret、安全风险、外部密钥方案（External‑Secrets‑Operator）、生命周期管理、权限管控、环境差异化标准、故障排查。
- 前置认知：认证(Authentication) → 授权(RBAC Authorization) → Secret敏感数据分发。

## 二、Secret概述
### 2.1 Secret作用
用于存放敏感信息：数据库账号密码、Redis密码、API密钥、镜像仓库凭证、TLS证书、访问Token；避免明文写在ConfigMap、Pod YAML或者容器镜像内。
> ConfigMap：存放非明文配置；Secret专门存放敏感数据。

### 2.2 Kubernetes原生Secret底层短板（生产重点）
1. 默认情况下，etcd中Secret仅进行Base64编码，**并不是加密**；Base64只是编码，可以轻松解码；
2. 集群内只要拥有读取Secret权限（get secret）就可以拿到明文；
3. Secret数据会被缓存到节点内存；Pod启动时会挂载到容器内文件或者环境变量；
4. etcd必须开启静态加密（Encrypt Secrets at Rest），否则etcd数据库文件中密钥为Base64字符串，存在泄露风险。

### 2.3 4种内置Secret类型
| Type | 用途 |
|------|------|
| `Opaque`（默认） | 通用密钥，自定义键值对，日常使用最多 |
| `kubernetes.io/dockerconfigjson` | Harbor镜像仓库认证凭证，拉取私有镜像使用 |
| `kubernetes.io/tls` | TLS证书和私钥，Ingress HTTPS场景使用 |
| `kubernetes.io/service‑account‑token` | SA自动创建的JWT令牌，由K8s自动维护，人工不要创建 |

## 三、Secret创建方式
### 方式1：命令行创建（推荐，避免YAML明文写Base64字符串）
```bash
# 创建opaque类型secret
kubectl create secret generic db-secret -n prod \
--from-literal=db-user=root \
--from-literal=db-password="Root@123456"
```

### 方式2：YAML文件创建（不推荐直接写yaml文件）
> 注意：value值必须先做base64编码：`echo -n "Root@123456" | base64`
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: prod
type: Opaque
data:
  db-user: cm9vdA==
  db-password: Um9vdEAxMjM0NTY=
```
弊端：YAML文件如果提交Git仓库，会造成密钥泄露，生产禁止把base64密钥提交Git。

### 方式3：镜像仓库Secret（dockerconfigjson）
```bash
kubectl create secret docker-registry harbor-auth -n prod \
--docker-server=harbor.jinshaoyong.com \
--docker-username=admin \
--docker-password=Harbor@123
# 在serviceAccount绑定imagePullSecrets，Pod自动继承镜像凭证
kubectl patch serviceaccount default -n prod -p '{"imagePullSecrets":[{"name":"harbor-auth"}]}'
```

### 方式4：TLS证书Secret
```bash
kubectl create secret tls ingress-tls -n ingress-ns \
--cert=fullchain.crt --key=priv.key
```

## 四、Secret两种注入Pod方式
### 4.1 环境变量注入（env）
```yaml
env:
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: db-secret
      key: db-password
```
缺点：执行`printenv`或者查看容器进程环境变量即可看到明文，安全性偏弱。

### 4.2 文件挂载方式（生产推荐）
Secret会以只读文件形式挂载到容器指定目录，文件权限400。
```yaml
volumes:
- name: secret-volume
  secret:
    secretName: db-secret
volumeMounts:
- name: secret-volume
  mountPath: "/etc/secret-data"
  readOnly: true
```
应用程序读取 `/etc/secret-data/db-password` 文件获取密钥；相比环境变量更加安全。

> 重要特性：Secret内容更新之后：
> - 挂载文件模式：容器内文件大概45‑60秒自动更新；
> - env环境变量模式：Pod重启之后才会生效。

## 五、etcd静态加密（PROD必做）
1. apiserver开启加密配置文件 `--encryption‑provider‑config=/etc/kubernetes/pki/encryption-config.yaml`；
2. 使用AES‑GCM算法对Secret持久化存入etcd时进行加密；
3. 密钥保存在master节点本地，etcd磁盘中不再存储base64明文；
4. 未开启加密为生产重大安全漏洞。
示例加密配置：
```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key1
        secret: "这里填入32位base64加密密钥"
  - identity: {}
```
> identity代表不加密，配置顺序靠前优先执行加密。

## 六、生产高级方案：外部密钥管理（推荐）
原生Secret依然有短板：密钥无法自动轮换、密钥会被有权限的用户读取；生产环境推荐使用**External‑Secrets‑Operator(ESO)**对接外部密钥管理系统。
1. 外部密钥管理系统：Vault、阿里云KMS；
2. ESO在集群创建`ExternalSecret` CRD资源；
3. 集群不再存放真实密钥，ESO从外部KMS拉取密钥生成K8s Secret；
4. 密钥轮换在Vault里修改，集群自动同步更新；
5. 集群内部人员即使拿到Secret读取权限，也无法进入Vault修改密钥；实现密钥和集群解耦。

## 七、RBAC权限管控（非常关键）
### 7.1 最小权限原则
1. 普通开发人员：禁止授予`get secrets`权限；只能查看Pod和日志；
2. 项目管理员(ns‑admin)：仅本命名空间内可以查看Secret；
3. 运维账号：仅必要人员可以读取Secret；
4. ServiceAccount：只授予程序必须访问的Secret，不要全局放开。

示例禁止开发人员读取secret：
- 内置`view` ClusterRole默认**没有get secrets权限**；
- `admin`角色具备secret读写权限；分配角色时慎重选择。

查看权限命令：
```bash
# 校验用户是否可以读取secret
kubectl auth can-i get secrets -n prod --as dev-user
```

### 7.2 常见安全问题
1. 开发者拿到namespace admin权限读取secret拿到数据库密码；
2. 集群内部Pod被入侵，通过SA读取命名空间下全部Secret；
3. Secret被导出提交到Git；
4. etcd未开启加密，etcd备份文件泄露造成密钥外泄。

## 八、Secret生命周期管理（生产SOP）
1. 创建阶段：
   - 优先使用`kubectl create secret`命令行创建；禁止明文写在yaml；
   - 生产环境接入Vault+External‑Secrets‑Operator；
2. 使用阶段：
   - 优先文件挂载方式，尽量不用环境变量注入；
   - 严格控制RBAC读取权限；etcd开启静态加密；
3. 密钥轮换：
   - 原生Secret：修改secret内容，滚动重启Pod；
   - Vault方案：外部系统更新密钥，ESO自动同步；
4. 废弃清理：项目下线删除对应的Secret；删除无用的docker‑configjson密钥。

## 九、DEV/FAT/UAT/PROD差异化标准
1. DEV环境：
    - 可以直接使用原生Secret；etcd加密可选；密钥可以简单管理；
2. FAT测试环境：
    - etcd开启静态加密；禁止将Secret YAML提交Git；开发人员无读取Secret权限；
3. UAT预生产：
    - 部署External‑Secrets‑Operator对接测试Vault；逐步脱离原生Secret；
    - Secret全部由ExternalSecret资源生成，不手动创建Secret；
4. PROD生产环境（强制约束）
    1. etcd必须开启Secret静态加密；不允许裸Secret；
    2. 生产正式密钥统一存放在Vault，通过External‑Secrets‑Operator同步；
    3. 普通开发人员禁止拥有get secrets权限；运维人员双人复核才可查看密钥；
    4. 定期清理废弃Secret、过期Harbor凭证；
    5. 禁止把Secret的Base64值存入Git、CI配置文件、镜像内部；
    6. apiserver审计日志记录Secret读取、修改事件。

## 十、常用运维命令
```bash
# 查看secret
kubectl get secret -n prod
# 查看secret详情（查看base64编码内容）
kubectl get secret db-secret -n prod -o yaml
# 解码查看明文
kubectl get secret db-secret -n prod -o jsonpath='{.data.db-password}' | base64 -d
# 删除secret
kubectl delete secret db-secret -n prod
# 查看SA是否有读取secret权限
kubectl auth can-i get secrets -n prod --as system:serviceaccount:prod:app-sa
```

## 十一、故障排查
### 问题1：Pod启动失败，提示找不到secret
1. secret名称写错；
2. secret不在当前Pod命名空间；
3. secret被误删除。

### 问题2：环境变量里面密钥没有更新
- 原因：env注入方式Secret更新后Pod不会自动加载；解决：重启Pod；
- 文件挂载模式等待60秒左右即可生效。

### 问题3：镜像拉取失败 ImagePullBackOff
1. docker‑configjson secret创建错误；
2. 没有绑定到当前namespace default ServiceAccount；
3. Harbor账号密码错误。

### 问题4：etcd备份文件可以解码出密钥
解决：开启apiserver encryption‑provider配置，重启apiserver。

## 十二、最佳实践总结
1. 尽量避免手动创建Secret，生产优先采用Vault + External‑Secrets‑Operator；
2. etcd必须开启静态加密，这是原生Secret最低安全底线；
3. 优先文件挂载方式注入密钥，减少环境变量使用；
4. 通过RBAC严格限制secret读取权限，普通开发人员禁止读取密钥；
5. 密钥定期轮换，下线资源及时清理废弃Secret；
6. Git仓库只存放ExternalSecret CRD，不存放密钥本身，实现配置GitOps托管。

## 十三、关联文档
1. `authorization.md`：RBAC权限控制；
2. `authentication.md`：ServiceAccount原理；
3. `05‑node‑hardening.md`：节点安全加固；
4. `05‑kubeadm‑init.md`：apiserver启动参数配置；
5. GitOps文档：ArgoCD管理ExternalSecret资源。