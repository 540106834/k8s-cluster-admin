# 03-kubernetes-packages.md
## 一、文档基础信息
- 前置依赖：`02-containerd.md` 全节点 containerd、runc、cni-plugins、crictl 部署完成
- 系统：Ubuntu 22.04 LTS x86_64
- K8s 固定版本：v1.32.13
- 执行范围：所有节点（master/worker）统一执行
- 安装方式：官方二进制压缩包 wget 下载解压部署，不使用APT源
- 下游文档：`04-harbor.md`

## 二、集群全局信息
| 主机名 | IP | 角色 |
|--------|----|------|
| k8s-master-01 | 192.168.11.161 | 控制面 |
| k8s-worker-01 | 192.168.11.162 | 工作节点 |
| k8s-worker-02 | 192.168.11.163 | 工作节点 |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库 |

## 三、前置校验（必须全部通过）
```bash
# 1. containerd 正常运行
systemctl status containerd
# 2. crictl 连通正常
crictl info
# 3. CNI 插件目录存在
ls /opt/cni/bin
# 4. swap 已关闭
free -h
# 5. 网络连通github（下载失败则离线上传兜底）
ping github.com
```

## 四、二进制包下载部署 kubeadm/kubelet/kubectl v1.32.13
### 4.1 下载官方二进制压缩包
```bash
# 定义全局变量
K8S_VER=v1.32.13
ARCH=amd64
cd /usr/local/src

# 批量下载三个组件二进制包
wget https://dl.k8s.io/${K8S_VER}/bin/linux/${ARCH}/kubeadm
wget https://dl.k8s.io/${K8S_VER}/bin/linux/${ARCH}/kubelet
wget https://dl.k8s.io/${K8S_VER}/bin/linux/${ARCH}/kubectl

# ⚠️ 外网下载失败兜底：本地下载三个文件上传至 /usr/local/src
```

### 4.2 赋予执行权限并放入系统全局PATH
```bash
# 授权
chmod +x kubeadm kubelet kubectl

# 移动到系统二进制目录
mv kubeadm kubelet kubectl /usr/local/bin/

# 版本校验
kubeadm version
kubelet --version
kubectl version --client
```

## 五、配置 kubelet systemd 服务单元
二进制安装无自带service文件，手动创建标准systemd管理文件
```bash
# 创建kubelet服务文件
cat > /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
RestartSec=5
# 资源限制
LimitNOFILE=65535
LimitNPROC=unlimited
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# 创建kubelet环境变量配置目录
mkdir -p /var/lib/kubelet
mkdir -p /etc/systemd/system/kubelet.service.d

# 写入kubelet启动参数（适配containerd systemd cgroup）
cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<EOF
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=systemd"
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
ExecStartPre=/bin/sh -c 'sysctl -w fs.protected_regular=0'
ExecStartPre=/bin/sh -c 'sysctl -w fs.protected_symlinks=0'
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_CGROUP_ARGS \$KUBELET_EXTRA_ARGS
EOF
```

### 5.1 重载systemd并设置开机自启
```bash
systemctl daemon-reload
systemctl enable kubelet
# 此时无kubelet配置文件，会持续重启，属于正常现象，kubeadm init/join后自动生成配置
systemctl status kubelet
```

## 六、kubectl 命令补全（全节点永久配置）
```bash
# 安装补全依赖
apt install -y bash-completion

# 全局生效补全与别名
echo 'source <(kubectl completion bash)' >> /etc/profile
echo 'alias k=kubectl' >> /etc/profile
echo 'complete -F __start_kubectl k' >> /etc/profile

# 当前终端立即生效
source /etc/profile
```

## 七、离线部署兜底方案（服务器无法访问dl.k8s.io）
1. 能联网机器下载3个二进制文件：
   - https://dl.k8s.io/v1.32.13/bin/linux/amd64/kubeadm
   - https://dl.k8s.io/v1.32.13/bin/linux/amd64/kubelet
   - https://dl.k8s.io/v1.32.13/bin/linux/amd64/kubectl
2. 上传至集群节点 `/usr/local/src`
3. 执行4.2小节权限与移动命令，后续流程完全一致

## 八、全流程验收清单（全部通过再执行下一节）
```bash
# 1. 核对组件版本
kubeadm version
kubelet --version
kubectl version --client

# 2. 二进制文件路径校验
ls /usr/local/bin/kubeadm /usr/local/bin/kubelet /usr/local/bin/kubectl

# 3. systemd服务文件存在
ls /etc/systemd/system/kubelet.service
ls /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# 4. kubelet自启配置完成
systemctl is-enabled kubelet

# 5. kubectl补全与别名生效
k version --client
```

## 九、常见故障排查
1. **wget下载超时/解析失败**：使用离线上传方案
2. **kubelet持续启动失败**：未执行kubeadm init/join，缺少kubelet配置文件，属于正常现象
3. **Pod创建失败（cgroup不匹配）**：确认`--cgroup-driver=systemd`已写入kubelet环境配置
4. **CRI连接失败**：检查containerd socket `/run/containerd/containerd.sock` 权限与运行状态

## 十、上下游文档关联
- 上游：02-containerd.md 容器运行时部署完成
- 下游：04-harbor.md 私有镜像仓库部署
- 故障汇总：10-troubleshooting.md kubelet/kubeadm 启动异常章节