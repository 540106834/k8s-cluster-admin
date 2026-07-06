# 01-kubeconfig-overview.md

## 一、文档基础信息

- 所属目录：`05-kubeconfig-management/`
- 前置依赖：集群已完成 `05-kubeadm-init.md` 初始化，存在 `/etc/kubernetes/admin.conf`
- 适用集群：Kubernetes v1.32.13 单Master集群
- 作用：介绍 kubeconfig 核心概念、认证逻辑、使用场景、三种认证方式

## 二、什么是 kubeconfig

`kubeconfig` 是 kubectl、kubeadm、外部程序用于连接 Kubernetes API Server 的**身份配置文件**。
文件内存储三类核心信息：

1. 集群地址（API Server HTTPS 地址、CA根证书）
2. 用户身份凭证（客户端证书 / Token / 账号密码）
3. 上下文（Context）：绑定「集群+用户+默认命名空间」，一键切换访问目标

若无 kubeconfig，每次执行 kubectl 都必须手动传入全量认证参数，生产环境极不友好。

## 三、核心作用

1. **API 身份认证**
   向 192.168.11.161:6443 apiserver 提供合法凭证，校验身份后放行请求。
2. **多集群快速切换**
   一份配置文件可包含多套集群、多套用户，通过 `context` 切换集群/权限。
3. **统一默认参数**
   预设集群地址、默认命名空间、用户身份，无需每次命令追加 `--server` `--kubeconfig`。
4. **权限分层管控**
   区分管理员、只读运维、业务ServiceAccount，不同人员使用独立kubeconfig实现最小权限。

## 四、集群认证链路（当前集群）

1. kubectl 读取 `$HOME/.kube/config`（或环境变量 `KUBECONFIG` 指定文件）
2. 提取集群CA证书，校验 apiserver 证书合法性（防止中间人劫持）
3. 携带用户客户端证书/Token 发送 HTTPS 请求至 `https://192.168.11.161:6443`
4. apiserver 通过 CA 校验客户端身份，结合 RBAC 判断是否允许执行操作

## 五、三种主流认证方式（文档后续覆盖）

### 1. 客户端证书认证（管理员 admin.conf）

kubeadm init 自动生成，基于集群根CA签发证书，权限最高，长期有效（默认1年）。
适用：集群管理员、Master节点本地操作。

### 2. ServiceAccount Token 认证

集群内置sa自动生成加密token，无证书文件，可挂载至Pod内或导出给外部程序调用API。
适用：自动化脚本、监控组件、CI/CD、后台服务。

### 3. 独立用户证书认证（自定义运维账号）

使用集群CA自行签发普通用户证书，绑定只读/编辑RBAC权限，按需分发。
适用：运维人员、开发人员，禁止直接分发admin.conf。

## 六、系统默认 kubeconfig 路径优先级

kubectl 按以下顺序加载配置，后加载配置会合并覆盖前者：

1. 命令行参数 `--kubeconfig=/xxx/config`（最高优先级）
2. 环境变量 `KUBECONFIG` 指定文件，多文件用冒号分隔自动合并
3. 用户家目录默认路径 `$HOME/.kube/config`（日常最常用）
4. 系统全局无默认kubeconfig，需手动生成/拷贝

## 七、集群内置默认 kubeconfig 说明

集群初始化完成后 Master 自动生成管理员配置：

`/etc/kubernetes/admin.conf`

- 权限：集群最高 cluster-admin 权限，可增删改查所有资源
- 来源：kubeadm init 生成控制平面证书配套客户端配置
- 标准操作：拷贝至 `$HOME/.kube/config` 供当前用户使用

## 八、典型使用场景

1. Master 本地管理员操作：拷贝 admin.conf 至 `~/.kube/config`
2. Worker 节点本地 kubectl：scp 拷贝管理员配置或分发只读用户kubeconfig
3. 运维人员远程访问：签发只读用户证书，导出独立kubeconfig分发
4. 程序/组件调用API：使用ServiceAccount token生成kubeconfig
5. 多集群并行管理：合并多套kubeconfig，通过context切换集群

## 九、与集群组件关联说明

1. kubelet：使用 `/var/lib/kubelet/config.yaml` 节点专用配置，不属于用户kubeconfig体系
2. calico/metrics-server：内部通过ServiceAccount自动认证，无需人工维护kubeconfig
3. kubectl/kubeadm：完全依赖kubeconfig文件完成API通信

## 十、与本目录其他文档关联

1. 基础结构：`02-kubeconfig-structure.md` 解析yaml完整字段
2. 管理员配置：`03-admin-conf.md` admin.conf拷贝与权限设置
3. 普通用户：`04-user-kubeconfig.md` 自定义证书用户生成
4. SA账号：`05-service-account-kubeconfig.md` Token型kubeconfig
5. 日常操作：`06~08` Context/Cluster/User管理
6. 多集群合并、分发、安全、证书轮换、故障排查依次对应后续文档

## 十一、快速验证命令（当前集群执行）

```bash
# 查看当前加载的kubeconfig完整内容
kubectl config view

# 查看当前生效上下文
kubectl config current-context

# 验证集群连通性
kubectl get nodes
```
