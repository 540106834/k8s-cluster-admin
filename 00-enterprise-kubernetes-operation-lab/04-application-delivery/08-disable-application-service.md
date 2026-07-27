# disable-application-service.md
# 业务流量入口临时关停标准化操作手册
## 一、文档定位
本文适用于**业务临时维护、版本灰度暂停、故障隔离、安全漏洞处置**场景，提供七层Ingress、四层LoadBalancer、内部Service三种流量入口关停方案；区分临时关停（可快速恢复）与永久下线前置隔离，不删除Deployment/PVC等业务数据，仅切断外部/内部访问流量，配套应用发布、缩容、下线文档。  
前置依赖：  
deploy-java-application.md｜业务应用正常运行  
expose-application-service.md｜Service/Ingress/LB流量暴露配置  
scale-down-application.md｜业务副本缩容操作手册  
下游关联：decommission-application.md｜应用完整退役销毁

## 二、操作区分：临时关停 vs 永久下线
### 2.1 临时关停（本文适用，保留所有业务资源）
场景：
1. 重大漏洞临时隔离，修复完成后恢复访问
2. 数据库迁移、中间件升级，暂停外部流量
3. 版本灰度暂停，临时下线新版本入口
4. 第三方接口故障，切断业务防止大量报错
操作逻辑：仅屏蔽流量入口（Ingress/LB/Service），**保留Deployment、PVC、ConfigMap、Secret**，随时一键恢复流量。

### 2.2 永久下线（decommission-application.md）
业务彻底淘汰，删除所有Namespace内资源、PVC、镜像项目、权限，不再恢复。

### 2.3 关停前置风险校验
1. 确认业务可短暂断流，提前通知使用方
2. 生产业务选择低峰窗口操作
3. 记录当前流量入口配置，便于快速回滚恢复
4. 核心中间件（数据库）不操作，仅关停上层业务流量

## 三、三类流量入口关停方案（按需选择）
### 方案1：七层Web/API 关停Ingress（最常用，对外域名屏蔽）
适用于公网/内网域名HTTP/HTTPS业务。
#### 3.1 方式A：临时注释Ingress路由规则（快速恢复）
```bash
# 编辑Ingress资源，注释所有rules、tls段落
kubectl edit ingress api-public-ingress -n prod-business
```
修改示例：
```yaml
# spec:
#   tls:
#   - hosts: ["api.example.com"]
#     secretName: api-tls-cert
#   rules:
#   - host: api.example.com
#     http:
#       paths: ...
```
保存后Ingress-Nginx立即刷新配置，域名访问直接404。

#### 3.2 方式B：临时切换空IngressClass，隔离流量
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: nginx-disabled # 不存在的网关
```
#### 3.3 恢复流量：删除注释/改回原IngressClass

### 方案2：四层TCP业务关停MetalLB LoadBalancer（数据库/中间件）
适用于MySQL、Redis、Kafka等四层长连接服务。
#### 3.1 修改Service，删除LB IP分配标签，切换为ClusterIP
```bash
kubectl edit svc mysql-lb -n prod-db
spec:
  type: ClusterIP # 从LoadBalancer改为仅内部访问
  # 删除loadBalancerIP、LB相关annotations
```
效果：公网/内网VIP立即回收，外部无法连接，集群内部Pod仍可访问。

#### 3.2 恢复：改回type:LoadBalancer，补充原有LB标签。

### 方案3：集群内部完全隔离（禁止所有Pod调用）
适用于全链路故障，不仅切断外部，同时阻断其他微服务内部调用。
#### 3.1 操作：NetworkPolicy全局阻断所有入站流量
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-all-ingress
  namespace: prod-business
spec:
  podSelector:
    matchLabels:
      app: api-server
  policyTypes: [Ingress]
  # 无任何from规则，全部阻断
```
应用后：同命名空间、跨命名空间Pod均无法访问该业务端口。
#### 3.2 恢复：删除该阻断NetworkPolicy。

## 四、步骤1：关停流量标准化操作流程
1. 前置通知：运维、产品、开发告知业务临时维护窗口
2. 记录原始流量入口配置（Ingress/Service yaml备份）
3. 执行对应入口关停操作
4. 连通性验证：外部/内部访问全部失败
5. 监控告警屏蔽：屏蔽该业务5xx、连接失败告警
6. 维护操作（漏洞修复、迁移、升级）
7. 维护完成后恢复流量，校验业务访问正常
8. 取消告警屏蔽，留存操作记录

## 五、步骤2：关停效果验证
### 5.1 七层Ingress验证
浏览器访问域名返回404 Not Found；curl域名无响应。
### 5.2 四层LB验证
外网nc VIP 3306 连接超时；集群内部Pod可正常连通。
### 5.3 全网隔离（NetworkPolicy）验证
集群其他Pod `curl api-svc` 连接超时、无法解析转发。

## 六、步骤3：流量快速恢复操作
### 6.1 Ingress恢复
取消rules注释，还原原ingressClass，等待10秒Nginx重载配置，域名访问恢复。
### 6.2 LoadBalancer恢复
Service改回type:LoadBalancer，补齐原LB标签，自动重新分配VIP。
### 6.3 网络隔离恢复
删除block-all-ingress NetworkPolicy，业务互通立即恢复。

## 七、配套辅助操作（可选）
### 7.1 临时缩容业务副本（流量入口关停后）
完全无访问需求时，缩容降低资源占用，参考scale-down-application.md
```bash
kubectl scale deployment app-api --replicas=1 -n prod-business
```
### 7.2 暂停HPA自动扩容
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
spec:
  minReplicas: 1
  maxReplicas: 1 # 锁定副本无法扩容
```

## 八、DEV / UAT / PROD 环境差异化规范
1. DEV开发环境：可直接删除Ingress/切换Service类型，无严格流程
2. UAT测试环境：关停前通知测试人员，维护窗口不限
3. PROD生产环境：
   - 仅限凌晨低峰窗口执行关停操作
   - 必须留存原始入口yaml备份，防止恢复配置丢失
   - 关停与恢复全程留存操作日志、时间戳、操作人
   - 核心交易业务关停前确认无正在支付订单

## 九、高频故障与处理
### 故障1：关停Ingress后部分缓存节点依然能访问
根因：Ingress-Nginx DaemonSet配置重载延迟；
处理：重启ingress-nginx Pod快速刷新规则。
### 故障2：LoadBalancer切换ClusterIP后内部也无法访问
根因：同时配置了阻断NetworkPolicy；
处理：删除阻断策略，ClusterIP仅屏蔽外部。
### 故障3：恢复Ingress后域名访问502
根因：后端Deployment副本缩容至0；
处理：扩容业务Pod至正常副本数。
### 故障4：四层LB恢复后VIP不自动分配
根因：IP地址池标签、annotations丢失；
处理：核对Service原有metadata标签，补齐后重新apply。
### 故障5：NetworkPolicy阻断策略删除后依然无法访问
根因：存在多条叠加deny规则；
处理：批量清理项目ns下冲突NetworkPolicy，重新加载放行基线。

## 十、生产运维标准化规范
1. 临时关停仅操作流量入口，**严禁删除Deployment、PVC、Secret**等持久化资源；
2. 生产业务关停前必须留存Ingress/Service原始配置备份，保障快速恢复；
3. 七层Web业务优先操作Ingress，四层中间件操作LoadBalancer，内网隔离使用NetworkPolicy；
4. 业务维护完成第一时间恢复流量，禁止长期关停遗忘引发业务停滞；
5. 关停期间屏蔽对应业务告警，避免大量超时、5xx告警刷屏；
6. 重大漏洞、故障隔离操作完整归档记录：关停时间、恢复时间、处置原因、操作人；
7. 项目交付验收区分临时关停与永久下线流程，禁止混用操作。

## 十一、关联文档索引
expose-application-service.md Service、Ingress、LB流量暴露配置
scale-down-application.md 业务临时缩容操作手册
deploy-java-application.md Java微服务Deployment部署模板
deploy-stateful-application.md 有状态中间件四层LB配置
decommission-application.md 应用完整永久下线销毁流程
05-network-security.md NetworkPolicy流量隔离规则配置
06-network-debug.md Ingress 404、LB VIP分配故障排查