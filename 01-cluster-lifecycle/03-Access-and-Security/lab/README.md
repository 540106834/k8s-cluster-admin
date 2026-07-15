基于你当前集群状态：

* **单控制平面 Kubernetes v1.32.13**
* **containerd 2.1.5**
* **Calico v3.30.4 BGP**
* **Harbor私有仓库**
* **企业内部生产运维场景**

`03-access-and-security` 实验不需要覆盖所有 Kubernetes 安全特性，而应该围绕**生产管理员每天真正会遇到的问题**设计。

建议重点：

1. kubeconfig 生命周期管理（最高频）
2. RBAC 权限设计（最高频）
3. ServiceAccount + Token（应用访问）
4. Secret 管理（生产必备）
5. TLS证书管理（必须掌握）
6. Harbor认证（你的环境必须）
7. 安全加固（了解即可）
8. 高级认证方式（简单记录）

目录如下：

```text
03-access-and-security-lab/
│
├── README.md
│   # 实验环境说明
│   # Kubernetes v1.32.13
│   # 单Master架构
│   # Calico网络
│   # Harbor仓库
│
│
├── 01-kubeconfig-management/                 # kubeconfig管理（重点）
│
│   ├── 01-kubeconfig-structure.md
│   # kubeconfig结构解析
│   # cluster
│   # user
│   # context
│   # certificate-data
│
│   ├── 02-admin-kubeconfig.md
│   # 管理员kubeconfig管理
│   # /etc/kubernetes/admin.conf
│   # 权限控制
│
│   ├── 03-create-user-kubeconfig.md
│   # 创建普通用户访问配置
│   # openssl生成用户证书
│   # 绑定RBAC权限
│
│   ├── 04-kubeconfig-context.md
│   # 多环境context管理
│   # dev/test/prod切换
│
│   └── 05-kubeconfig-troubleshooting.md
│       # 常见问题
│       # certificate expired
│       # connection refused
│       # forbidden
│
│
├── 02-rbac-management/                       # RBAC权限管理（重点）
│
│   ├── 01-rbac-basic.md
│   # Authentication到Authorization流程
│   # User
│   # Group
│   # ServiceAccount
│
│   ├── 02-namespace-permission-design.md
│   # Namespace级权限设计
│   # Role
│   # RoleBinding
│
│   ├── 03-cluster-permission-design.md
│   # 集群管理员权限
│   # ClusterRole
│   # ClusterRoleBinding
│
│   ├── 04-dev-user-permission.md
│   # 模拟研发账号
│   # 只能操作指定Namespace
│
│   ├── 05-rbac-audit.md
│   # 权限检查
│   # kubectl auth can-i
│   # 权限审计
│
│   └── 06-rbac-troubleshooting.md
│       # forbidden排查流程
│
│
├── 03-serviceaccount-management/              # ServiceAccount管理（重点）
│
│   ├── 01-create-serviceaccount.md
│   # 创建应用账号
│
│   ├── 02-serviceaccount-token.md
│   # Token机制
│   # BoundServiceAccountTokenVolume
│
│   ├── 03-pod-api-access.md
│   # Pod访问Kubernetes API
│   # curl apiserver
│
│   └── 04-serviceaccount-security.md
│       # 禁止默认Token自动挂载
│       # automountServiceAccountToken
│
│
├── 04-secret-management/                      # Secret管理（重点）
│
│   ├── 01-secret-basic.md
│   # Opaque Secret
│   # Base64编码
│
│   ├── 02-secret-volume.md
│   # Secret挂载文件
│
│   ├── 03-secret-env.md
│   # Secret作为环境变量
│
│   ├── 04-harbor-imagepullsecret.md
│   # Harbor私有仓库认证
│   # docker-registry Secret
│   # imagePullSecrets
│
│   ├── 05-tls-secret.md
│   # Ingress HTTPS证书
│
│   └── 06-secret-encryption.md
│       # etcd Secret加密
│       # 生产了解
│
│
├── 05-certificate-management/                 # 证书管理（重点）
│
│   ├── 01-cluster-certificate-check.md
│   # kubeadm证书检查
│   # kubeadm certs check-expiration
│
│   ├── 02-apiserver-certificate.md
│   # apiserver证书
│   # SAN配置
│
│   ├── 03-kubelet-certificate.md
│   # kubelet client/server证书
│   # 自动轮换
│
│   ├── 04-certificate-renew.md
│   # kubeadm renew
│
│   └── 05-certificate-failure-recovery.md
│       # 证书过期恢复流程
│
│
├── 06-harbor-security/                        # Harbor安全集成（重点）
│
│   ├── 01-harbor-authentication.md
│   # Harbor账号认证
│
│   ├── 02-imagepullsecret-management.md
│   # Namespace绑定Secret
│
│   ├── 03-serviceaccount-imagepull.md
│   # ServiceAccount默认镜像认证
│
│   └── 04-image-pull-troubleshooting.md
│       # ImagePullBackOff排查
│
│
├── 07-security-hardening/                     # 安全加固（了解）
│
│   ├── 01-api-server-security.md
│   # anonymous-auth
│   # audit-log
│
│   ├── 02-pod-security-standard.md
│   # Pod Security Admission
│   # baseline/restricted
│
│   └── 03-networkpolicy-basic.md
│       # Calico NetworkPolicy基础
│
│
├── 08-advanced-authentication/                # 高级认证（简单）
│
│   ├── 01-oidc.md
│   # 企业SSO认证
│
│   ├── 02-ldap.md
│   # 企业账号体系集成
│
│   └── 03-cloud-iam.md
│       # 云厂商IAM
│
│
└── 09-production-troubleshooting/             # 生产故障案例（重点）
│
    ├── 01-kubectl-access-denied.md
    # kubectl forbidden排查
    
    ├── 02-kubeconfig-invalid.md
    # kubeconfig失效
    
    ├── 03-certificate-expired.md
    # 集群证书过期
    
    ├── 04-secret-not-found.md
    # Secret不存在
    
    └── 05-imagepull-failed.md
        # Harbor拉取失败
```

### 实验优先级

| 模块             | 重要度   | 原因          |
| -------------- | ----- | ----------- |
| kubeconfig     | ★★★★★ | 管理员入口，生产必用  |
| RBAC           | ★★★★★ | 企业权限核心      |
| ServiceAccount | ★★★★★ | 应用访问K8s API |
| Secret         | ★★★★★ | 业务配置、密码、证书  |
| Harbor认证       | ★★★★★ | 你的环境实际使用    |
| Certificate    | ★★★★☆ | 集群维护必须      |
| NetworkPolicy  | ★★★☆☆ | 安全隔离需要      |
| OIDC/LDAP      | ★★☆☆☆ | 大型企业场景      |
| Static Token   | ★☆☆☆☆ | 历史方案        |

这个目录更符合**Kubernetes生产管理员/SRE岗位能力模型**，不会陷入大量低频安全机制。你当前集群环境可以直接逐项实施。
