# decommission-application.md
# 业务应用完整永久下线、资产销毁标准化运维手册
## 一、文档定位
本文针对业务版本淘汰、项目下线、产品线关停等场景，提供**流量切断 → 缩容排空 → 删除全量K8s资源 → 销毁镜像/存储/权限/监控日志配置 → 台账归档**完整闭环永久下线流程；区分无状态Java微服务、有状态中间件两套操作规范，属于不可逆操作，执行前必须复核备份，配套项目交付、资源策略、镜像仓库、权限文档。  
前置依赖：  
disable-application-service.md｜临时关停流量入口流程  
scale-down-application.md｜业务副本缩容操作  
build-harbor-registry.md｜私有镜像仓库项目管理  
deliver-developer-access.md｜开发人员RBAC权限回收  
build-storage-platform.md｜NFS/块存储数据清理  
下游关联：create-project-workspace.md、validate-project-environment.md  

## 二、下线前置约束与风险红线
### 2.1 适用场景（满足其一执行完整退役）
1. 产品线永久淘汰，不再迭代、无任何访问流量
2. 项目业务迁移至新集群/新系统，旧环境完全废弃
3. 业务重构重构完成，旧版本永久停用，无需保留任何资源
4. 测试环境临时项目用完废弃，释放集群资源

### 2.2 严禁直接操作风险说明
1. 禁止未排空流量、未缩容直接删除Namespace：残留PV、Harbor权限、监控配置、RBAC垃圾资源
2. 有状态MySQL/Redis等必须提前完整备份数据，下线后数据无法找回
3. PROD生产业务下线必须留存完整操作归档、数据备份快照，满足审计要求
4. 下线不可逆，删除PVC/数据库数据后无法恢复，执行前双人复核

### 2.3 下线前置检查项（全部通过方可执行）
1. 业务流量全量切断：Ingress/LB/内部Service已关闭，监控QPS归零72小时（生产）
2. 数据备份完成：NFS/块存储PVC业务数据、数据库全量快照备份留存
3. 上下游依赖确认：无其他业务调用该服务，下游已切换新接口
4. 项目负责人、运维负责人双人审批下线工单
5. 开发人员权限、Harbor机器人账号、监控ServiceMonitor全部梳理待回收

## 三、整体下线7大阶段流程
1. 阶段1：永久关停所有流量入口（disable-application-service.md）
2. 阶段2：分批缩容排空业务Pod，停止所有运行实例
3. 阶段3：删除项目所有业务K8s资源（应用、配置、密钥、网络策略）
4. 阶段4：持久化存储PVC数据销毁、存储资源回收
5. 阶段5：配套平台资源清理（Harbor镜像、监控、日志、RBAC权限）
6. 阶段6：（可选）废弃整个业务Namespace
7. 阶段7：资产台账、工单、备份记录归档闭环

## 四、阶段1：永久切断全部南北向流量入口
### 4.1 七层Web业务：删除Ingress资源
```bash
kubectl delete ingress api-public-ingress -n prod-business
# 删除对应证书Secret
kubectl delete secret api-tls-cert -n prod-business
```

### 4.2 四层中间件：删除LoadBalancer Service
```bash
kubectl delete svc mysql-lb -n prod-business
```

### 4.3 内部集群访问：删除ClusterIP Service
```bash
kubectl delete svc api-svc -n prod-business
```

### 4.4 验证流量完全归零
Grafana监控QPS持续为0，无任何请求日志，持续观察24h（生产72h）

## 五、阶段2：分批缩容排空所有业务Pod
### 5.1 无状态Deployment 缩容至0副本
```bash
kubectl scale deployment app-api --replicas=0 -n prod-business
# 等待所有Pod全部销毁
watch kubectl get pods -n prod-business -l app=app-api
```

### 5.2 有状态StatefulSet（MySQL/Redis）
1. 提前导出全量数据库备份至异地冷存储
2. 缩容至0副本
```bash
kubectl scale statefulset mysql --replicas=0 -n prod-business
```

### 5.3 删除HPA自动弹性伸缩
```bash
kubectl delete hpa api-hpa -n prod-business
```

## 六、阶段3：删除业务所有运行时配置资源
### 6.1 批量删除配置、密钥、网络策略
```bash
# ConfigMap
kubectl delete configmap app-api-config -n prod-business
# Secret 数据库、镜像拉取密钥
kubectl delete secret app-api-secret harbor-pull-secret -n prod-business
# 业务放行NetworkPolicy
kubectl delete networkpolicy allow-frontend-access-api -n prod-business
```

### 6.2 删除监控、日志采集资源
```bash
# Prometheus采集规则
kubectl delete servicemonitor app-api-monitor -n prod-business
# Loki日志自定义规则（如有）
```

## 七、阶段4：持久化存储PVC数据销毁与回收（核心不可逆）
### 7.1 区分存储类型操作
1. **NFS共享存储**
    1）登录NFS服务端，进入PVC对应目录，确认备份完成
    2）rm -rf 业务完整数据目录
2. **RBD块存储CSI**
    存储平台删除对应块设备，销毁磁盘数据

### 7.2 删除PVC资源
```bash
kubectl delete pvc app-api-log-pvc mysql-data-pvc -n prod-business
```
> 资源Quota会自动释放存储容量，可供新项目复用

## 八、阶段5：配套周边平台资源全清理
### 8.1 Harbor私有镜像仓库清理
1. 废弃项目镜像tag标记归档冻结，不再允许拉取
2. 删除对应环境机器人只读账号（robot-prod-business）
3. 项目不再维护则归档Harbor仓库，隐藏不删除（生产审计留存）

### 8.2 RBAC开发人员权限回收
1. 删除所有RoleBinding绑定关系
2. 废弃项目专用Role角色删除
3. 回收开发人员该项目kubeconfig访问权限（deliver-developer-access.md）
```bash
kubectl delete rolebinding dev-lisi-bind-prod-business -n prod-business
kubectl delete role prod-viewer-business -n prod-business
```

### 8.3 监控大盘、告警规则清理
1. 删除业务专属Grafana面板
2. 移除Loki日志过滤规则
3. 删除Loki日志告警规则

### 8.4 域名DNS清理
1. 公网域名DNS解析删除，域名回收归档
2. 内网域名LB后端移除该业务节点

## 九、阶段6：（可选）删除整个业务Namespace（彻底释放集群基线资源）
所有业务、存储、权限清理完成后，若项目永久废弃，直接删除命名空间：
```bash
kubectl delete namespace prod-business
```
### 删除前校验项
1. 无任何Pod、PVC、Secret残留资源
2. 无绑定该ns的RBAC权限、监控资源
3. 数据全部备份归档，无需保留任何业务配置

## 十、阶段7：运维收尾归档工作
1. 下线工单审批记录、操作执行日志、操作人、时间戳归档
2. 业务全量数据备份快照异地冷存储归档，留存至少90天
3. 资产台账更新：服务器、存储、域名、镜像仓库资源标记废弃
4. 监控告警屏蔽规则全部清理，恢复大盘默认视图
5. 集群季度巡检台账标记该项目下线，不再纳入资源统计

## 十一、DEV / UAT / PROD 环境下线差异化规范
1. **DEV开发环境**
    流程简化，无需长期观测流量，备份后直接删除所有资源、Namespace
2. **UAT测试环境**
    流量归零观测24h，数据短期备份30天，清理镜像、权限
3. **PROD生产环境（严格管控）**
    - 双人审批下线工单，留存纸质/电子审批记录
    - 流量归零持续观测72小时，确认无隐藏访问
    - 业务数据冷备份归档90天以上，满足安全审计
    - 所有操作逐条记录，运维负责人复核每一步删除操作
    - 禁止直接删除Namespace，分步清理资源，每一步校验无残留

## 十二、高频故障与风险问题处理
### 问题1：删除Namespace后PVC残留无法自动清理
根因：StorageClass回收策略Retain，ns删除不会销毁PV/PVC
处理：阶段4提前手动删除所有PVC，再删除命名空间

### 问题2：下线后开发人员依然可以查询日志/监控
根因：未清理Servicemonitor、Loki规则、RBAC权限
处理：完整执行阶段5周边资源清理步骤

### 问题3：数据库下线后业务需要恢复数据，备份已丢失
根因：下线前未完成全量数据快照备份
规范：下线第一步强制导出完整数据至冷存储，备份校验通过才允许缩容

### 问题4：删除Ingress后外部仍有少量流量访问404
根因：DNS缓存、CDN节点缓存域名解析
处理：提前TTL调小，等待缓存过期再执行下线

### 问题5：Harbor机器人账号未回收，账号泄露存在权限风险
处理：阶段8同步删除项目专用robot账号，轮换仓库总密钥

## 十三、生产运维标准化规范
1. 生产业务下线不可逆，必须双人复核、工单审批、完整数据备份三件套齐全
2. 严格遵循7阶段分步流程，禁止一步删除Namespace快速下线，防止残留垃圾资源
3. 有状态中间件（MySQL/Redis）下线前强制全量异地备份，无备份禁止缩容销毁
4. 下线后完整清理全链路配套资源：镜像、权限、监控、日志、域名、存储
5. 生产业务数据归档冷存储最低留存90天，满足等保、安全审计要求
6. 季度巡检定期扫描废弃项目残留PVC、Secret、权限资源，及时清理
7. 业务下线完成后归档全套操作记录，台账更新资产状态，闭环管理
8. 区分临时关停（disable-application-service.md）与永久下线，禁止混用两套流程

## 十四、关联文档索引
disable-application-service.md 业务流量临时关停操作手册
scale-down-application.md 业务Pod分批缩容流程
build-harbor-registry.md Harbor镜像仓库机器人账号管理
deliver-developer-access.md RBAC权限回收规范
build-storage-platform.md PVC持久化存储数据销毁流程
create-project-workspace.md 项目Namespace创建基线资源
validate-project-environment.md 项目环境上线验收标准（反向下线复核）
06-network-debug.md 下线后残留流量、权限故障排查手册