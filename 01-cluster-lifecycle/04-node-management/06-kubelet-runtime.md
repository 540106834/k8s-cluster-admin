# 03-worker-node-management/06-kubelet-runtime.md
## 文档元信息
归属模块：Worker 节点管理
前置依赖：01-node-basics.md、05-node-troubleshooting.md
关联文档：08-resource-pressure.md、09-node-hardening.md
适用运行时：containerd 2.x（集群统一标准）
定位：kubelet + containerd 配置、故障、调优、排障完整手册

# 一、架构基础
## 1.1 组件调用链路
kubelet → CRI（/run/containerd/containerd.sock）→ containerd → runc → OCI容器
- kubelet：对接APIServer，管理Pod生命周期、资源驱逐、调度校验
- containerd：CRI标准运行时，镜像管理、sandbox/容器创建、日志转发
- runc：OCI底层，cgroup/namespace隔离、权限管控

## 1.2 核心目录路径（生产固定）
```
# containerd 主配置
/etc/containerd/config.toml
# containerd socket
/run/containerd/containerd.sock
# 容器镜像/容器数据存储
/var/lib/containerd
# kubelet 主配置
/var/lib/kubelet/config.yaml
# kubelet 工作目录
/var/lib/kubelet
# kubelet 证书
/var/lib/kubelet/pki/
# 容器日志持久化目录
/var/log/containers
# cgroup 挂载标准
/sys/fs/cgroup
```

# 二、containerd 标准配置解析
## 2.1 生成默认配置模板
```bash
containerd config default > /etc/containerd/config.toml
systemctl restart containerd
```
## 2.2 生产必改关键项
### 1）cgroup驱动统一（与kubelet对齐）
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```
> 不匹配会直接导致kubelet启动失败、Pod创建报错。

### 2）镜像加速/私有仓库（Harbor内网）
```toml
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."harbor.internal.com"]
  endpoint = ["https://harbor.internal.com"]
```
私有仓库证书存放目录：`/etc/containerd/certs.d/域名/`

### 3）日志驱动配置
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  LogDriver = "json-file"
[plugins."io.containerd.grpc.v1.cri"]
  max_log_size = "50Mi"
  max_log_files = 3
```
限制单容器日志大小，防止磁盘打满触发DiskPressure。

### 4）sandbox pause镜像统一
```toml
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "harbor.internal.com/k8s/pause:3.9"
```

## 2.3 containerd 服务启停与状态
```bash
# 状态查看
systemctl status containerd
# 重启重载配置
systemctl restart containerd
# 实时日志
journalctl -u containerd -f --since "10m"
# 版本校验
ctr version
crictl version
```

# 三、kubelet 核心配置与参数
## 3.1 kubelet 核心配置文件：/var/lib/kubelet/config.yaml
### 关键配置项说明
1. `cgroupDriver: systemd`
必须与containerd保持一致，否则节点NotReady。
2. `evictionHard`
资源驱逐硬阈值，详见 08-resource-pressure.md
3. `systemReserved` / `kubeReserved`
宿主机系统与kube组件预留资源，降低业务抢占内核资源风险
4. `imageGCHighThresholdPercent` / `imageGCLowThresholdPercent`
镜像垃圾回收水位，自动清理闲置镜像
5. `serializeImagePulls: false`
并行拉取镜像，加速多镜像Pod启动

## 3.2 kubelet 系统服务文件
路径：`/lib/systemd/system/kubelet.service.d/10-kubeadm.conf`
常用启动参数：
```
--container-runtime=remote
--container-runtime-endpoint=unix:///run/containerd/containerd.sock
--kubeconfig=/var/lib/kubelet/kubeconfig
--node-ip=节点内网IP
```

## 3.3 kubelet 运维命令
```bash
# 服务重启
systemctl restart kubelet
# 实时日志
journalctl -u kubelet -f
# 校验配置合法性
kubelet --config /var/lib/kubelet/config.yaml -v4
# 查看kubelet识别的节点资源
kubectl describe node $NODE
```

# 四、crictl 运行时调试工具（替代docker命令）
## 4.1 环境变量（永久写入/etc/profile）
```bash
export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
export IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock
```

## 4.2 高频运维命令
```bash
# 查看运行中容器
crictl ps
# 查看所有容器（含停止）
crictl ps -a
# 查看pod sandbox
crictl pods
# 拉取镜像
crictl pull harbor.internal.com/xxx:v1
# 删除镜像
crictl rmi <image-id>
# 清理无用镜像
crictl images prune
# 进入容器
crictl exec -it <container-id> /bin/sh
# 查看容器日志
crictl logs <container-id>
# 容器资源统计
crictl stats
```

# 五、高频故障分类与排查方案
## 5.1 故障1：kubelet 启动失败，报错 cgroup driver mismatch
### 现象
kubelet日志：`cgroup driver: cgroupfs, expected systemd`
### 根因
containerd SystemdCgroup=false，kubelet配置为systemd，两端不统一
### 修复
1. 修改 `/etc/containerd/config.toml` SystemdCgroup = true
2. `systemctl restart containerd kubelet`

## 5.2 故障2：cri socket 连接失败
### 日志关键词
`failed to connect containerd.sock: connection refused`
### 排查步骤
1. 检查socket文件是否存在：`ls /run/containerd/containerd.sock`
2. 检查containerd是否running：`systemctl status containerd`
3. 权限修复：`chmod 666 /run/containerd/containerd.sock`
4. 重启containerd重建socket

## 5.3 故障3：镜像拉取失败（tls/域名/证书）
### 报错
`x509: certificate signed by unknown authority`
### 修复流程
1. 在 `/etc/containerd/certs.d/仓库域名/` 放置ca.crt
2. 配置对应registry mirrors
3. 重启containerd，测试拉取 `crictl pull xxx`

## 5.4 故障4：Pod创建失败，sandbox无法启动
### 关键词
`failed to create sandbox`、`pause image pull failed`
### 根因
1. pause镜像地址错误/无法拉取
2. cgroup挂载异常
3. iptables/nftables被清空，CNI未就绪
### 修复
1. 修改config.toml sandbox_image为内网pause镜像
2. 检查cgroup挂载 `mount | grep cgroup`
3. 重启calico-node/cilium-agent

## 5.5 故障5：容器日志持续打满磁盘触发DiskPressure
### 根因
容器未配置日志轮转，单容器日志数十GB
### 临时处理
```bash
# 截断超大日志
truncate -s 0 /var/log/containers/*.log
# 清理停止容器释放空间
crictl rm $(crictl ps -a -q)
```
### 永久优化
配置containerd日志max_log_size、max_log_files，见2.2章节

## 5.6 故障6：kubelet 频繁重启、证书过期
### 日志关键词
`x509: certificate has expired or is not yet valid`
### 修复
1. 控制平面执行证书续期 `kubeadm certs renew all`
2. 节点重新join或同步kubelet pki证书
3. 同步节点时间 `chronyc tracking`

# 六、生产调优最佳实践
## 6.1 containerd 性能调优
1. 开启并行镜像拉取，关闭serializeImagePulls
2. 镜像存储目录挂载独立高速SSD分区
3. 限制并发容器创建数量，避免瞬间IO打满
4. 配置镜像自动GC阈值，定期清理废弃镜像

## 6.2 kubelet 资源预留调优
示例配置（8C16G节点）：
```yaml
systemReserved:
  cpu: "500m"
  memory: "1Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
```
预留资源避免内核/运行时被业务Pod抢占导致节点失联。

## 6.3 安全调优（联动09-node-hardening.md）
1. 禁止容器特权运行，PodSecurityPolicy/PSP替换为PodSecurityStandard
2. containerd限制容器挂载宿主机敏感目录
3. 限制容器文件句柄、进程数ulimit
4. 私有仓库强制TLS，禁止http明文拉取镜像

# 七、标准化巡检清单
每次节点巡检必执行：
1. containerd、kubelet 服务running无报错
2. cgroup驱动两端统一systemd
3. 私有仓库证书完整，镜像拉取正常
4. 日志轮转参数已配置，无超大容器日志
5. 镜像GC阈值配置合理，闲置镜像定期清理
6. kubelet资源预留配置生效
7. crictl pods/ps无大量异常终止sandbox/容器

# 八、文档关联跳转
- 节点基础状态查看：01-node-basics.md
- 节点整体故障排查：05-node-troubleshooting.md
- 资源压力与驱逐阈值：08-resource-pressure.md
- 节点安全加固：09-node-hardening.md
- 事故处理手册：10-runbooks.md