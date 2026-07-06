# 03-worker-node-management/09-node-hardening.md
## Worker节点安全加固生产规范
## 一、加固总原则
Worker节点承载业务容器，是集群攻击暴露面最大环节；加固目标：收缩宿主机权限、限制容器逃逸、缩小攻击面、闭环审计、杜绝弱配置。
前置依赖：01-node-basics.md、06-kubelet-runtime.md、08-resource-pressure.md
关联文档：05-node-troubleshooting.md、10-runbooks.md

## 二、宿主机系统层加固
## 2.1 系统账号与SSH安全
1. 禁用root远程SSH登录，仅普通运维账号登录
```ini
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
MaxAuthTries 3
AllowUsers opsadmin
```
2. 全节点统一密钥登录，删除闲置账号、弱口令账号
3. 定时清理过期sudo权限，sudo仅授予运维最小权限
4. 配置ssh自动断开闲置会话 `ClientAliveInterval 300`

## 2.2 内核sysctl安全参数
写入`/etc/sysctl.conf`全局生效
```conf
# 关闭IP转发伪造
net.ipv4.ip_forward=0
# 防范ICMP重定向攻击
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
# 禁止源路由
net.ipv4.conf.all.accept_source_route=0
# 开启SYN洪水防护
net.ipv4.tcp_syncookies=1
# 限制core转储，防止敏感信息泄露
fs.suid_dumpable=0
# 保护内核指针
kernel.kptr_restrict=1
# 限制ptrace防进程注入
kernel.yama.ptrace_scope=1
```
生效命令：`sysctl -p`

## 2.3 文件系统权限加固
1. 敏感目录严格权限
```bash
chmod 600 /etc/shadow
chmod 644 /etc/passwd
chmod 700 /root
chmod 700 /var/lib/kubelet/pki
```
2. 挂载关键目录nosuid、noexec、nodev
`/tmp`、`/var/tmp`、`/dev/shm` 添加挂载参数
3. 禁用USB存储设备，防止数据外带
4. 定期扫描SUID/SGID高危程序，清理无用setuid二进制

## 2.4 防火墙与网络访问控制
1. 使用firewalld/nftables限制入站端口，仅开放必要端口
- 仅内网段允许6443、10250、10255
- 禁止公网直接访问kubelet、containerd
2. 禁止节点之间互通高危端口，业务网络隔离
3. 关闭无用服务：rpc、nfs、ftp、telnet等传统服务
4. 限制ICMP速率，防止网络扫描攻击

## 三、containerd运行时安全加固
## 3.1 容器运行时基础限制
1. 默认禁用特权容器，禁止`privileged: true`
2. 禁止容器挂载宿主机敏感目录：/etc、/root、/var/lib/kubelet、/sys/fs/cgroup
3. 限制容器capabilities，仅保留业务必需能力，删除ALL高危cap
```yaml
securityContext:
  capabilities:
    drop:
      - ALL
```
4. 禁止容器修改内核参数、加载内核模块

## 3.2 containerd配置安全约束
1. 私有仓库强制TLS，禁止http明文拉取镜像
2. 镜像仓库配置证书校验，拒绝自签未信任证书
3. 限制容器ulimit，防止文件句柄耗尽DoS
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  Rlimits = [
    {"type": "RLIMIT_NOFILE", "hard": 10240, "soft": 4096}
  ]
```
4. 日志驱动统一json-file，禁止容器输出敏感明文日志

## 3.3 镜像安全管控
1. 禁止latest标签镜像，强制固定版本号
2. 镜像准入校验：镜像漏洞扫描、私有仓库仅放行可信镜像
3. 禁止使用基础镜像含高危工具（curl、wget、nc、bash可按需裁剪）
4. 定期清理闲置镜像，缩小攻击面

## 四、kubelet组件安全加固
## 4.1 kubelet访问鉴权加固
1. 关闭kubelet匿名只读访问 `--anonymous-auth=false`
2. 开启kubelet认证、授权Webhook，不允许未授权访问10250端口
3. kubelet证书定期轮换，设置证书过期告警
4. kubeconfig文件权限600，仅kubelet进程可读

## 4.2 资源与逃逸防护
1. 全局强制Pod配置request/limit，杜绝无限制资源占用
2. 开启kubelet cgroup pids限制，防止进程耗尽攻击
3. 禁止容器挂载宿主机/dev设备，阻断硬件逃逸
4. 禁用kubelet调试端口、pprof线上对外开放

## 4.3 节点访问隔离
1. 维护节点自动添加NoSchedule污点，隔离业务Pod
2. 故障节点配置NoExecute污点，快速驱逐业务容器
3. 使用NodeSelector+Taint实现业务分区隔离，数据库/中间件独立节点组

## 五、Pod安全标准（强制落地）
## 5.1 全局SecurityContext规范
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  fsGroup: 2000
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
```
- 禁止root用户运行容器
- 关闭权限提升，防止容器内提权逃逸
- 只读根文件系统，阻断恶意写入篡改程序

## 5.2 PodSecurity标准分级
集群启用PodSecurity准入控制器，命名空间分级管控：
1. Restricted（生产业务默认）：最严格，限制权限、cap、root、特权
2. Baseline（中间件运维）：允许少量基础能力，无高危权限
3. Privileged（仅监控/网络组件）：仅限可信DaemonSet使用

## 5.3 网络策略隔离
1. 全局开启NetworkPolicy，默认拒绝Pod跨命名空间互通
2. 业务之间仅开放必需端口，禁止全通策略
3. 阻断Pod直连节点宿主机IP，限制横向渗透

## 六、审计与监控加固
## 6.1 系统审计
1. 启用auditd审计：ssh登录、sudo操作、文件修改、容器创建删除
2. 审计日志远端同步至日志中心，本地不可删除篡改
3. 监控异常账号登录、多次密码失败、su切换root行为

## 6.2 集群安全告警
1. 监控特权Pod、root运行容器、高危capabilities容器创建事件
2. 监控节点Pressure、kubelet证书过期、节点未知IP接入
3. 监控容器镜像拉取失败、异常大量容器创建销毁

## 七、定期安全巡检清单
1. SSH禁止root登录、密码登录，仅密钥认证
2. 无特权容器、无root运行业务Pod
3. containerd私有仓库TLS证书有效，无http仓库
4. kubelet关闭匿名访问，证书未过期
5. /tmp、/dev/shm挂载nosuid/noexec
6. 无闲置SUID程序、弱口令账号
7. 所有业务Pod配置只读根、禁止权限提升
8. NetworkPolicy已部署，默认拒绝跨NS访问
9. auditd审计正常采集，日志远端存储
10. 节点无高危sysctl配置，防火墙限制内网端口

## 八、应急安全处置流程
1. 发现恶意容器：节点cordon → drain驱逐 → 删除恶意Pod
2. 节点被入侵：断开网络 → 快照取证 → 重装节点重新join
3. 证书泄露：批量轮换节点kubelet证书、更新仓库证书
4. 横向渗透：启用NetworkPolicy阻断互通，隔离受感染节点

## 九、关联文档跳转
- kubelet与containerd配置调优：06-kubelet-runtime.md
- 节点资源压力驱逐机制：08-resource-pressure.md
- 节点排空隔离操作：03-node-drain.md
- 节点故障排查手册：05-node-troubleshooting.md
- 线上事故标准化处理：10-runbooks.md