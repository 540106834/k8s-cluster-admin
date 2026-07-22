# 02-metrics-server.md
# Metrics Server 指标采集与HPA数据源完整文档
## 一、组件定位
Metrics Server 是Kubernetes官方轻量级指标采集组件，**集群资源基础指标标准数据源**，替代旧版Heapster。
- 资源类型：Deployment
- 推荐命名空间：kube-system
- 监听端口：6443(安全API)、10250(访问kubelet)

> 重要区分：
> Metrics Server 只采集 **Node/Pod CPU、内存实时资源用量**；
> 业务自定义指标、容器磁盘、网络、进程指标不归它负责，由Prometheus体系采集。

## 二、核心能力
1. 周期性调用各节点 `kubelet /metrics/resource` 接口，采集Pod与Node实时CPU、内存占用；
2. 指标聚合缓存，对外提供 `metrics.k8s.io` API；
3. 作为 **HPA（HorizontalPodAutoscaler）** 内置默认数据源；
4. 支撑 `kubectl top node / kubectl top pod` 命令展示资源使用率。

## 三、数据采集链路
1. Metrics Server 循环遍历所有Node；
2. 通过kube-apiserver代理或直连访问节点kubelet 10250端口；
3. 获取Pod、Node瞬时资源指标；
4. 指标短期内存缓存（默认不持久化，重启数据清空）；
5. 对外注册 `metrics.k8s.io` API，供HPA、kubectl top调用。

## 四、关键配置要点
1. **鉴权**
必须配置RBAC，拥有访问kubelet、读取Pod/Node资源权限；
2. **采集周期**
默认采集间隔15s，根据集群规模调整；
3. **kubelet访问模式**
集群内常用两种模式：
- kubelet-insecure-tls：测试环境，跳过kubelet证书校验；
- 生产：使用CA可信证书，禁止关闭TLS校验；
4. **资源限制**
大规模集群需要上调metrics-server CPU/内存配额，防止采集阻塞。

## 五、与HPA联动流程
1. HPA控制器定期向apiserver请求 `metrics.k8s.io` 指标；
2. apiserver转发请求至Metrics Server；
3. Metrics Server返回当前PodCPU/内存使用率；
4. HPA根据目标阈值计算期望副本数，触发扩缩容。

## 六、运维常用操作
```bash
# 查看metrics-server运行状态
kubectl get deployment metrics-server -n kube-system

# 验证指标API是否正常
kubectl top nodes
kubectl top pods -A

# 查看metrics-server日志（排查采集失败）
kubectl logs -f deployment/metrics-server -n kube-system

# 直接调用指标API测试
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes"
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/default/pods"
```

## 七、生产高频故障
1. **kubectl top 报错：Metrics not available**
根因：
- metrics-server Pod异常崩溃；
- RBAC权限缺失；
- 无法连通kubelet 10250端口；
- TLS证书校验失败（未配置kubelet-insecure-tls或证书不信任）。

2. **HPA一直显示 `<unknown>`**
排查顺序：
1. metrics-server正常运行；
2. API能正常返回指标；
3. HPA访问metrics.k8s.io网络无拦截；
4. 采集间隔小于HPA评估周期。

3. 大规模集群指标采集超时、部分Node无数据
优化：上调metrics-server内存、调整并发采集数量、合理拉长采集周期。

4. 指标存在延迟，HPA扩缩容滞后
根因：指标采集间隔 + HPA同步周期叠加；根据业务容忍度调整参数。

## 八、边界与局限性
1. 仅提供CPU、内存两类容器资源指标；**无磁盘、网络、自定义业务指标**；
2. 数据仅内存缓存，不持久化，无法查看历史趋势；
3. 不支持告警、图表展示；长期监控搭配Prometheus + kube-state-metrics。

## 九、运维规范
1. 生产部署至少2副本，避免单点导致HPA失效；
2. 禁止长期使用 `kubelet-insecure-tls`，完善TLS证书信任；
3. 根据集群节点规模合理设置资源requests/limits；
4. 监控metrics-server副本状态、接口响应延迟；
5. 明确分工：基础资源指标走Metrics Server；完整监控体系使用Prometheus Operator。

## 十、依赖关系
- 依赖：kube-apiserver、kubelet；
- 消费者：kubectl top、HPA；
- 平行互补：Prometheus Operator 负责长期存储与全维度监控。

下一份继续输出 `03-ingress-controller.md`？