# 07-production-checklist.md
## 一、文档基础信息
- 归属目录：`06-daily-operations/`
- 前置阅读：00~06 全套日常运维文档、集群安全/存储/网络/审计文档
- 集群基准：Kubernetes v1.32.13、OIDC认证、etcd静态加密、CSI存储、Calico网络策略、审计日志、GitOps流水线
- 环境分层：DEV本地 / FAT测试 / UAT预生产 / PROD生产
- 核心覆盖：发布前预校验清单、每日自动化巡检项、每周人工巡检、月度深度安全巡检、故障分级处置标准、巡检异常闭环流程、巡检记录归档规范

## 二、巡检整体分层框架
1. **发布前置校验（每次变更必执行）**：资源、存储、网络、权限、备份、镜像、准入校验
2. **每日自动化巡检（告警驱动）**：组件状态、资源水位、审计异常、备份任务、证书预警
3. **每周人工巡检**：冗余权限、废弃资源、网络策略、镜像漏洞、日志采集状态
4. **月度全维度深度巡检**：证书轮换、etcd数据校验、权限全面梳理、全集群漏洞扫描、灾备恢复演练

## 三、生产发布前标准化校验清单（所有变更强制执行）
### 1. 资源与负载校验
1. `kubectl auth can-i` 校验当前账号拥有对应资源操作权限；
2. dry-run模拟执行变更，确认无意外删除资源；
3. 检查Deployment/StatefulSet资源limits/requests配置完整，无缺失LimitRange违规Pod；
4. 镜像禁止latest标签，仅内网Harbor固定版本Tag；
5. 确认副本数充足，发布期间可承载流量，避免单副本单点故障。

### 2. 存储校验
1. 底层存储池剩余容量≥20%，防止扩容/发布IO阻塞；
2. PVC存储Quota未达上限，无存储资源超限告警；
3. 核心数据库已执行当日逻辑备份+CSI快照；
4. NFS/SSD存储类无磁盘只读、inode耗尽告警。

### 3. 网络安全校验
1. NetworkPolicy白名单配置完整，无全开放高危策略；
2. Ingress仅内网/指定源IP可访问，无0.0.0.0无限制放行；
3. DNS、Harbor出站白名单正常，无网络策略拦截。

### 4. 安全校验
1. Pod完整配置Restricted安全上下文，无特权容器、root运行；
2. 数据库、仓库密钥使用Secret，无明文硬编码YAML；
3. 无新增高权限ClusterRoleBinding，无cluster-admin长期绑定；
4. 证书剩余有效期＞7天，无即将过期预警。

### 5. 观测与兜底校验
1. 审计告警通道正常，可接收高危操作通知；
2. 备份CronJob无失败记录，临时可suspend暂停规避IO打满；
3. 业务低峰窗口执行发布，提前错开批量备份、快照任务。

## 四、每日自动化巡检清单（监控平台自动告警）
### 1. 控制平面组件巡检
1. kube-apiserver/controller-manager/scheduler/etcd 全部Pod Running；
2. etcd端口2379/2380通信正常，无磁盘满告警；
3. 集群证书剩余7天内自动预警。

### 2. 系统组件巡检（kube-system）
1. CSI-node、Calico-node、Ingress-controller、CoreDNS、Metrics-server无CrashLoopBackOff；
2. Filebeat审计日志采集正常，无日志丢失、采集失败。

### 3. 资源水位巡检
1. 节点CPU/内存使用率＞70%预警，＞85%高危告警；
2. PVC/PV磁盘使用率＞80%预警，＞90%阻断写入告警；
3. Namespace ResourceQuota存储/CPU内存接近上限预警。

### 4. 备份与快照巡检
1. 数据库定时CronJob执行状态successful，无连续失败；
2. VolumeSnapshot每日快照创建成功，无ReadyToUse=false失败快照；
3. 过期快照、备份文件自动清理机制正常。

### 5. 安全审计巡检
1. 大量403越权访问、删除资源、修改Secret/RBAC实时告警；
2. 准入控制拦截特权Pod、违规镜像创建事件告警；
3. FAT命名空间访问PROD网段NetworkPolicy阻断异常告警。

## 五、每周人工巡检清单（运维人工执行，留存记录）
1. 权限清理：删除闲置ClusterRoleBinding、离职人员OIDC权限绑定；
2. 存储清理：过期快照、废弃PVC、无用备份文件清理；
3. 网络策略巡检：排查包含`0.0.0.0/0`全开放端口的高危NetworkPolicy；
4. 镜像漏洞：内网Harbor高危漏洞镜像清单同步业务负责人修复；
5. 负载冗余：长期0副本Deployment、闲置StatefulSet梳理下线；
6. 日志校验：审计日志无中断，脱敏正常无密钥明文输出；
7. 证书复核：确认下周到期客户端证书完成轮换。

## 六、月度深度安全&集群巡检清单（输出正式巡检报告）
### 1. 证书体系
1. 全集群客户端、组件证书过期时间完整核查，完成到期轮换；
2. 集群根CA备份校验，确认离线加密备份文件完好。

### 2. RBAC权限深度梳理
1. 不存在全局长期cluster-admin账号，所有高危绑定解绑；
2. 开发账号仅拥有对应环境只读权限，无delete/modify动词；
3. ServiceAccount仅绑定最小粒度Role，default SA无集群权限。

### 3. 容器运行安全校验
1. 所有UAT/PROD命名空间开启Restricted PSS，无违规特权Pod；
2. 核查所有容器securityContext：runAsNonRoot、drop ALL capabilities、只读根文件系统。

### 4. 存储全维度巡检
1. 存储池磁盘、inode使用率完整统计；
2. 备份恢复演练：从快照恢复数据库验证备份可用性；
3. NFS/SSD StorageClass配置规范核对，无废弃SC。

### 5. 网络隔离校验
1. 多环境网段阻断验证：FAT Pod无法连通UAT/PROD中间件；
2. 所有NS default-deny-ingress策略存在，无命名空间旁路。

### 6. 密钥与镜像巡检
1. 核心业务密钥按月轮换记录核对，逾期补轮换；
2. 全集群镜像扫描，Critical/High漏洞镜像推动业务修复闭环。

### 7. 审计复盘
1. 月度审计日志导出，梳理越权、删除、密钥变更异常操作；
2. 优化告警规则，屏蔽无效误报，新增遗漏高危操作告警。

## 七、故障分级处置规范
### 一级（紧急高危，短信+消息双告警，24h运维响应）
触发场景：
1. 数据库/StatefulSet批量删除、生产PVC批量删除；
2. 密钥/镜像仓库Secret创建/更新/删除；
3. NetworkPolicy全局默认策略被删除；
4. 集群证书7天内过期未轮换；
5. 大量403暴力越权访问、特权容器批量创建。
处置流程：
1. 立即暂停业务写入、暂停定时备份抢占IO；
2. 阻断测试环境访问生产网络；
3. 审计日志溯源操作人、操作时间、影响范围；
4. 双人协同执行回滚（快照/备份/RBAC恢复）；
5. 24小时输出安全故障复盘报告，优化巡检规则。

### 二级（风险告警，消息平台通知，工作时段处置）
触发场景：
1. 普通Deployment/Service变更、Ingress规则修改；
2. 资源水位70%~85%预警、存储池容量不足；
3. 快照创建失败、单次备份Job执行失败；
4. 镜像存在高危漏洞未修复。
处置流程：
1. 记录告警日志，业务低峰窗口清理/扩容资源；
2. 推动业务修复漏洞、调整资源规格。

### 三级（普通信息，仅日志留存，无需人工干预）
普通读操作、开发只读查询、常规发布无异常，仅日志留存90天。

## 八、DEV/FAT/UAT/PROD 巡检差异化基线
### DEV本地
无标准化巡检，自用调试，无需记录报告。
### FAT测试
1. 仅每日自动化基础告警，无月度深度巡检；
2. 每周人工简单清理闲置资源即可；
3. 发布前校验简化，无需双人复核。

### UAT预生产
1. 巡检基线完全对齐生产，仅少量权限放宽；
2. 每日自动化告警、每周人工清理冗余资源；
3. 月度完整巡检，输出简化巡检报告。

### PROD生产（强制约束）
1. 发布前完整校验清单逐条核对，双人复核；
2. 每日自动化告警实时响应，不允许延迟处置一级告警；
3. 每周人工巡检，月度完整深度安全巡检并输出归档报告；
4. 所有巡检、变更、故障处置记录统一归档存储90天；
5. 每月执行一次数据恢复演练，验证快照/备份有效性。

## 九、巡检运维常用命令
```bash
# 发布前权限预校验
kubectl auth can-i delete statefulset mysql -n prod --as=oidc:user:zhangsan@example.com

# 查看集群证书过期时间
kubeadm certs check-expiration

# 检索审计403越权访问记录
jq '.responseStatus.code == "403"' /var/log/k8s/audit/audit.log

# 查找无标准安全上下文的违规Pod
kubectl get pods -n prod -o json | jq '.items[] | select(.spec.containers[].securityContext.allowPrivilegeEscalation != false)'

# 查看过期快照、废弃PVC
kubectl get volumesnapshots,pvc -n prod --sort-by=.metadata.creationTimestamp

# 临时暂停备份CronJob防止IO打满存储
kubectl patch cronjob mysql-backup -n prod -p '{"spec":{"suspend":true}}'
```

## 十、生产巡检最佳实践
1. 分层巡检：发布前置校验、每日自动化告警、每周人工清理、月度深度安全复盘；
2. 所有高危操作、巡检记录、故障处置工单统一Git/日志平台归档，可追溯；
3. 严格区分三级告警分级，一级高危故障即时响应，避免数据丢失；
4. 每月执行灾备恢复演练，验证快照、逻辑备份可用；
5. 遵循最小权限、深度防御原则，巡检中及时清理冗余高权限账号；
6. 存储、网络、权限、证书、镜像多维度全覆盖，不留安全盲区；
7. 巡检发现的风险建立台账，限期闭环整改，次月复查。

## 十一、关联文档
1. 日常运维总览：`06-daily-operations/00-README.md` 运维操作分层规范
2. 工作负载操作：`06-daily-operations/03-workload-operations.md` 发布变更流程
3. 存储运维：`04-storage-management/` PV/PVC扩容、快照巡检项
4. 安全管理全套：`05-security-management/` 证书、RBAC、准入、审计巡检标准
5. 网络安全：`03-network-management/06-network-policy.md` 网络策略月度校验清单
6. 存储故障排错：`04-storage-management/06-storage-troubleshooting.md` 存储池满、IO阻塞故障处置SOP
7. 集群备份：`etcd-backup.md` 巡检发现资源异常后etcd快照回滚流程