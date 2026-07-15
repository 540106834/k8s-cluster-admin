# 03-access-and-security 实验环境说明

## 1. 实验目标

本实验模块围绕 Kubernetes 生产环境访问控制与安全管理展开。

主要掌握：

- Kubernetes 集群访问认证流程
- kubeconfig 生命周期管理
- RBAC 权限设计与审计
- ServiceAccount 应用身份管理
- Secret 敏感信息管理
- Kubernetes 证书生命周期管理
- Harbor 私有镜像仓库认证
- 常见安全故障排查


---

# 2. Kubernetes 集群环境

## 2.1 集群基础信息

| 项目 | 信息 |
| ---- | ---- |
| Kubernetes版本 | v1.32.13 |
| 集群类型 | 单控制平面 Kubernetes 集群 |
| 安装方式 | kubeadm |
| 操作系统 | Ubuntu 22.04 LTS x86_64 |
| 容器运行时 | containerd 2.1.5 |
| CNI插件 | Calico v3.30.4 |
| 网络模式 | Calico BGP |
| Service CIDR | 10.96.0.0/12 |
| Pod CIDR | 10.32.0.0/16 |


---

# 3. 节点信息

| 主机名 | IP地址 | 角色 |
| ---- | ---- | ---- |
| k8s-master-01 | 192.168.11.161 | Control Plane |
| k8s-worker-01 | 192.168.11.162 | Worker |
| k8s-worker-02 | 192.168.11.163 | Worker |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库 |


---

# 4. 实验工具

## Kubernetes客户端

```bash
kubectl version
kubectl cluster-info