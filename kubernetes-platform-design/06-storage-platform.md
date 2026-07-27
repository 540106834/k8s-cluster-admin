# kubernetes-platform-design/06-storage-platform.md
## 文档元信息
- 模块：存储平台体系
- 优先级：★★★★★ 有状态业务核心底座
- 依赖文档：00-platform-overview.md、02-namespace-resource-governance、04-application-delivery
- 关联模块：08-secret-management、07-observability、12-cluster-lifecycle-management、13-disaster-recovery、15-compliance-audit
- 适用角色：平台SRE、存储运维、DBA、CSI开发、多租户架构师

## 1. 模块定位与核心目标
### 1.1 定位
归属三层「集群资源管控域-存储持久化域」，统一管理K8s持久化存储全链路：**存储池规划、StorageClass分层、CSI驱动、PV/PVC生命周期、快照、克隆、备份恢复、数据容灾**。
为无状态/有状态业务提供标准化持久化能力，隔离底层存储硬件差异，配合Namespace资源配额实现租户存储容量隔离，是数据库、缓存、消息队列等有状态负载运行基础。

### 1.2 核心目标
1. 屏蔽底层存储硬件异构，统一CSI标准接口，一套存储资源模型适配块/文件/对象存储
2. 按环境、业务负载分层定义StorageClass，性能、容量、冗余等级差异化管控
3. 租户存储容量强隔离，配合ResourceQuota限制单团队PVC总占用，防止存储资源耗尽
4. 全生命周期自动化：PVC创建、扩容、快照、克隆、备份、回收、销毁闭环
5. 数据安全闭环：定时快照、跨集群备份、加密存储、数据销毁机制
6. 存储资源可观测，容量使用率、IOPS、延迟、故障告警全覆盖
7. 杜绝本地hostPath裸盘挂载，统一CSI持久化存储标准

### 1.3 解决业务痛点
- 业务随意创建大容量PVC，耗尽集群存储池，引发全集群存储IO阻塞
- 存储类型无区分，数据库使用低速文件存储，引发性能抖动
- 无统一快照备份策略，数据库故障丢失数据，RPO/RTO不达标
- hostPath宿主机本地存储无法迁移，节点故障数据丢失，无容灾能力
- PVC删除后底层存储未自动回收，存储资源持续泄漏
- 存储凭证、存储加密密钥分散管理，无统一安全管控
- 存储用量无分团队计量，无法分摊存储硬件成本

## 2. 存储分层架构（三层解耦）
```
业务层：PVC/StatefulSet挂载声明 → 平台存储抽象层：StorageClass、快照、克隆、扩容策略 → 底层基础设施层：CSI驱动、块存储/文件存储/对象存储硬件池
```
1. **业务声明层**：PVC、临时存储emptyDir、ConfigMap挂载（只读配置）
2. **平台抽象层**：StorageClass、SnapshotClass、VolumeSnapshot、VolumeClone、扩容策略、存储配额
3. **底层驱动层**：标准化CSI驱动、存储网关、存储硬件集群、加密层

## 3. StorageClass 标准化分层模型（按环境+负载区分）
全局统一预置6类StorageClass，禁止业务自定义StorageClass，准入控制器拦截非法SC绑定
| StorageClass名称 | 存储介质 | 冗余等级 | 适用环境 | 适用负载 | 核心特性 |
| --- | --- | --- | --- | --- | --- |
| sc-dev-file | 分布式文件存储 | 单副本 | dev/test | 开发临时中间件、日志缓存 | 低性能，自动回收，无快照 |
| sc-test-block | 高性能块存储 | 2副本 | test/staging | 测试数据库、缓存 | 支持快照，保留7天快照 |
| sc-std-prod-block | 企业级块存储 | 3副本 | prod | MySQL、Redis、业务核心数据 | 高IO、定时快照、支持扩容、跨节点迁移 |
| sc-hiops-prod-block | NVMe高速块存储 | 3副本 | prod | 高并发交易库、时序数据库 | 低延迟、高IOPS，配额严格管控 |
| sc-archive-file | 大容量归档文件存储 | 3副本 | all | 日志、离线备份、归档文件 | 大容量低成本，限速IO |
| sc-object-s3 | 对象存储 | 多副本 | all | 文件上传、离线备份、镜像归档 | 对接S3兼容网关，用于备份系统 |

### 全局StorageClass强制约束
1. 生产有状态数据库必须绑定`sc-std-prod-block`/`sc-hiops-prod-block`，禁止文件存储；
2. dev环境仅允许sc-dev-file，如需块存储需工单审批；
3. 所有SC默认开启**存储加密**，底层磁盘落盘加密；
4. Retain策略统一管控：生产PVC删除保留底层存储，测试PVC自动删除回收。

## 4. PV/PVC 全生命周期管控
### 4.1 PVC 标准化规范
1. 命名规范：`pvc-{应用名}-{数据用途}`，强制携带env/team/app标准标签；
2. 容量约束：受Namespace ResourceQuota管控，单PVC最大容量由StorageClass限制；
3. 访问模式：
   - 数据库：`ReadWriteOnce`（块存储独占）
   - 多实例共享文件：`ReadWriteMany`（仅归档文件SC允许）
4. 扩容能力：所有生产SC开启在线扩容，无需停机迁移数据；
5. 禁止静态PV手动创建，统一StorageClass动态供给。

### 4.2 PVC 生命周期流程
1. 创建：GitOps提交PVC资源 → 校验容量Quota、SC合法性 → CSI自动创建PV；
2. 使用：StatefulSet/Deployment挂载，监控IO、容量使用率；
3. 扩容：提交工单在线扩容，CSI执行底层存储扩容；
4. 快照：定时自动快照/手动快照，用于故障回滚；
5. 销毁：PVC删除触发校验：
   - dev/test：自动删除底层存储，释放容量；
   - prod：PVC删除后PV保留7天，7天后自动清理，支持恢复误删数据。

### 4.3 存储配额联动（02-namespace-resource-governance）
ResourceQuota管控两类存储资源：
1. `requests.storage`：Namespace总存储容量上限；
2. `persistentvolumeclaims`：Namespace最大PVC数量；
使用率80%触发告警，100%拒绝新建PVC。

## 5. 快照、克隆与数据备份（容灾核心能力，联动13-disaster-recovery）
### 5.1 VolumeSnapshot 快照体系
1. 全局统一SnapshotClass，与StorageClass一一绑定；
2. 自动快照策略：
   - 生产数据库：每日凌晨全量快照，保留7份；
   - 测试环境：每日快照，保留3份；
3. 支持快照克隆：基于快照快速新建PVC，用于数据复制、压力测试；
4. 快照独立占用存储容量，计入租户存储配额。

### 5.2 跨集群备份方案
1. 本地快照短期回滚（RPO=1天）；
2. 定时将快照数据同步至对象存储sc-object-s3归档（RPO=24h）；
3. 跨区域备份：核心业务每日同步至备用集群对象存储，满足异地容灾；
4. 备份保留周期：测试30天、预发90天、生产1年。

### 5.3 数据恢复流程
1. 自助恢复工单：选择快照、目标Namespace、容量；
2. 平台自动克隆快照生成新PVC，挂载至临时实例校验数据；
3. 校验通过后切换业务挂载，完整恢复流程审计留痕。

## 6. 存储安全管控
### 6.1 静态数据加密
1. 底层存储落盘加密，加密密钥统一托管Vault（08-secret-management）；
2. 生产块存储强制开启，dev/test可选关闭；
3. 密钥自动轮换，无需人工干预。

### 6.2 访问权限隔离
1. PVC归属Namespace隔离，跨Namespace无法挂载其他团队PVC；
2. 存储后端认证凭证（存储网关账号、S3 AK/SK）统一ExternalSecret注入，禁止明文写入YAML；
3. 准入控制器拦截hostPath、localPV本地存储，杜绝节点绑定数据风险。

### 6.3 数据销毁规范
1. PVC正式销毁时，底层存储执行数据擦除，而非仅删除元数据；
2. 合规审计记录销毁时间、操作人、数据容量，留存180天。

## 7. 存储可观测体系（联动07-observability-platform）
### 7.1 采集指标维度
1. 容量指标：PVC总容量、已使用、使用率、快照占用容量；
2. 性能指标：读/写IOPS、读写延迟、块设备丢包、队列深度；
3. 生命周期指标：待回收PV数量、快照数量、扩容事件、挂载失败次数。

### 7.2 分级告警规则
1. P1：PVC使用率≥95%、存储IO延迟突增、CSI驱动异常离线；
2. P2：使用率≥80%、快照创建失败、备份同步中断；
3. P3：闲置PVC（30天无挂载）、存储配额即将耗尽。

### 7.3 存储成本计量
按namespace/team/env统计月度存储占用容量，区分块存储/文件/对象存储单价，输出资源账单。

## 8. CSI插件标准化运维（11-addon-management）
1. 统一部署官方标准CSI驱动，不使用第三方自研驱动；
2. CSI Controller多副本高可用，节点DaemonSet全节点部署；
3. CSI操作日志全量采集：PVC创建、扩容、快照、删除事件；
4. CSI版本跟随集群生命周期统一升级（12-cluster-lifecycle-management）。

## 9. 落地强制禁忌规范
1. 禁止业务使用hostPath、localPV宿主机本地持久化存储；
2. 禁止生产数据库绑定文件型StorageClass；
3. 禁止手动创建静态PV，所有存储供给依赖StorageClass动态创建；
4. 禁止PVC不配置资源标签，禁止跨Namespace挂载PVC；
5. 禁止关闭生产存储落盘加密；
6. 禁止无快照、无备份策略运行生产有状态服务；
7. 禁止删除PV/PVC前无数据确认，生产PVC直接删除不保留7天缓冲期。

## 10. 跨模块协作边界
1. 02-namespace-resource-governance：Namespace创建配置存储Quota，隔离租户存储容量；
2. 04-application-delivery：StatefulSet统一绑定标准化StorageClass，准入校验PVC合规性；
3. 08-secret-management：存储网关AK/SK、加密密钥存入Vault，通过ExternalSecret下发；
4. 07-observability：采集存储容量、IO性能指标，统一告警大盘；
5. 11-addon-management：CSI驱动、SnapshotClass作为平台基础插件统一运维；
6. 13-disaster-recovery：快照、跨集群对象存储备份作为核心容灾手段；
7. 14-platform-engineering：自助门户提供PVC扩容、数据快照恢复工单；
8. 15-compliance-audit：PVC创建、扩容、销毁、数据恢复操作全量审计日志留存。