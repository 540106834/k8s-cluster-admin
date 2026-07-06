# 03-worker-node-management/10-runbooks.md
## Worker节点线上事故标准化处理手册
## 一、文档说明
本Runbook汇总Worker节点高频故障闭环处置流程，所有操作均为生产可直接落地标准步骤；
前置依赖：00-overview.md、01-node-basics.md、03-node-drain.md、05-node-troubleshooting.md、06-kubelet-runtime.md、08-resource-pressure.md、09-node-hardening.md

## 二、故障1：节点 Unknown（P0 最高优先级）
### 现象
`kubectl get nodes` 节点状态 Unknown，业务Pod批量驱逐重建，集群告警节点失联
### 排查步骤
1. 控制平面侧确认节点心跳丢失
```bash
kubectl describe node $NODE | grep -A5 Conditions
kubectl get events --field-selector involvedObject.name=$NODE
```
2. 连通性校验
```bash
# 1. 测试ssh连通
ssh $NODE_IP
# 2. 节点侧访问apiserver
curl -vk https://$APISERVER:6443/healthz
# 3. 时间同步检查
date && ssh $NODE_IP date
```
3. 分层定位根因
- 无法ssh：机房确认服务器电源、网卡、交换机故障
- 能ssh但无法访问apiserver：防火墙/路由/安全组拦截6443
- 能连通apiserver：查看kubelet/containerd/journalctl日志
### 处置流程
1. 短期失联（3分钟内可恢复）：等待主机恢复，kubelet自动上报心跳恢复Ready
2. 长期失联（超过10分钟）
```bash
# 1. 封锁节点阻止新调度
kubectl cordon $NODE
# 2. 确认业务Pod已漂移至其他节点
kubectl get pods -A --field-selector spec.nodeName=$NODE
# 3. 删除失效节点对象
kubectl delete node $NODE
# 4. 主机修复后重新执行节点接入 02-node-join.md
```
### 事后复盘要点
- 机房硬件故障/交换机抖动/内核panic/时间偏移/kubelet崩溃

## 三、故障2：节点 NotReady
### 3.1 子场景A：DiskPressure=True 磁盘打满
#### 现象
节点标记DiskPressure，无法拉取镜像，Pod频繁Evict驱逐
#### 处置步骤
1. 登录节点定位占用
```bash
df -h; df -i
du -sh /var/lib/containerd /var/log/containers
```
2. 快速清理释放空间
```bash
# 清理停止容器
crictl rm $(crictl ps -a -q)
# 清理闲置镜像
crictl images prune
# 截断超大容器日志
truncate -s 0 /var/log/containers/*.log
```
3. 临时扩容磁盘分区
4. 校验节点状态自动恢复Ready
5. 长期优化：配置containerd日志轮转、独立imagefs分区、镜像GC阈值
### 风险提示
truncate清空日志会丢失日志，故障排查优先备份日志再清理

### 3.2 子场景B：MemoryPressure=True 内存驱逐
#### 现象
节点标记MemoryPressure，大量Evicted事件，业务Pod反复重建
#### 处置步骤
1. 查看节点内存分配与宿主机占用
```bash
kubectl describe node $NODE | grep -A30 "Allocated resources"
free -h; htop
```
2. 临时缓解：删除无QoS限制的BestEffort测试Pod
3. 扩容节点内存/拆分高内存业务至高内存节点（标签调度隔离）
4. 规范所有Pod配置memory request，避免无限占用内存

### 3.3 子场景C：NetworkUnavailable=True CNI异常
#### 现象
节点NotReady，NetworkUnavailable标记为true，Pod无法互通
#### 处置步骤
1. 检查集群CNI组件Pod
```bash
kubectl get pods -n kube-system | grep calico
```
2. 重启异常CNI Pod，查看节点calico-node日志
```bash
journalctl -u calico-node -f
```
3. 校验宿主机iptables/nftables是否被业务脚本清空
4. 修复CNI后等待节点NetworkUnavailable状态自动消失

### 3.4 子场景D：kubelet/containerd服务崩溃
#### 现象
节点NotReady，无Pressure标记，服务启动失败
#### 处置步骤
```bash
# 查看运行时日志
journalctl -u containerd -f --since "10m"
journalctl -u kubelet -f --since "10m"
# 重启组件
systemctl restart containerd kubelet
```
高频根因：cgroup驱动不匹配、证书过期、socket权限丢失、磁盘满无法写日志

## 四、故障3：节点需要停机维护/内核升级/硬件更换
### 标准闭环操作流程
1. 前置检查：集群剩余资源充足、核心业务副本≥2，避开业务高峰
2. 封锁节点禁止新Pod调度
```bash
kubectl cordon $NODE
kubectl get nodes | grep $NODE # 确认SchedulingDisabled
```
3. 查看节点存量业务，评估影响
```bash
kubectl get pods -A --field-selector spec.nodeName=$NODE
```
4. 安全排空节点（生产标准模板）
```bash
kubectl drain $NODE \
--ignore-daemonsets \
--delete-emptydir-data \
--grace-period=60 \
--timeout=300s
```
5. 校验排空完成（仅保留DaemonSet）
```bash
kubectl get pods -A --field-selector spec.nodeName=$NODE | grep -v kube-system
```
6. 执行维护操作：重启/升级内核/更换硬件/重装系统
7. 主机恢复后解除调度封锁
```bash
kubectl uncordon $NODE
```
### 紧急故障强制排空（节点卡死无法优雅退出）
```bash
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --force
```

## 五、故障4：镜像拉取失败（私有Harbor/TLS报错）
### 现象
Pod状态ImagePullBackOff，报错x509证书未知、连接超时
### 处置步骤
1. 节点内手动测试拉取镜像定位问题
```bash
crictl pull harbor.internal.com/app/demo:v1
```
2. TLS证书问题：将仓库CA证书放入`/etc/containerd/certs.d/仓库域名/ca.crt`
3. 镜像源不通：切换内网Harbor镜像地址、检查节点内网路由
4. containerd重载配置
```bash
systemctl restart containerd
```
5. 删除异常Pod重建

## 六、故障5：节点PIDPressure 进程耗尽
### 现象
容器启动报错fork failed，节点PIDPressure标记True
### 处置步骤
1. 查看当前进程总量与内核上限
```bash
ps aux | wc -l
cat /proc/sys/kernel/pid_max
```
2. 临时调高进程上限
```bash
echo 4194304 > /proc/sys/kernel/pid_max
```
3. 永久固化内核参数
```bash
echo "kernel.pid_max=4194304" >> /etc/sysctl.conf
sysctl -p
```
4. 业务优化：Pod配置pids limit，限制单容器最大进程数

## 七、故障6：节点被入侵/出现恶意容器（安全应急）
### 处置流程（09-node-hardening.md配套）
1. 隔离节点，阻断横向渗透
```bash
kubectl cordon $NODE
# 快速驱逐所有业务Pod
kubectl drain $NODE --ignore-daemonsets --force
```
2. 取证：导出系统日志、容器日志、容器镜像、进程快照
3. 断开节点内网，防止横向攻击
4. 重装操作系统，清理后门、恶意程序
5. 加固节点安全配置后重新join集群
6. 全局扫描所有节点特权Pod、root容器、高危镜像

## 八、故障7：kubelet证书过期节点失联
### 现象
kubelet日志x509证书过期，节点Unknown/NotReady
### 处置步骤
1. 控制平面更新集群证书
```bash
kubeadm certs renew all
```
2. 节点同步全新kubelet pki证书
3. 重启kubelet服务
```bash
systemctl restart kubelet
```
4. 校验节点恢复Ready状态
5. 新增证书过期监控告警

## 九、通用应急操作速查表
### 9.1 节点管控基础命令
```bash
# 封锁节点
kubectl cordon $NODE
# 解除封锁
kubectl uncordon $NODE
# 标准排空
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
# 删除失效节点
kubectl delete node $NODE
```
### 9.2 运行时清理命令
```bash
# 清理停止容器
crictl rm $(crictl ps -a -q)
# 清理无用镜像
crictl images prune
# 重启运行时
systemctl restart containerd kubelet
```
### 9.3 日志排查命令
```bash
# kubelet实时日志
journalctl -u kubelet -f --since "10m ago"
# containerd实时日志
journalctl -u containerd -f --since "10m ago"
# 内核硬件/oom日志
dmesg -T | grep -E "OOM|error|I/O"
# 节点事件
kubectl get events --field-selector involvedObject.name=$NODE --sort-by=.lastTimestamp
```

## 十、故障复盘统一模板
1. 故障基础信息：故障节点、发生时间、故障等级、业务影响范围
2. 初始现象：节点状态、告警、Pod异常现象
3. 排查关键日志与执行命令输出
4. 根因定位（硬件/系统/运行时/配置/人为操作）
5. 临时恢复操作步骤
6. 长期根治优化方案
7. 监控告警补充、预防措施

## 十一、关联文档跳转
- 节点基础信息查询：01-node-basics.md
- 节点排空标准操作：03-node-drain.md
- 节点全维度故障排查：05-node-troubleshooting.md
- kubelet+containerd配置与故障：06-kubelet-runtime.md
- 资源压力驱逐机制：08-resource-pressure.md
- 节点安全加固规范：09-node-hardening.md