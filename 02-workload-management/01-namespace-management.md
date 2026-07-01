# Namespace 命名空间管理规范（01-namespace-management.md）Ubuntu22.04 离线生产版

## 1. 文档概述

### 1.1 文档定位

本文为 Kubernetes 生产集群 **Namespace（命名空间）标准化运维规范**，适配 **Ubuntu22.04、K8s v1.32、kubeadm 离线 Harbor 集群**。统一命名空间的创建规范、资源隔离、配额管控、标签管理、权限约束、下线删除全流程标准，是所有业务上线、资源隔离、多环境划分的前置基础规范。

### 1.2 核心作用

Namespace 是 K8s 集群**资源逻辑隔离单元**，用于实现集群多租户、多业务、多环境隔离，避免不同业务资源、配置、Pod 相互干扰，是集群资源治理、配额限制、权限划分的基础维度。

### 1.3 适用场景

- 生产/测试/预发多环境隔离划分
- 多业务线、多项目资源隔离治理
- 命名空间资源配额配置、资源总量限制
- 命名空间生命周期管理：创建、运维、下线、销毁
- 基于 Namespace 的 RBAC 权限细分管控

## 2. 命名空间基础认知

### 2.1 系统默认命名空间

K8s 集群初始化自带 3 个核心命名空间，禁止修改、删除、自定义配置：
- **default**：默认命名空间，未指定 ns 的资源默认归属，生产禁止投放核心业务
- **kube-system**：集群系统组件专属命名空间，存放 apiserver、etcd、calico、coredns 等核心组件
- **kube-public**：公共只读命名空间，存放集群公共配置、信任信息

### 2.2 资源隔离范围

Namespace 隔离**绝大多数业务资源**，不隔离集群级资源：
- **命名空间级资源**：Pod、Deployment、StatefulSet、Service、Ingress、ConfigMap、Secret、PVC、Quota 等
- **集群级资源（全局）**：Node、PV、StorageClass、CRD、ClusterRole 等，不受 NS 隔离

## 3. 生产命名空间命名规范（强制）

所有自定义命名空间必须遵循统一命名规则，杜绝随意命名、混乱无序。

### 3.1 命名格式

`{env}-{business}`  
- env：环境标识（prod / test / dev / staging）
- business：业务线/项目短标识

### 3.2 标准示例

- prod-api、prod-web、test-api、dev-tools、staging-job

### 3.3 命名红线

- 禁止使用大写字母、特殊符号、中文
- 禁止使用 default、kube-system、kube-public 自定义业务
- 禁止创建模糊、无意义命名空间（test1、demo、temp）

## 4. 命名空间标签与注解规范

所有生产 NS 必须标配固定标签，用于筛选、配额绑定、权限管控、运维统计。

### 4.1 强制标签

- `env: prod/test/dev/staging`：环境标识
- `business: xxx`：业务线标识
- `owner: xxx`：负责人

### 4.2 标准 YAML（生产模板）

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod-api
  labels:
    env: prod
    business: api
    owner: ops

```

## 5. 命名空间创建运维流程

### 5.1 方式一：YAML 标准创建（生产推荐）

```bash
# 应用命名空间配置
kubectl apply -f ns-prod-api.yaml

# 查看命名空间
kubectl get ns

```

### 5.2 方式二：命令行快速创建（临时测试）

```bash
kubectl create ns test-demo

```

### 5.3 切换默认命名空间

```bash
# 安装工具（可选）
apt install kubectx -y

# 快速切换
kubens prod-api

```

## 6. 命名空间资源管控（生产核心）

生产所有业务命名空间**必须绑定资源配额与资源限制**，防止单业务耗尽集群资源。

### 6.1 关联资源

- **ResourceQuota**：命名空间总资源上限（总CPU、总内存、总Pod数）
- **LimitRange**：单 Pod 资源上下限、默认资源规格

详细配置参考：`08-resourcequota.md`、`09-limitrange.md`

## 7. 命名空间只读锁定（生产保护）

核心生产命名空间可配置**禁止删除保护**，防止误删导致业务全量下线。

### 7.1 添加删除保护注解

```yaml
metadata:
  annotations:
    kubernetes.io/delete-protection: "true"

```

开启后，直接删除 NS 会报错拦截，规避高危误操作。

## 8. 命名空间下线与删除规范

**生产红线：禁止随意删除生产命名空间**，删除前必须完成业务下线、数据备份、资源确认。

### 8.1 删除前置检查

```bash
# 检查命名空间下所有资源
kubectl get all -n prod-api

# 检查 PVC、配置、密钥
kubectl get pvc,cm,secret -n prod-api

```

### 8.2 标准删除命令

```bash
# 删除整个命名空间（级联删除所有资源）
kubectl delete ns prod-api

```

### 8.3 卡死 Terminating 状态排障

命名空间残留资源、webhook 拦截会导致删除卡死，执行强制清理：

```bash
# 导出并清理 finalizers
kubectl get ns <ns-name> -o json | jq '.spec.finalizers=[]' | kubectl replace -f -

```

## 9. 日常运维常用命令清单

```bash
# 列出所有命名空间
kubectl get ns

# 查看命名空间详情
kubectl describe ns prod-api

# 查看命名空间资源配额
kubectl get resourcequota -n prod-api

# 批量查看所有ns资源使用
kubectl get ns -o yaml | grep -E 'name|quota'

```

## 10. 生产红线规范

- 禁止生产业务运行在 default、kube-system 命名空间
- 禁止创建无标签、无归属、无配额的空白生产命名空间
- 禁止随意删除生产命名空间，删除必须走变更审批、备份流程
- 禁止多业务混杂同一命名空间，必须按业务/环境拆分隔离
- 禁止未配置 ResourceQuota、LimitRange 的命名空间上线正式业务

## 11. 常见故障与排错

- **命名空间删除卡死 Terminating**：多为资源 finalizers 残留或 webhook 拦截，清空 finalizers 强制释放
- **资源创建报错配额不足**：Namespace 绑定 ResourceQuota 已满，调整配额或清理冗余资源
- **权限不足无法操作 NS**：RBAC 权限未分配对应命名空间权限，重新绑定角色授权
- **环境混乱业务冲突**：未按规范拆分 NS，重构命名空间并迁移业务隔离

## 12. 关联文档

- 资源配额管理：`08-resourcequota.md`
- 资源限制管理：`09-limitrange.md`
- 工作负载排障：`15-workload-troubleshooting.md`


