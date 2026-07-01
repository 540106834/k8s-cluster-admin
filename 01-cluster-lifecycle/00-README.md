# 01-cluster-lifecycle README.md
## 一、模块概述
本目录为生产级 Kubernetes 集群全生命周期运维手册，覆盖**集群规划、部署、日常运维、升级、灾备、迁移、下线**完整闭环，全部文档基于企业生产落地场景编写，摒弃纯理论演示，所有操作附带校验命令、风险点、回滚方案与生产避坑规范。

适用人群：集群SRE、平台运维、云原生工程师；适配自建裸金属/虚拟机K8s集群（kubeadm、RKE2两套主流部署方案），兼容单控制平面、多Master高可用架构。

## 二、文档目录与核心定位
| 文档名称 | 核心作用 | 生产价值 |
|--------|--------|--------|
| cluster-planning.md | 集群上线前标准化规划模板 | 避免后期网络/IP/资源/版本架构重构，提前锁定HA、CNI、存储、安全基线 |
| cluster-installation.md | kubeadm / RKE2 完整部署实操 | 可直接复制的离线部署脚本、内核调优、系统基线、初始化校验流程 |
| control-plane-management.md | Master控制面运维 | apiserver/controller-manager/scheduler/etcd组件监控、故障排查、资源限流、高可用调优 |
| worker-node-management.md | 工作节点通用运维 | 节点内核、容器运行时、kubelet故障、资源挤压、污点容忍、调度策略管控 |
| node-join.md | 节点扩容接入集群 | 新旧版本token有效期处理、离线节点接入、多网卡节点注册、接入后校验流程 |
| node-remove.md | 节点安全下线 | 驱逐Pod、排空节点、清理集群资源、主机残留清理、异常节点强制移除方案 |
| kubernetes-upgrade.md | 集群版本滚动升级 | 控制面→节点分阶段升级、跨小/大版本升级步骤、升级中断回滚、离线升级镜像处理 |
| certificate-renewal.md | 集群证书全流程更新 | k8s根证书、apiserver证书、kubelet证书轮换、过期应急修复、自动续期配置 |
| etcd-backup.md | etcd定时备份生产方案 | 定时备份脚本、快照压缩、备份保留策略、权限管控、备份可用性校验 |
| etcd-restore.md | etcd数据灾难恢复 | 单/多Master集群快照恢复、数据丢失修复、恢复后集群一致性校验、故障复盘流程 |
| cluster-migration.md | 跨集群业务迁移 | 同版本集群迁移、新旧集群双写过渡、PV数据迁移、服务无中断切换、流量切回策略 |
| cluster-decommission.md | 集群整体下线销毁 | 业务分批下线、PV/存储资源回收、命名空间清理、集群资源释放、主机格式化清理 |

## 三、生产使用规范
### 3.1 操作前置约束
1. 所有变更操作必须在**维护窗口**执行，提前预留回滚时间；etcd备份、集群升级、证书轮换等高风险操作需双人复核。
2. 文档内所有命令默认适配 Linux CentOS / Ubuntu 生产服务器，离线环境需提前预拉取镜像、离线rpm/deb包。
3. HA集群操作遵循**滚动变更**原则，禁止同时操作全部Master节点，单Master变更后必须完成集群健康校验再执行下一步。
4. 任何破坏性操作（节点删除、etcd恢复、集群销毁）执行前强制执行etcd全量快照备份。

### 3.2 通用集群健康校验标准（全流程通用）
执行任意生命周期操作后，必须完成以下校验，集群状态正常才可结束操作：
```bash
# 1. 控制面组件健康
kubectl get cs
# 2. 节点就绪状态
kubectl get nodes
# 3. 集群Pod无异常
kubectl get pods -n kube-system
# 4. etcd集群健康
etcdctl endpoint health --cacert=/etc/kubernetes/pki/ca.crt
# 5. apiserver连通性测试
kubectl api-resources
```

### 3.3 风险分级说明
- 低风险：节点新增、常规节点巡检、备份执行、证书预检查
- 中风险：节点移除、单Master配置调整、小版本迭代升级
- 高风险：etcd恢复、集群大版本升级、证书全量轮换、集群迁移、集群销毁
高风险操作单独文档内置**回滚预案**，操作前完整阅读回滚步骤。

## 四、部署方案选择指引
1. **kubeadm**：中小企业自建标准方案，自由度高，适配自定义CNI、存储、系统基线，文档内置1.24~1.30多版本适配步骤；
2. **RKE2**：大规模标准化集群、安全合规场景，内置容器运行时、自动证书管理，适配边缘、裸机大规模批量部署。

## 五、目录扩展规划
后续迭代补充文档规划：
1. cluster-disaster-recovery.md：集群整体故障应急（Master全部宕机、etcd脑裂、apiserver不可用）
2. cluster-version-compatibility.md：K8s各版本兼容矩阵、弃用API预警、版本选型建议
3. cluster-cost-optimize.md：集群节点资源规划、闲置节点回收、调度成本优化

## 六、配套依赖目录
本模块依赖仓库其他目录能力：
- `02-network/`：集群网络规划、CNI部署、负载均衡配套
- `03-security/`：集群RBAC、安全基线、证书加固
- `04-monitor/`：集群组件监控、节点告警、etcd监控大盘
- `05-storage/`：集群持久化存储规划（与集群迁移、节点下线联动）

## 七、联系方式与更新规范
1. 文档变更遵循GitOps流程，所有操作脚本、参数修改提交PR并附变更说明；
2. 集群版本迭代同步更新对应文档，过期版本操作步骤标注废弃说明；
3. 线上故障可同步更新对应文档补充坑点、应急修复方案。