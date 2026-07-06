# 03-admin-conf.md

## 一、文档基础信息

- 所属目录：`05-kubeconfig-management/`
- 前置阅读：`01-kubeconfig-overview.md`、`02-kubeconfig-structure.md`
- 集群环境：Kubernetes v1.32.13 单Master，API地址 `https://192.168.11.161:6443`
- 核心说明：讲解集群初始化自动生成的 `/etc/kubernetes/admin.conf`，权限、拷贝流程、校验、安全规范

## 二、admin.conf 基础介绍

### 2.1 文件来源

执行 `kubeadm init` 完成集群初始化后，kubeadm 自动生成管理员kubeconfig：`/etc/kubernetes/admin.conf`  
配套证书路径：`/etc/kubernetes/pki/` 下全套集群CA、apiserver、客户端证书。

### 2.2 权限等级

内置绑定 `cluster-admin` 集群超级管理员 ClusterRole，拥有集群**全部资源增删改查权限**：

- 管理控制平面组件（etcd、kube-apiserver、coredns、calico等）
- 创建/删除节点、命名空间、RBAC、存储、工作负载
- 操作集群所有Secret、敏感配置，权限极高，禁止随意分发普通人员

### 2.3 文件内置结构（贴合02结构文档）

1. clusters：集群名称 `kubernetes`，服务地址 `https://192.168.11.161:6443`，内置CA base64
2. users：用户 `kubernetes-admin`，客户端证书+私钥base64
3. contexts：上下文 `kubernetes-admin@kubernetes`，绑定集群+管理员用户
4. current-context：默认使用管理员上下文

## 三、标准操作：拷贝至用户家目录（Master本地必做）

### 3.1 执行命令

```bash
# 创建用户kubeconfig目录
mkdir -p $HOME/.kube
# 复制管理员配置
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
# 收紧文件权限，仅当前用户可读（安全强制要求）
chmod 600 $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
```

### 3.2 权限说明

kubeconfig包含证书私钥，**必须600权限**，其他用户不可读取，否则kubectl会告警拒绝运行。

## 四、验证配置生效

```bash
# 查看当前加载配置
kubectl config view

# 查看默认上下文
kubectl config current-context
# 预期输出：kubernetes-admin@kubernetes

# 连通集群校验
kubectl get nodes
kubectl get cs
```

## 五、Worker节点同步管理员配置（仅运维管理员使用）

### 5.1 Master节点推送至Worker

```bash
# 推送至worker01
scp /etc/kubernetes/admin.conf root@192.168.11.162:/root/
# 推送至worker02
scp /etc/kubernetes/admin.conf root@192.168.11.163:/root/
```

### 5.2 Worker节点内部处理

```bash
mkdir -p $HOME/.kube
mv ./admin.conf $HOME/.kube/config
chmod 600 $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# 验证集群访问
kubectl get nodes
```

## 六、安全管控规范

1. **分发限制**
   admin.conf 为超级权限，仅集群运维负责人持有；普通开发/运维人员使用独立只读用户kubeconfig（参考`04-user-kubeconfig.md`）。
2. **传输规范**
   仅内网scp传输，禁止微信、邮件、公网链接明文发送。
3. **权限强制**
   所有kubeconfig文件权限固定 `600`，定期巡检：

   ```bash
   ls -l $HOME/.kube/config
   ```

4. **证书有效期**
   admin内置客户端证书默认有效期1年，到期后需证书轮换（参考`12-kubeconfig-rotation.md`）。

## 七、常见问题

### 7.1 kubectl 提示权限过大

报错：`config file has permissions of 644, wanted no more than 600`
修复：

```bash
chmod 600 $HOME/.kube/config
```

### 7.2 拷贝后无法连接集群

1. 核对节点hosts解析 `harbor.jinshaoyong.com`、`k8s-master-01`
2. 确认API地址 `192.168.11.161:6443` 防火墙放行
3. 检查文件是否完整，传输中断重新scp

### 7.3 证书即将过期

执行查看证书有效期：

```bash
kubectl config view --raw | grep client-certificate-data | awk -F': ' '{print $2}' | base64 -d | openssl x509 -noout -dates
```

到期前执行证书轮换流程。

## 八、上下游文档关联

- 上游：05-kubeadm-init.md 集群初始化生成admin.conf
- 基础前置：01、02 kubeconfig原理与结构
- 权限替代方案：04-user-kubeconfig.md 生成低权限普通用户配置
- 证书更新：12-kubeconfig-rotation.md
- 故障排查：15-troubleshooting.md kubeconfig权限/证书异常