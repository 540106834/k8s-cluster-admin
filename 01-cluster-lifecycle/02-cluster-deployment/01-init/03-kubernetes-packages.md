# 03-kubernetes-packages.md

## 一、文档说明（重点解决源版本缺失问题）

1. 旧阿里云 `kubernetes/apt` 旧源仅同步至1.28，无法获取1.32版本，**必须切换官方新版分版本源** `pkgs.k8s.io` / 阿里云镜像 `kubernetes-new`
2. 安装方式：标准APT DEB安装 v1.32.13
3. 前置依赖：`02-containerd.md` 全部节点部署完成
4. 执行范围：master、worker 所有节点统一操作
5. K8s版本：v1.32.13
6. 私有镜像仓库：`harbor.jinshaoyong.com/k8s`
7. 下游文档：`04-harbor.md`

## 二、集群节点清单

| 主机名 | IP | 角色 |
|--------|----|------|
| k8s-master-01 | 192.168.11.161 | 单控制面 |
| k8s-worker-01 | 192.168.11.162 | 工作节点 |
| k8s-worker-02 | 192.168.11.163 | 工作节点 |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库 |

## 三、前置校验（所有节点）

```bash
# 1. containerd 正常运行
systemctl status containerd
crictl info

# 2. CNI插件目录完整
ls /opt/cni/bin

# 3. swap 关闭
free -h

# 4. 域名解析正常
ping harbor.jinshaoyong.com

# 5. 清理旧失效k8s源（关键）
rm -f /etc/apt/sources.list.d/kubernetes.list
apt clean
```

## 四、配置 v1.32 专属新版APT源（二选一，推荐阿里云镜像）

### 方案A：阿里云 kubernetes-new 国内镜像（推荐，速度快）

```bash
# 安装依赖
apt update && apt install -y ca-certificates curl gnupg

# 创建密钥存放目录
mkdir -p -m 755 /etc/apt/keyrings

# 导入v1.32分支签名密钥
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# 写入1.32专属源
cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.32/deb/ /
EOF

# 更新源缓存
apt update

# 查看可安装版本，确认存在1.32.13
apt-cache madison kubeadm
```

### 方案B：官方源（外网通畅时使用）

```bash
apt update && apt install -y ca-certificates curl gnupg
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
apt update
```

## 五、DEB 安装固定版本 v1.32.13

```bash
# 精准安装对应版本
apt install -y kubeadm=1.32.13-1.1 kubelet=1.32.13-1.1 kubectl=1.32.13-1.1

# 锁定版本，禁止自动升级
apt-mark hold kubeadm kubelet kubectl
```

## 六、安装校验

```bash
# 核对版本
kubeadm version
kubelet --version
kubectl version --client

# 查看锁定状态
apt-mark showhold

# 查看deb安装记录
dpkg -l | grep kube
```

## 七、kubelet 适配 containerd systemd cgroup

apt安装自动生成systemd配置，默认对接 `/run/containerd/containerd.sock`

```bash
# 校验cgroup驱动为systemd
cat /var/lib/kubelet/config.yaml | grep cgroupDriver

# 查看kubelet状态（未init/join会持续重启，属正常）
systemctl status kubelet
```

## 八、kubectl 全局补全+别名

```bash
apt install -y bash-completion
echo 'source <(kubectl completion bash)' >> /etc/profile
source /etc/profile

# 测试
k version --client
```

## 九、离线兜底方案（服务器无法访问外网源）

### 9.1 在线机器下载全套deb

```bash
# 在线Ubuntu22.04，配置上面1.32源后执行
apt update
# 仅下载不安装
apt install --download-only kubeadm=1.32.13-1.1 kubelet=1.32.13-1.1 kubectl=1.32.13-1.1
# 包存放路径 /var/cache/apt/archives/
```

### 9.2 上传集群节点离线安装

```bash
# 上传所有deb至 /usr/local/src/k8s-deb
cd /usr/local/src/k8s-deb
apt install -y ./*.deb
apt-mark hold kubeadm kubelet kubectl
```

## 十、验收标准

1. kubeadm/kubelet/kubectl 版本严格 v1.32.13
2. `apt-mark showhold` 包含三件套，不会自动升级
3. cgroupDriver: systemd，与containerd统一
4. crictl info 无报错，containerd正常运行

## 十一、常见故障排查

1. **apt-cache madison kubeadm 看不到1.32版本**
   - 原因：仍在使用旧 `mirrors.aliyun.com/kubernetes/apt` 源，仅支持1.28及以下
   - 解决：删除旧kubernetes.list，重新配置 `kubernetes-new` v1.32专属源
2. **curl密钥下载失败**
   - 离线场景：使用离线deb包方案
3. **kubelet反复重启**
   - 未执行kubeadm init/join，缺少节点配置文件，正常现象
4. **镜像拉取tls报错**
   - 跳转02-containerd.md检查harbor insecure_skip_verify配置

## 十二、上下游文档关联

- 上游：02-containerd.md
- 下游：04-harbor.md（k8s镜像仓库维护）
- 集群初始化：05-kubeadm-init.md
- 故障汇总：10-troubleshooting.md kubelet/kubeadm 异常章节