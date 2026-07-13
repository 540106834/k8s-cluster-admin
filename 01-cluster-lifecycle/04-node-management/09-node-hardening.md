# 03‑worker‑node‑management/09‑node‑hardening.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/09‑node‑hardening.md`
- 前置文档：
  `00‑overview.md`、`01‑node‑basics.md`、`06‑kubelet‑runtime.md`、`08‑resource‑pressure.md`、`05‑security‑management`安全模块
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Ubuntu‑22.04、systemd、ufw防火墙、SELinux、sysctl内核参数、kubelet最小权限、镜像安全、离线内网环境。
- 适用环境：DEV / FAT / UAT / PROD。
- 文档内容：操作系统加固、内核sysctl参数、防火墙配置、用户权限加固、containerd安全配置、kubelet安全配置、镜像安全策略、文件权限、审计配置、生产检查清单。

## 二、加固整体设计原则
1. **最小可用原则**：关闭不必要服务、端口、内核模块，只开放集群必要通信端口；
2. **权限最小化**：kubelet、containerd运行用户权限收紧；配置文件权限严格管控；
3. **内核安全加固**：防范SYN‑Flood、端口扫描、资源耗尽、inode耗尽；
4. **运行时安全**：禁用特权容器、禁止hostPath随意挂载、开启SELinux；
5. **可审计**：系统操作日志、kubelet日志、containerd日志、内核日志完整留存；
6. **分层防御**：系统层 → CRI层 → kubelet层 → K8s准入Webhook多层防护。

## 三、第一部分：Ubuntu‑22.04操作系统加固
### 3.1 卸载无用服务与软件
```bash
# 关闭并禁用不必要服务
systemctl disable --now rpc‑bind avahi‑daemon cups
apt remove -y telnet‑d nfs‑common
```
### 3.2 用户与SSH安全加固
1. 禁止root账号远程登录；
2. 普通运维账号，禁止使用root日常登录；
3. SSH禁用密码登录，只使用密钥登录；修改sshd配置 `/etc/ssh/sshd_config`：
    ```ini
    PermitRootLogin no
    PasswordAuthentication no
    MaxAuthTries 3
    ```
4. 定期修改服务器密码，密码复杂度：大小写+数字+特殊字符。

### 3.3 文件权限加固（生产强制）
```bash
# kubelet配置目录权限必须为600
chmod 600 /var/lib/kubelet/config.yaml
chmod 700 /var/lib/kubelet
chmod 600 /etc/containerd/config.toml
# 系统关键文件权限
chmod 600 /etc/shadow
chmod 644 /etc/passwd
```

### 3.4 开启系统审计auditd
1. 安装`auditd`，记录登录、文件修改、进程执行操作；
2. 审计文件：kubelet目录、containerd目录、`/etc/kubernetes`；
3. 审计日志保存30天，日志同步至ELK。

## 四、第二部分：sysctl内核参数（生产固定配置，写入`/etc/sysctl.d/k8s‑hardening.conf`）
```bash
# 网络基础配置，k8s必备
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# 安全加固参数
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1               # 抵御syn‑flood攻击
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 60

# inotify参数，解决PLEG延迟、inode耗尽问题
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192

# 内核OOM行为优化
vm.overcommit_memory = 1
vm.swappiness = 0                          # 彻底禁用swap

# 防止进程耗尽PID
kernel.pid_max = 4194304

# TCP连接上限
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
```
生效命令：
```bash
sysctl -p /etc/sysctl.d/k8s-hardening.conf
```

### 内核模块黑名单，禁止加载危险模块
```bash
# /etc/modprobe.d/blacklist‑modules.conf
install cramfs /bin/false
install squashfs /bin/false
install usb‑storage /bin/false
```

## 五、第三部分：防火墙ufw配置（PROD强制开启，禁止关闭防火墙）
### 5.1 worker节点放行端口
| 端口 | 用途 | 来源 |
|------|------|------|
| 6443 | 访问apiserver | 仅控制平面网段 |
| 10250 | kubelet通信 | 集群所有节点网段 |
| 9099 | calico‑node | 集群内部 |
| 30000‑32767 | NodePort | 业务网段按需开放 |
| 22 | ssh登录 | 运维管理网段 |

ufw配置示例：
```bash
ufw reset
ufw default deny incoming
ufw allow from 10.0.10.0/24 to any port 10250
ufw allow from 10.0.10.10/32 to any port 6443
ufw allow from 运维网段 to any port 22
ufw enable
```
> 禁止配置 `ufw allow in on any` 全开放策略。

## 六、第四部分：containerd‑2.1.5安全配置（`/etc/containerd/config.toml`）
### 6.1 核心安全配置项
1. cgroup驱动固定为`systemd`；
2. 镜像仓库只使用内网Harbor，禁用外网registry；
3. 启用SELinux；
4. 禁用容器特权默认配置；
5. 容器日志限制大小；
6. sandbox镜像使用内网pause镜像；
```toml
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "harbor.jinshaoyong.com/k8s/pause:3.10"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    NoPivotRoot = false
    NoNewPrivileges = true        # 容器内禁止提权（生产必选）
    SelinuxOptions = {Type = "spc_t"}
```
### 6.2 镜像安全
1. containd‑config禁止http镜像仓库，只使用https；
2. 配合准入Webhook：禁止latest标签、禁止公网镜像、只允许内网Harbor镜像；
3. 镜像定期扫描漏洞，高危镜像禁止部署。

## 七、第五部分：kubelet安全加固（`/var/lib/kubelet/config.yaml`）
### 7.1 kubelet核心安全配置
```yaml
# 关闭匿名访问
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
authorization:
  mode: Webhook # 所有访问kubelet 10250端口都经过apiserver鉴权
# 禁止容器开启特权
allowPrivilegedContainers: false
# 日志限制
containerLogMaxSize: 50Mi
containerLogMaxFiles: 5
# 驱逐阈值使用默认值，禁止随意调低
evictionHard:
  memory.available: 100Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%
```
### 7.2 systemd服务加固（`/lib/systemd/system/kubelet.service`）
```ini
[Service]
LimitNOFILE=65535
LimitNPROC=65535
PrivateTmp=true
ProtectSystem=strict
```
执行生效：
```bash
systemctl daemon-reload
systemctl restart kubelet
```
### 7.3 kubelet‑10250端口访问控制
1. 开启Webhook鉴权；
2. NetworkPolicy限制只有apiserver可以访问kubelet 10250端口；
3. 运维人员不能直接访问10250端口。

## 八、第六部分：K8s运行时安全（配合准入控制器）
1. 启用PSS(Pod Security Standard)：生产命名空间强制Restricted模式；
    - runAsNonRoot:true；
    - capabilities.drop:["ALL"]；
    - 禁止特权容器、禁止hostPID、hostNetwork、hostPath随意挂载；
2. Node层面禁止host‑network=true的Pod随意部署，必要业务单独放行；
3. 节点本地目录尽量不要hostPath挂载，优先使用CSI‑PVC持久存储。

## 九、第七部分：日志与定时任务安全
1. 容器日志由containerd输出至`/var/log/containers`；filebeat采集至ELK；
2. 日志开启轮转，避免日志文件过多耗尽inode；
3. 清理节点上无人维护的crontab定时任务；
4. 禁止在worker节点创建业务定时任务，统一使用集群CronJob。

## 十、DEV / FAT / UAT / PROD 差异化标准
1. DEV环境：防火墙可以关闭；SSH密码登录可临时开启；内核参数仅基础配置；
2. FAT测试：sysctl参数对齐生产；开启ufw，放行集群网段；禁用root远程登录；
3. UAT预生产：完全复用生产加固配置，SELinux开启，准入策略和生产一致；
4. PROD生产环境强制约束：
    1. ufw防火墙必须开启，严格限制源IP；禁止关闭防火墙；
    2. SSH只能密钥登录，禁用密码登录；root禁止远程登录；
    3. containerd和kubelet安全配置逐条核对，禁止特权容器；
    4. 开启auditd审计，所有登录、修改配置操作留存日志；
    5. 节点加固完成后执行安全检查清单；每季度做一次漏洞扫描；
    6. 修改sysctl、kubelet、containerd配置必须提交运维工单双人审批。

## 十一、加固检查命令（逐条核查）
```bash
# 1.查看sysctl配置是否生效
sysctl net.ipv4.ip_forward fs.inotify.max_user_instances

# 2.查看防火墙规则
ufw status verbose

# 3.查看文件权限
ls -l /var/lib/kubelet/config.yaml /etc/containerd/config.toml

# 4.查看kubelet配置
cat /var/lib/kubelet/config.yaml | grep -E "allowPrivilegedContainers|authorization"

# 5.查看containerd运行状态
systemctl status containerd
crictl info

# 6.查看ssh配置
grep -E "PermitRootLogin|PasswordAuthentication" /etc/ssh/sshd_config

# 7.查看内核报错
dmesg -T
```

## 十二、生产最佳实践
1. 新节点上线前必须执行本加固清单，校验完成才允许kubeadm‑join加入集群；
2. 加固脚本做成自动化shell脚本，所有worker节点统一执行，避免人为配置不一致；
3. 开启Prometheus监控：inode使用率、tcp连接数、内核报错；
4. 定期使用kube‑bench工具扫描节点安全漏洞；
5. 区分系统层安全和集群层安全，节点加固 + PSS准入控制双层防护。

## 十三、关联文档
1. `02‑node‑join.md`：节点初始化阶段执行加固脚本；
2. `06‑kubelet‑runtime.md`：kubelet配置文件详解；
3. `08‑resource‑pressure.md`：inode耗尽、磁盘压力问题；
4. `05‑security‑management`：PSS安全策略、准入Webhook；
5. `07‑monitoring‑and‑troubleshooting`：node‑exporter系统指标监控。