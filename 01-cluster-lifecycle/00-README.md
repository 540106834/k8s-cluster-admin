01-cluster-lifecycle                    # Kubernetes 集群生命周期管理
│
├── 01-planning                         # 集群规划阶段：设计集群架构和基础资源
│   ├── 01-architecture.md              # 集群整体架构设计：HA架构、Control Plane、Worker节点规划
│   ├── 02-network.md                   # 集群网络规划：PodCIDR、ServiceCIDR、DNS域名规划
│   ├── 03-resource.md                  # 集群资源规划：CPU、Memory、Storage容量评估
│   └── 04-component-selection.md       # 核心组件选型：Kubernetes版本、Runtime、CNI、CSI
│
├── 02-bootstrap                        # 集群初始化阶段：从裸机到可运行Kubernetes
│   ├── 01-node-preparation.md          # 节点初始化：Linux优化、Kernel参数、Swap关闭、系统依赖
│   ├── 02-container-runtime.md         # 容器运行时部署：containerd、runc、crictl安装配置
│   ├── 03-kubernetes-install.md        # Kubernetes组件安装：kubeadm、kubelet、kubectl部署
│   ├── 04-cluster-init.md              # 集群初始化：kubeadm init、Control Plane启动流程
│   ├── 05-network-plugin.md            # CNI网络部署：Calico、Cilium安装和网络验证
│   └── 06-validation.md                # 集群初始化验证：节点状态、组件状态、网络连通性检查
│
├── 03-access-and-security               # 集群访问和安全控制
│   ├── 01-kubeconfig.md                # kubeconfig管理：管理员、用户访问配置和生命周期管理
│   ├── 02-authentication.md             # 身份认证机制：Certificate、ServiceAccount、Token认证
│   ├── 03-certificate-management.md     # Kubernetes证书生命周期管理：检查、续签、轮换、故障恢复
│   ├── 04-authorization.md              # 权限控制机制：RBAC、Role、ClusterRole设计
│   └── 05-secret-management.md          # Secret管理：应用密钥、镜像仓库认证、敏感信息管理
│
├── 04-node-management                   # Kubernetes节点生命周期管理
│   ├── 01-node-lifecycle.md             # 节点生命周期：Node加入、删除、替换流程
│   ├── 02-maintenance.md                # 节点维护操作：cordon、drain、uncordon使用场景
│   ├── 03-scheduling.md                 # Pod调度控制：Label、Taint、Affinity、Topology规则
│   └── 04-troubleshooting.md            # 节点故障排查：NotReady、资源异常、kubelet问题
│
├── 05-resource-management                # Kubernetes资源生命周期管理
│   ├── 01-namespace.md                  # Namespace管理：创建、隔离、回收和规范
│   ├── 02-workload.md                   # 工作负载管理：Deployment、StatefulSet、DaemonSet
│   ├── 03-configuration.md              # 应用配置管理：ConfigMap、Secret、环境变量配置
│   ├── 04-resource-control.md           # 资源控制：Request、Limit、ResourceQuota、LimitRange
│   └── 05-network-policy.md             # 网络安全策略：Namespace隔离和流量访问控制
│
├── 06-cluster-operation                 # 集群日常运行维护
│   ├── 01-health-check.md               # 集群健康检查：API Server、ETCD、Scheduler、Controller
│   ├── 02-capacity-management.md        # 容量管理：CPU、Memory、Storage、Pod数量分析
│   ├── 03-maintenance.md                # 日常维护：镜像清理、无效资源清理、证书检查
│   └── 04-operation-report.md           # 运维报告：巡检结果、资源趋势、风险记录
│
├── 07-upgrade-and-migration              # 集群升级、备份和迁移管理
│   ├── 01-upgrade.md                    # 集群升级：Kubernetes、Runtime、CNI组件升级流程
│   ├── 02-backup-recovery.md            # 数据保护：ETCD备份、资源备份、PV恢复方案
│   ├── 03-migration.md                  # 集群迁移：资源迁移、数据迁移、流量切换
│   └── 04-decommission.md               # 集群下线：业务清理、节点清理、环境回收
│
└── 08-standards                         # Kubernetes企业运维规范
    ├── 01-naming.md                     # 命名规范：Cluster、Namespace、Node、Resource命名规则
    ├── 02-label-annotation.md           # 标签规范：Label、Annotation设计和使用规范
    ├── 03-image.md                      # 镜像规范：Registry、Repository、Tag管理规范
    ├── 04-resource.md                   # 资源规范：Request、Limit、Quota标准配置
    ├── 05-security.md                   # 安全规范：RBAC、ServiceAccount、Secret安全要求
    └── 06-operation.md                  # 运维流程规范：发布、变更、故障、审计流程