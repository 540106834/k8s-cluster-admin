# 02-containerd.md｜Containerd v2.1.5-1 DEB包安装配置（K8s标准CRI运行时）

## 一、文档基础信息

- **适配前置**：01-os-init.md（全节点系统初始化完成）、00-README.md 全局集群规范
- **适配系统**：Ubuntu 22.04 LTS x86_64
- **组件版本&安装方式区分**：containerd **v2.1.5-1(离线DEB安装)**、runc v1.3.5(wget二进制安装)、crictl v1.32.0(wget压缩包解压安装)
- **集群版本**：Kubernetes v1.32.13
- **执行范围**：✅ k8s-master-01、✅ k8s-worker-01、✅ k8s-worker-02 **全部K8s集群节点执行**
- **下游依赖**：执行完成后跳转 03-kubernetes-packages.md 部署kubeadm组件
- **核心规范**：采用systemd cgroup驱动（K8s生产强制标准）、对接内网Harbor私有仓库

```bash
root@mysql-slave:~# ls -lh download/
total 103M
-rw-r--r-- 1 root root 51M Jan  7  2025 cni-plugins-linux-amd64-v1.6.2.tgz
-rw-r--r-- 1 root root 22M Nov 18  2025 containerd.io_2.1.5-1~ubuntu.22.04~jammy_amd64.deb
-rw-r--r-- 1 root root 19M Dec  9  2024 crictl-v1.32.0-linux-amd64.tar.gz
-rw-r--r-- 1 root root 13M Mar 18 00:56 runc.amd64

```

## 二、全局集群节点信息

|主机名|IP地址|节点角色|
|---|---|---|
|k8s-master-01|192.168.11.161|K8s控制面节点|
|k8s-worker-01|192.168.11.162|K8s工作节点|
|k8s-worker-02|192.168.11.163|K8s工作节点|
|harbor.jinshaoyong.com|192.168.11.170|私有镜像仓库|

## 三、前置环境校验（必须全部通过）

全节点执行，确认上一步系统初始化无异常

```bash
# 1. 校验swap已关闭
free -h | grep Swap
# 2. 校验内核网络模块加载完成
lsmod | grep -E "overlay|br_netfilter"
# 3. 校验Harbor域名解析正常
ping -c 4 harbor.jinshaoyong.com
```

## 四、DEB离线包安装 Containerd v2.1.5-1（推荐Ubuntu生产标准方式）

**全局环境关键限制**：现场环境全部外网Github资源、Harbor HTTPS网页解析报错：

1. **Github全量链接解析失败**：runc、crictl、cni-plugins Github外网URL均网页解析失败；
2. **Harbor管理页面访问报错**：URL https://192.168.11.170 拼写/解析异常，网页无法打开；
   
✅ 统一执行规范：

1. containerd v2.1.5-1：离线DEB包安装
2. runc、crictl、CNI网络插件：优先wget命令部署，解析失败直接本地离线上传文件兜底
3. Harbor仅内网容器镜像通信、忽略前端管理页面访问报错

### 4.1 离线DEB包准备清单（提前本地下载上传）

将以下4个deb安装包，本地下好后上传所有K8s节点服务器：`/usr/local/src/containerd-deb/` 目录
- containerd_2.1.5-1_amd64.deb （唯一离线DEB安装包，仅安装containerd主程序）
- 无需上传 runc、crictl 安装包：优先服务器wget下载，下载失败再本地离线上传兜底
- 取消cni-plugins DEB安装：改用用户指定wget二进制部署方式

### 4.2 执行离线批量安装（全节点复制执行）

```bash
# 创建deb包存放目录
mkdir -p /usr/local/src/containerd-deb
cd /usr/local/src/containerd-deb

# ==== 操作步骤：本地仅上传containerd DEB包到此目录 ====
# 上传包：containerd_2.1.5-1_amd64.deb
# 仅安装containerd主程序；cni-plugins、runc、crictl全部后续二进制部署
apt install -y ./containerd_2.1.5-1_amd64.deb

# 锁定containerd版本，防止系统apt自动升级覆盖版本
apt-mark hold containerd

```

### 4.3 验证DEB安装结果

```bash
# 查看containerd安装版本，校验和全局版本一致
root@ubuntu2204-tmp-11-160:~/download# containerd --version
containerd containerd.io v2.1.5 fcd43222d6b07379a4be9786bda52438f0dd16a1

# 查看deb安装清单
dpkg -l | grep containerd

# 确认systemd服务自动生成（deb包自带service文件）
systemctl status containerd
```

### 4.4 安装 runc v1.3.5（wget二进制部署｜用户指定方式）

```bash
cd /usr/local/src
# 用户指定安装命令，下载runc二进制程序
wget https://github.com/opencontainers/runc/releases/download/v1.3.5/runc.amd64

# 授权并安装到系统全局路径
install -m 755 runc.amd64 /usr/local/sbin/runc

# 版本校验
root@ubuntu2204-tmp-11-160:~/download# runc --version
runc version 1.3.5
commit: v1.3.5-0-g488fc13e
spec: 1.2.1
go: go1.25.8
libseccomp: 2.6.0


# ⚠️ 下载失败兜底方案（现场网页解析报错执行）：本地下载文件上传至 /usr/local/src 执行上方install命令
```

### 4.5 安装 crictl v1.32.0（wget压缩包部署｜用户指定方式）

```bash
cd /usr/local/src
# 用户指定安装命令，下载crictl压缩包
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.32.0/crictl-v1.32.0-linux-amd64.tar.gz

# 解压并移动至全局可执行路径
tar -xf crictl-*.tar.gz
mv crictl /usr/local/bin/
chmod +x /usr/local/bin/crictl

# 版本校验
root@ubuntu2204-tmp-11-160:~/download# crictl --version
crictl version v1.32.0

# ⚠️ 下载失败兜底方案（现场网页解析报错执行）：本地下载压缩包上传解压移动
```

### 4.6 安装 CNI-Plugins v1.5.0（用户指定wget部署｜K8s容器网络必备插件）

```bash
cd /usr/local/src
# 用户指定标准安装命令
wget https://github.com/containernetworking/plugins/releases/download/v1.5.0/cni-plugins-linux-amd64-v1.5.0.tgz

# 创建K8s标准CNI插件目录
mkdir -p /opt/cni/bin

# 解压安装至系统标准CNI路径
root@ubuntu2204-tmp-11-160:~/download# tar -xvf cni-plugins-linux-amd64-v1.6.2.tgz -C /opt/cni/bin
./
./ipvlan
./tap
./loopback
./host-device
./README.md
./portmap
./ptp
./vlan
./bridge
./firewall
./LICENSE
./macvlan
./dummy
./bandwidth
./vrf
./tuning
./static
./dhcp
./host-local
./sbr

# 校验插件安装成功
root@ubuntu2204-tmp-11-160:~/download# ls /opt/cni/bin
LICENSE    bandwidth  dhcp   firewall     host-local  loopback  portmap  sbr     tap     vlan
README.md  bridge     dummy  host-device  ipvlan      macvlan   ptp      static  tuning  vrf

# ⚠️ 下载失败兜底方案（现场Github解析报错执行）：本地下载tgz压缩包，上传/usr/local/src后执行解压命令
```

## 五、生产环境关键配置修改（K8s强制适配｜DEB安装通用配置）

DEB安装默认自动生成配置目录 `/etc/containerd/config.toml`；核心三项配置：**systemd cgroup驱动、禁用外网加速器、内网Harbor仓库放行、pause基础镜像替换**

```bash
# 生成标准默认配置（DEB安装建议重新生成纯净配置文件）
containerd config default > /etc/containerd/config.toml

# 1. 设置Systemd Cgroup驱动（K8s集群生产强制必须配置）
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# 2. 修改默认sandbox镜像，使用阿里稳定pause镜像（规避外网镜像拉取失败）
sed -i 's|registry.k8s.io/pause:3.10|harbor.jinshaoyong.com/k8s/pause:3.10|g' /etc/containerd/config.toml

# 3. 适配现场Harbor解析异常：配置内网仓库并跳过tls校验，规避192.168.11.170网页解析失败问题
mkdir -p /etc/containerd/certs.d/harbor.jinshaoyong.com
vim /etc/containerd/certs.d/harbor.jinshaoyong.com/hosts.toml

# 修改和添加 config.toml
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d" 

```

```hosts.toml
server = "https://harbor.jinshaoyong.com"

[host."https://harbor.jinshaoyong.com"]
  capabilities = ["pull", "resolve"]
```

## 六、Systemd服务优化（DEB默认服务，仅优化参数）

DEB包安装自动生成systemd服务文件，无需新建；仅追加生产级资源、OOM优化参数

```bash
# 编辑原生service文件，追加生产优化参数
mkdir -p /etc/systemd/system/containerd.service.d/
vim /etc/systemd/system/containerd.service.d/override.conf
# 写入以下内容
[Service]
LimitNOFILE=65535
LimitNPROC=unlimited
LimitCORE=0
TasksMax=infinity
OOMScoreAdjust=-999
```

## 七、重启服务并配置开机自启

```bash
# 重载systemd配置
systemctl daemon-reload

# 重启containerd生效全部配置
systemctl restart containerd
# 设置开机自启（DEB默认已开启，重复执行兜底）
systemctl enable containerd

# 查看运行状态，确保active(running)
systemctl status containerd
```

## 八、配置 crictl 全局环境

crictl已通过wget解压部署完成，仅配置对接containerd运行时

### 8.1 配置crictl默认连接containerd

```bash
# 生成crictl全局配置文件
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
debug: false
EOF

# 校验连通性
crictl --version
crictl info
```

## 九、全流程部署验收（全部通过方可进入下一步）

```bash
# 1. 核对全部组件版本与安装方式
containerd --version      # DEB离线安装 v2.1.5-1
runc --version            # wget二进制安装 v1.3.5
crictl version            # wget解压安装 v1.32.0
ls /opt/cni/bin/          # wget部署CNI-Plugins v1.5.0
dpkg -l | grep containerd

# 2. 验证CRI接口连通性（K8s调用核心接口）
crictl info

# 3. 拉取pause基础镜像验证运行时能力
crictl pull registry.aliyuncs.com/k8sxio/pause:3.10

# 4. 验证内网Harbor仓库连通性，忽略网页解析失败报错（tls跳过校验生效）
crictl pull harbor.jinshaoyong.com/k8s/pause:3.10

# 5. 确认cgroup驱动配置生效
grep SystemdCgroup /etc/containerd/config.toml

# 6. 确认deb组件版本锁定，防止自动升级
apt-mark showhold
```

## 十、常见故障预排查（适配现场网页解析失败报错）

- **现场已知报错汇总**：1. 全部Github外网下载链接网页解析失败；2. https://192.168.11.170 Harbor管理页面URL解析/拼写错误无法访问；**以上报错不影响集群容器启动、内网镜像拉取、集群通信**
- **统一下载失败兜底方案**：全部wget外网命令解析失败时，本地浏览器下载对应二进制/压缩包，上传服务器/usr/local/src目录执行相同部署命令
- **DEB安装失败**：检查containerd.deb包完整性、服务器文件目录权限
- **containerd启动失败**：检查config.toml语法格式，尾部多余换行/格式错误会启动失败
- **Harbor镜像拉取失败**：已配置insecure_skip_verify=true，绕过网页解析失败问题；优先检查hosts内网域名解析、内网端口连通性
- **K8s后续Pod网络异常**：优先校验/opt/cni/bin插件文件完整性、目录权限（CNI插件已取消DEB安装）
- **K8s后续创建Pod失败**：优先检查 SystemdCgroup=true 是否配置生效、runc二进制权限是否为755
- **crictl连接超时**：检查/run/containerd/containerd.sock文件权限
- **版本漂移问题**：仅锁定containerd；runc、crictl、CNI插件为二进制部署，无系统自动升级逻辑

## 十一、上下游文档关联

- 上游：01-os-init.md 系统初始化
- 下游：✅ **03-kubernetes-packages.md** 离线DEB安装kubeadm/kubelet/kubectl
- 故障汇总：10-troubleshooting.md containerd运行时故障章节

