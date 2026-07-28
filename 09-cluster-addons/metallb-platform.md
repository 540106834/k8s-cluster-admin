# Kubernetes MetalLB Platform

## 1. 项目介绍

本项目用于**裸机 Kubernetes 集群**部署 MetalLB 组件，为集群提供 `Service Type=LoadBalancer` 能力。  
裸机部署的 Kubernetes 集群无云厂商原生负载均衡能力，本项目通过 MetalLB 实现以下核心能力：

- 为 LoadBalancer 类型 Service 自动分配外网可用虚拟 IP
- 实现局域网环境下 Kubernetes 服务外网访问
- 裸机环境模拟公有云 LoadBalancer 负载均衡能力

本项目支持**离线部署**，全程依托私有镜像仓库，无需公网环境，部署管理规范可落地。  
**部署特性**：原生 YAML 部署、Git 版本管理、Harbor 私有镜像托管、离线环境适配、多环境配置隔离

---

## 2. Kubernetes 集群环境

### 2.1 集群版本

```Plain Text
Kubernetes v1.32.0
```

### 2.2 节点信息

|节点名称|节点角色|节点IP|
|---|---|---|
|master-100|Control Plane（控制面）|192.168.122.100|
|node-101|Worker（工作节点）|192.168.122.101|
|node-102|Worker（工作节点）|192.168.122.102|

### 2.3 集群网络

```Plain Text
192.168.122.0/24
```

---

## 3. MetalLB 架构

MetalLB 基于 L2 二层广播模式工作，核心由 **Controller** 和 **Speaker** 两个组件组成，协同实现负载均衡 IP 分配与流量转发。

```Plain Text
Kubernetes API Server
                     |
                     |
          +-------------------+
          |    Controller     |
          |  Deployment       |
          +-------------------+
                     |
                     |
          分配 LoadBalancer VIP
                     |
                     |
Client ------ LoadBalancer VIP
|
|
+-------------------+
|     Speaker       |
|    DaemonSet      |
+-------------------+
|
|
L2 ARP 广播宣告
|
|
Kubernetes Node 节点网络
```

---

## 4. 核心组件说明

### 4.1 Controller 控制器

- **运行方式**：Deployment 单副本部署
- **运行节点**：master-100（控制面节点）
- **核心职责**：
    - 监听集群内 Service 资源变更事件
    - 处理 LoadBalancer 类型服务的 IP 申请请求
    - 从自定义 IP 地址池中分配可用虚拟 IP
    - 更新 Service 外部 IP 状态与资源信息

### 4.2 Speaker 广播器

- **运行方式**：DaemonSet 全局部署
- **运行节点**：集群所有节点（master-100、node-101、node-102）
- **核心职责**：
    - 对外广播 LoadBalancer 虚拟 IP 地址
    - L2 模式下响应局域网 ARP 请求
    - 将外部访问流量引流至集群节点，完成流量转发

---

## 5. 网络与IP地址池设计

### 5.1 集群节点网络明细

- master-100：192.168.122.100
- node-101：192.168.122.101
- node-102：192.168.122.102

### 5.2 MetalLB IP地址池规划

地址池网段：`192.168.122.240 - 192.168.122.250`

|IP地址|用途说明|
|---|---|
|192.168.122.240|集群 Ingress 网关专属VIP|
|192.168.122.241|通用 LoadBalancer 服务VIP|
|192.168.122.242 - 192.168.122.250|备用VIP地址，预留扩容使用|

### 5.3 地址池配置约束

MetalLB IP 地址池必须满足以下条件，否则会导致服务异常：

- 与集群节点网络二层互通、同网段可访问
- IP 网段不与局域网 DHCP 自动分配地址冲突
- 所有VIP不占用集群节点物理IP，无地址冲突

---

## 6. 项目目录结构

```Plain Text
kubernetes-metallb/
├── manifests/                # 核心部署YAML资源清单
│   ├── 00-crd.yaml           # MetalLB自定义资源CRD定义
│   ├── 01-rbac.yaml          # 权限控制（SA、CR、CRB）
│   ├── 02-controller.yaml    # Controller控制器部署配置
│   ├── 03-speaker.yaml       # Speaker广播器守护进程配置
│   ├── 04-ip-pool.yaml       # VIP地址池资源配置
│   └── 05-l2.yaml            # L2二层广播模式配置
├── environments/             # 多环境配置隔离目录
│   ├── dev/                  # 测试环境专属配置
│   └── prod/                 # 生产环境专属配置
├── scripts/                  # 自动化运维脚本
│   ├── install.sh            # 一键部署MetalLB脚本
│   └── verify.sh             # 部署结果校验脚本
└── README.md                 # 项目部署说明文档
```

---

## 7. 镜像管理方案

本集群为**离线环境**，所有 MetalLB 镜像统一托管至内部 Harbor 私有仓库，节点无需访问公网。

### 7.1 私有仓库信息

```Plain Text
harbor.jinshaoyong.com
```

### 7.2 核心镜像版本

```Plain Text
harbor.jinshaoyong.com/rancher/controller:v0.14.5
harbor.jinshaoyong.com/rancher/speaker:v0.14.5
```

### 7.3 镜像离线同步流程

公网拉取镜像 → 重新打私有仓库标签 → 推送至 Harbor 私有仓库 → 集群节点拉取部署

---

## 8. 完整部署流程

### 8.1 安装 MetalLB CRD 资源

首先部署自定义资源定义，注册 MetalLB 专属 API 资源

```Plain Text
kubectl apply -f manifests/00-crd.yaml
```

验证CRD注册成功：

```Plain Text
kubectl api-resources | grep metallb
```

正常输出结果：

```Plain Text
ipaddresspools.metallb.io
l2advertisements.metallb.io
```

### 8.2 一键部署完整组件

执行自动化部署脚本，自动完成权限、组件、网络配置部署

```Plain Text
./scripts/install.sh
```

**标准部署顺序**：CRD 注册 → RBAC 权限配置 → Controller 部署 → Speaker 部署 → IP地址池配置 → L2广播配置

---

## 9. 部署结果验证

### 9.1 查看组件Pod运行状态

```Plain Text
kubectl get pods -n metallb-system -o wide
```

**预期状态**：controller、speaker 所有Pod均为 Running 正常运行状态

### 9.2 查看IP地址池配置

```Plain Text
kubectl get ipaddresspool -n metallb-system
```

### 9.3 查看L2广播配置

```Plain Text
kubectl get l2advertisement -n metallb-system
```

---

## 10. LoadBalancer 能力测试

### 10.1 创建测试LoadBalancer服务

```Plain Text
apiVersion: v1
kind: Service
metadata:
  name: nginx-lb
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
```

### 10.2 查看服务分配VIP

```Plain Text
kubectl get svc nginx-lb
```

正常结果示例：

```Plain Text
NAME        TYPE           EXTERNAL-IP
nginx-lb    LoadBalancer   192.168.122.240
```

### 10.3 访问测试

局域网内任意机器访问VIP，验证负载均衡生效：

```Plain Text
http://192.168.122.240
```

---

## 11. 版本升级策略

本项目所有变更基于 Git 版本管控，MetalLB 版本升级遵循标准化流程：  
修改私有镜像版本 → Git 提交变更 → 代码审核 → 更新集群Deployment配置 → 验证服务可用性  
示例版本迭代：v0.14.5 → v0.14.8

---

## 12. 常见故障排查

### 12.1 服务无法分配 EXTERNAL-IP

排查步骤：检查组件运行状态 → 查看控制器日志定位异常

```Plain Text
# 查看Pod状态
kubectl get pods -n metallb-system
# 查看控制器日志
kubectl logs -n metallb-system deployment/controller
```

### 12.2 VIP分配成功但无法访问服务

排查步骤：检查广播组件日志，核对网络配置

```Plain Text
kubectl logs -n metallb-system daemonset/speaker
```

重点核对项：

- L2Advertisement 广播配置是否正常存在

- 分配的VIP是否与局域网IP冲突

- 集群节点二层网络互通是否正常

---

## 13. 环境版本汇总

|组件名称|版本/配置信息|
|---|---|
|Kubernetes|v1.32.0|
|MetalLB|v0.14.5|
|部署方式|原生 YAML 清单部署|
|网络模式|L2 二层广播模式|
|镜像仓库|harbor.jinshaoyong.com|

---

## 14. 项目维护原则

本项目严格遵循标准化运维规范，保障部署可复用、变更可追溯：

- 所有核心组件基于原生 Kubernetes YAML 管理，无封装黑盒
- 全部配置文件纳入 Git 版本管控，留存变更记录
- 所有组件镜像统一托管内部 Harbor 私有仓库，支持离线部署
- 开发、生产环境配置完全隔离，互不干扰
- 生产环境所有配置变更需经过 Git Review 审核
- 标准化部署流程，保证多环境部署一致性、可重复性
