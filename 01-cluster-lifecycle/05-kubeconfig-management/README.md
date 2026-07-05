# 05-kubeconfig-management/README.md
## 一、目录概述
本目录独立管理集群 `kubeconfig` 全套配置、用户权限、证书分发、多集群、轮换、安全规范，配套前文部署文档（01~10全流程部署完成后运维使用）。
集群基础信息：
- K8s 版本：v1.32.13 单Master
- Master节点：`k8s-master-01 / 192.168.11.161`
- 私有仓库：`harbor.jinshaoyong.com/k8s`
- CNI：Calico v3.30.4，Pod网段 `10.32.0.0/16`
- CRI：containerd v2.1.5-1

## 二、文档分档功能说明
| 文件 | 核心内容 |
|------|--------|
| 01-kubeconfig-overview.md | kubeconfig 核心作用、集群认证逻辑、三种认证模式概述 |
| 02-kubeconfig-structure.md | kubeconfig yaml三层结构：clusters / users / contexts 完整字段解析 |
| 03-admin-conf.md | `/etc/kubernetes/admin.conf` 管理员配置来源、权限、拷贝到用户目录标准流程 |
| 04-user-kubeconfig.md | 基于CA证书创建自定义普通用户、RBAC绑定、生成独立kubeconfig |
| 05-service-account-kubeconfig.md | ServiceAccount 内置token提取、生成sa专用kubeconfig、后台程序无账号访问集群 |
| 06-context-management.md | 上下文创建/切换/删除/重命名、默认上下文设置 |
| 07-cluster-management.md | 新增/修改/删除集群接入地址、tls证书配置 |
| 08-user-management.md | 用户证书、token、客户端凭证增删改查 |
| 09-kubeconfig-merge.md | 多份kubeconfig文件合并、环境变量 KUBECONFIG 合并逻辑 |
| 10-kubeconfig-export.md | 安全导出、分发kubeconfig、权限控制、worker节点拷贝管理员配置 |
| 11-kubeconfig-security.md | 安全规范：文件权限、证书有效期、禁止明文存储、最小权限原则 |
| 12-kubeconfig-rotation.md | CA证书/用户证书过期轮换、更新kubeconfig内证书字段 |
| 13-multi-cluster.md | 单kubectl管理多套k8s集群、多context快速切换 |
| 14-kubectl-config-cheatsheet.md | `kubectl config` 全常用命令速查清单 |
| 15-troubleshooting.md | kubeconfig连接失败、证书过期、权限不足、context错乱等故障排查 |

## 三、前置依赖
1. `05-kubeadm-init.md` 集群初始化完成，Master存在 `/etc/kubernetes/admin.conf`
2. `03-kubernetes-packages.md` 所有节点kubectl安装完成，bash-completion可用
3. 集群网络Calico就绪，节点状态Ready

## 四、使用顺序建议（标准学习/操作流程）
1. 01-overview → 02-structure 理解原理结构
2. 03-admin-conf 管理员基础配置（必做）
3. 日常运维：06上下文、07集群、08用户管理
4. 权限分层：04自定义用户、05 sa账号
5. 多集群场景：09合并、13多集群管理
6. 交付分发：10导出分发
7. 安全加固：11安全规范 + 12证书轮换
8. 速查手册：14 cheatsheet
9. 异常处理：15故障排查

## 五、全局统一操作规范
1. 所有kubeconfig文件统一存放目录：`/usr/local/src/kubeconfig/`
2. 用户本地配置目录标准路径：`$HOME/.kube/config`
3. 文件权限严格控制：`chmod 600 config`，禁止其他用户读取证书/Token
4. 分发kubeconfig仅走内网scp，禁止明文传输至公网
5. 生产环境遵循最小权限，不直接分发admin.conf给普通运维人员

## 六、上下游文档关联
- 上游：05-kubeadm-init.md（集群生成admin.conf）、07-worker-join.md（节点拷贝kubeconfig）
- 配套运维：08-post-install.md RBAC账号管理
- 故障兜底：10-troubleshooting.md 补充kubeconfig连接异常章节