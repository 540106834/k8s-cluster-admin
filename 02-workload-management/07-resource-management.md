# 07-resource-management.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`01-namespace-management.md`、`02-pod-lifecycle.md`
- 集群环境：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT功能测试、UAT预生产、PROD生产
- 核心覆盖：requests/limits原理、LimitRange容器默认约束、ResourceQuota命名空间总配额、分环境配置、资源超限报错、资源防雪崩规范

## 二、底层资源理论基础
### 2.1 CPU/Memory 单位定义
1. CPU
   - `1` = 1核完整CPU；`1000m` = 1核；`100m` = 0.1核
2. Memory
   - Mi/MiB：二进制 1Mi=1024Ki；MB十进制不推荐，统一使用Mi/Gi
3. 规范：所有资源统一使用 `m`、`Mi`、`Gi` 单位

### 2.2 requests（调度预留资源）
1. 调度器依据requests筛选可用节点；
2. 节点预留对应资源，多Pod requests总和不能超过节点总资源；
3. Pod最小保障资源，程序峰值不超过requests也不会被限流/杀死；
4. 无requests会被LimitRange填充默认值。

### 2.3 limits（硬上限资源）
1. CPU达到limits：容器CPU被节流，程序变慢但不终止；
2. Memory达到limits：容器触发OOM Kill，退出码137；
3. 生产强制所有容器配置limits，防止单Pod耗尽整机资源。

### 2.4 两者关系约束
- requests ≤ limits；禁止requests大于limits；
- 仅配置requests：无上限，存在资源雪崩风险；
- 仅配置limits：调度无预留，极易出现节点资源抢占。

## 三、LimitRange：命名空间容器默认资源兜底
### 3.1 作用
命名空间内未声明 `resources` 的容器自动注入默认 requests/limits，统一兜底，避免裸容器无资源限制。
### 3.2 标准模板（分环境差异化）
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-container-limit
  namespace: prod
spec:
  limits:
  - type: Container
    # 未配置limits时自动填充上限
    default:
      cpu: "1"
      memory: "1Gi"
    # 未配置requests时自动填充预留
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    # 单容器最大资源硬限制，禁止超规格容器
    max:
      cpu: "4"
      memory: "8Gi"
    # 单容器最小资源，防止超小容器碎片调度
    min:
      cpu: "10m"
      memory: "16Mi"
```

### 3.3 分环境 LimitRange 参数标准
| 环境 | default cpu/mem | max cpu/mem | min cpu/mem |
|------|-----------------|-------------|-------------|
| DEV本地 | cpu:500m,mem:512Mi | cpu:2,mem:4Gi | cpu:10m,mem:16Mi |
| FAT测试 | cpu:500m,mem:512Mi | cpu:3,mem:6Gi | cpu:10m,mem:16Mi |
| UAT预生产 | cpu:1,mem:1Gi | cpu:4,mem:8Gi | cpu:100m,mem:128Mi |
| PROD生产 | cpu:1,mem:1Gi | cpu:4,mem:8Gi | cpu:100m,mem:128Mi |

## 四、ResourceQuota：命名空间全局资源总配额
### 4.1 作用
限制整个Namespace所有Pod、CPU、内存、PVC、Service、ConfigMap总数量，防止单环境耗尽集群全部资源。
### 4.2 完整模板（PROD示例）
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-total-quota
  namespace: prod
spec:
  hard:
    # 计算资源配额
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    # Pod总数量上限
    pods: "40"
    # 存储资源
    persistentvolumeclaims: "15"
    # 集群服务资源
    services: "10"
    services.loadbalancers: "2"
    # 配置类资源
    configmaps: "100"
    secrets: "50"
```

### 4.3 四层环境配额标准
#### FAT（功能测试，宽松）
```yaml
hard:
  requests.cpu: "16"
  requests.memory: 32Gi
  limits.cpu: "32"
  limits.memory: 64Gi
  pods: "80"
  persistentvolumeclaims: "30"
```
#### UAT（预生产，对齐生产规格）
```yaml
hard:
  requests.cpu: "12"
  requests.memory: 24Gi
  limits.cpu: "24"
  limits.memory: 48Gi
  pods: "50"
  persistentvolumeclaims: "20"
```
#### PROD（生产，严格管控）
```yaml
hard:
  requests.cpu: "20"
  requests.memory: 40Gi
  limits.cpu: "40"
  limits.memory: 80Gi
  pods: "40"
  persistentvolumeclaims: "15"
```
#### DEV本地
无集群配额，本地Docker/Kind自行控制。

## 五、资源配额配套运维操作
### 5.1 部署 LimitRange / ResourceQuota
```bash
kubectl apply -f limitrange-prod.yaml -n prod
kubectl apply -f quota-prod.yaml -n prod
```

### 5.2 查看配额使用情况
```bash
# 查看当前配额定义
kubectl get resourcequota ns-total-quota -n prod
# 查看已使用/总配额详情
kubectl describe resourcequota ns-total-quota -n prod
# 批量查看所有命名空间配额
kubectl get resourcequota --all-namespaces
# 查看LimitRange约束
kubectl describe limitrange default-container-limit -n fat
```

### 5.3 扩容配额流程
1. 清理闲置Pod、PVC释放资源；
2. 修改yaml hard字段上调上限；
3. `kubectl apply -f` 生效；
4. 重新describe校验可用额度。

### 5.4 清空环境释放配额（FAT专用）
```bash
kubectl delete deploy,sts,job,cronjob,pvc -n fat --all
```

## 六、存储资源配额补充（PVC）
1. ResourceQuota限制命名空间PVC总数量；
2. StorageClass可配置单PV存储容量上限；
3. StatefulSet volumeClaimTemplates创建的PVC同样计入配额；
4. FAT环境可定时清理闲置PVC，PROD删除PVC需双人复核。

## 七、生产强制落地规范
1. **所有业务Namespace必须同时部署LimitRange + ResourceQuota**，缺一不可；
2. 禁止创建无requests/limits的容器，LimitRange兜底补全；
3. 生产中间件（MySQL/Redis）单独调高limits内存，规避OOM；
4. 发布前校验目标命名空间剩余配额，避免创建Pod报 `exceeded quota`；
5. FAT环境每日自动清理闲置负载释放配额；PROD禁止自动回收业务资源；
6. 集群底层DaemonSet（kube-system）不受Namespace Quota限制，单独管控节点总资源；
7. 大版本升级前核对各环境资源占用，预留足够配额避免升级滚动失败。

## 八、高频资源故障与解决方案
### 1. 创建Pod报错：exceeded quota
原因：Namespace ResourceQuota已达硬上限
处理：清理闲置Pod/PVC/Service，或上调quota hard数值。

### 2. 容器OOM killed，退出码137
原因：memory limits过小，程序内存占用超出上限
处理：调高容器memory limits，优化应用内存泄漏。

### 3. 应用CPU持续节流、响应缓慢
原因：CPU limits过低，业务流量峰值被限流
处理：上调CPU limits，扩容副本分担压力。

### 4. 无resources的Pod未自动填充默认值
原因：对应命名空间未部署LimitRange，重新apply LimitRange资源。

### 5. 节点资源充足，但Pod调度失败
原因：节点总requests总和打满节点预留资源，limits不参与调度计算。
处理：缩容闲置Pod，或新增Worker节点扩容集群资源池。

### 6. StatefulSet扩容PVC报配额不足
ResourceQuota pvc数量耗尽，清理废弃PVC或上调pvc硬限制。

## 九、运维速查命令
```bash
# 批量导出所有命名空间配额备份
kubectl get resourcequota --all-namespaces -o yaml > all-quota-backup.yaml

# 统计各命名空间Pod占用
for ns in fat uat prod;do echo "==== $ns ====";kubectl get pods -n $ns | wc -l;done

# 查看命名空间资源占用总和
kubectl describe resourcequota -n prod
```

## 十、关联文档
1. 前置隔离：`01-namespace-management.md` 多环境分层隔离规范
2. Pod基础：`02-pod-lifecycle.md` OOM退出码、容器资源机制
3. 各类负载规范：03-deployment / 04-stateful / 05-daemon / 06-batch 资源配置模板
4. 扩缩容联动：`08-workload-scaling.md` HPA自动伸缩依赖requests指标
5. 故障汇总：`10-workload-troubleshooting.md` 资源超限、调度失败完整排错