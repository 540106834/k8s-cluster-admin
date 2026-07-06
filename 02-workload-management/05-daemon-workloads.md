# 05-daemon-workloads.md
## 一、文档基础信息
- 归属目录：`02-workload-management/`
- 前置阅读：`00-README.md`、`01-namespace-management.md`、`02-pod-lifecycle.md`
- 集群环境：Kubernetes v1.32.13、containerd 2.1.5、Calico v3.30.4、内网Harbor镜像仓库
- 环境分层：DEV本地、FAT测试、UAT预生产、PROD生产
- 核心覆盖：DaemonSet底层原理、调度规则、节点匹配策略、标准模板、运维操作、节点级组件落地规范、故障排查

## 二、DaemonSet 底层理论
### 2.1 核心定位
DaemonSet 是**节点专属控制器**，满足匹配条件的每一个节点仅运行1个Pod副本；
用于集群全局基础设施组件，不属于业务应用，不承载用户业务流量。

### 2.2 典型适用组件
- 网络类：Calico node、istio-sidecar、节点网关
- 监控采集：node-exporter、cadvisor
- 日志采集：filebeat、fluentd
- 安全审计：节点安全代理、入侵检测、内核审计
- 存储插件：CSI节点驱动、本地存储挂载代理

### 2.3 调度核心规则
1. 节点新增/上线时，自动创建对应DaemonSet Pod；
2. 节点下线/驱逐时，自动销毁该节点上Pod；
3. 每个节点最多1个副本，不支持手动扩缩容（副本数由节点数量决定）；
4. 可通过 `nodeSelector` / `nodeAffinity` / `tolerations` 筛选仅在指定节点运行；
5. 不受命名空间ResourceQuota Pod数量限制（集群基础设施豁免）。

### 2.4 与Deployment/StatefulSet核心区别
| 控制器 | 副本逻辑 | 适用场景 |
|--------|----------|----------|
| DaemonSet | 每个匹配节点1副本，副本数随节点增减 | 节点全局采集、网络、监控底层组件 |
| Deployment | 全局固定副本数，随机调度节点 | 无状态业务微服务 |
| StatefulSet | 有序固定副本，绑定独立PVC | MySQL/Redis等有状态中间件 |

## 三、标准 DaemonSet 完整模板（Filebeat日志采集示例）
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: filebeat
  namespace: kube-system
  labels:
    app: filebeat
    env: prod
    component: log-collector
spec:
  revisionHistoryLimit: 10
  # 滚动更新策略，逐节点分批更新，避免全节点采集中断
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1 # 同一时间最多1个节点Pod重建
  selector:
    matchLabels:
      app: filebeat
  template:
    metadata:
      labels:
        app: filebeat
    spec:
      # 特权权限：读取宿主机容器日志目录
      hostPID: true
      hostNetwork: false
      terminationGracePeriodSeconds: 30
      # 容忍master节点污点，单Master集群允许master运行采集组件
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      # 节点筛选：仅匹配带标签workload=node的节点
      nodeSelector:
        workload: node
      containers:
      - name: filebeat
        image: harbor.jinshaoyong.com/k8s/filebeat:8.15.0
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        # 基础探针（基础设施简化配置）
        readinessProbe:
          tcpSocket:
            port: 5066
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 5066
          initialDelaySeconds: 10
          periodSeconds: 15
        volumeMounts:
        # 挂载宿主机容器日志目录
        - name: pod-logs
          mountPath: /var/log/containers
        - name: filebeat-config
          mountPath: /usr/share/filebeat/config
      volumes:
      - name: pod-logs
        hostPath:
          path: /var/log/containers
          type: Directory
      - name: filebeat-config
        configMap:
          name: filebeat-config
```

## 四、筛选节点三大匹配机制（生产常用）
### 4.1 tolerations 容忍控制平面污点
单Master集群，DaemonSet需要在master节点运行监控/日志组件，必须添加control-plane容忍：
```yaml
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
```

### 4.2 nodeSelector 固定标签筛选节点
仅在打指定标签节点部署，例如存储节点、GPU节点：
```yaml
nodeSelector:
  storage: ssd
```

### 4.3 nodeAffinity 复杂多条件筛选
多标签与/或逻辑过滤，支持软/硬约束：
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: env
          operator: In
          values: ["fat","uat","prod"]
```

## 五、分环境部署规范
| 环境 | 部署Namespace | 更新策略maxUnavailable | 权限配置 | 探针要求 |
|------|---------------|------------------------|----------|----------|
| DEV本地 | default | 无强制 | 简化host挂载 | 可省略探针 |
| FAT测试 | kube-system | maxUnavailable=2 | 标准宿主机挂载 | readiness+liveness |
| UAT预生产 | kube-system | maxUnavailable=1 | 对齐生产权限 | 双探针完整配置 |
| PROD生产 | kube-system | maxUnavailable=1 | 最小特权，仅必要hostPath | 双探针强制配置 |

### 统一约束
1. 集群基础设施DaemonSet统一部署在 `kube-system`，禁止业务ns；
2. 业务自定义节点组件（如业务侧采集器）可部署至对应fat/uat/prod命名空间；
3. 生产环境滚动更新一次仅下线1个节点采集Pod，避免日志/监控断档。

## 六、DaemonSet 标准运维操作
### 6.1 创建/更新资源
```bash
kubectl apply -f ds-filebeat.yaml -n kube-system
```

### 6.2 查看资源状态
```bash
# 查看所有DaemonSet
kubectl get ds -n kube-system
# 查看所有节点上的采集Pod
kubectl get pods -n kube-system | grep filebeat
# 完整事件、调度、探针报错
kubectl describe ds filebeat -n kube-system
```

### 6.3 滚动更新观测
```bash
# 实时查看更新进度
kubectl rollout status ds filebeat -n kube-system -w
# 查看更新历史
kubectl rollout history ds filebeat -n kube-system
```

### 6.4 重启重载配置
```bash
kubectl rollout restart ds filebeat -n kube-system
```

### 6.5 版本回滚
```bash
# 回滚上一版本
kubectl rollout undo ds filebeat -n kube-system
# 指定历史版本回滚
kubectl rollout undo ds filebeat --to-revision=2 -n kube-system
```

### 6.6 删除DaemonSet
```bash
kubectl delete -f ds-filebeat.yaml -n kube-system
# 命令行删除
kubectl delete ds filebeat -n kube-system
```
删除后所有节点对应Pod同步销毁，宿主机日志采集停止。

## 七、Host资源挂载规范（安全红线）
DaemonSet普遍需要挂载宿主机目录，生产安全约束：
1. 最小挂载原则：仅挂载日志、监控、内核必要目录，禁止挂载 `/`、`/etc`、`/var/lib/kubelet` 全目录；
2. hostPID/hostNetwork按需开启，无需求关闭；
3. 禁止特权容器随意开启 `privileged: true`；
4. FAT环境可放宽，PROD严格限制hostPath范围。

## 八、生产运维最佳实践
1. 集群底层监控、日志、网络组件统一使用DaemonSet，禁止手动裸Pod；
2. 更新策略 `maxUnavailable=1`，保证更新过程大部分节点采集不中断；
3. 通过nodeSelector/亲和性隔离不同用途节点，避免无关节点运行采集组件；
4. 配置合理资源requests/limits，防止采集组件抢占业务节点资源；
5. 基础设施组件变更前执行etcd快照备份；
6. NetworkPolicy限制kube-system内DaemonSet对外出口，仅放行日志/监控服务地址；
7. 区分集群公共DaemonSet（calico/node、node-exporter）与业务自定义采集DS。

## 九、高频故障排查
1. **新增节点不创建DaemonSet Pod**
   检查nodeSelector、nodeAffinity、污点容忍不匹配，describe ds查看调度事件。
2. **Pod启动失败，hostPath权限不足**
   宿主机目录权限限制，调整目录权限或修改SecurityContext运行用户。
3. **滚动更新大量节点同时重建采集Pod**
   maxUnavailable设置过大，生产固定为1。
4. **节点NotReady但DaemonSet仍在运行**
   节点失联后kubelet停止上报，Pod状态变为Unknown，等待节点恢复自动重建。
5. **采集丢失日志**
   hostPath挂载路径错误、容器权限不足、filebeat配置文件缺失。

## 十、运维速查命令
```bash
# 导出DaemonSet完整备份
kubectl get ds filebeat -n kube-system -o yaml > ds-filebeat-backup.yaml

# 统计每个节点DaemonSet Pod数量
kubectl get pods -n kube-system -o wide | awk '{print $7}' | sort | uniq -c

# 查看DaemonSet更新事件
kubectl describe ds filebeat -n kube-system
```

## 十一、关联文档
1. 前置基础：`02-pod-lifecycle.md` 探针、Pod生命周期机制
2. 无状态业务对比：`03-deployment-management.md`
3. 有状态中间件对比：`04-stateful-workloads.md`
4. 资源管控：`07-resource-management.md` 容器资源限制
5. 发布回滚统一规范：`09-rollout-and-rollback.md`
6. 故障汇总：`10-workload-troubleshooting.md` 节点Pod调度、权限挂载排错