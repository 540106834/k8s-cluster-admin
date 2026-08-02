# kube-prometheus-stack 监控工程 README.md
## 一、项目基础信息
### 环境基线锁定
| 组件 | 固定版本 | 说明 |
| ---- | ---- | ---- |
| Kubernetes | v1.32 | 集群运行基线 |
| kube-prometheus-stack Chart | 65.1.0 | 核心监控Chart，全环境统一锁定版本 |
| 存储后端 | NFS StorageClass `nfs-sc` | Prometheus/Alertmanager/Grafana持久化存储 |
| Chart仓库源 | 离线MinIO | 内网无外网，Chart压缩包统一托管MinIO |
| 代码管理 | Git | 所有配置、脚本、资源文件版本受控 |

### 项目定位
本仓库为企业级K8s集群统一监控平台工程，基于Prometheus Operator构建，实现**多环境隔离部署、离线交付、标准化运维、可观测统一告警**；
所有资源遵循GitOps管理范式，变更走Git提交评审，无本地临时修改集群资源行为。

## 二、目录结构总览
```text
kube-prometheus-stack/
├── README.md                                  # 项目说明、部署入口、使用指南
├── VERSION                                    # 版本信息(K8s/Helm/Chart/Operator/Prometheus)
├── CHANGELOG.md                               # 版本变更记录
├── chart/                                     # Helm Chart信息管理
├── docs/                                      # 设计与运维全套文档
├── helm/                                      # 多环境Helm Values配置 + Grafana面板
├── manifests/                                 # Chart外独立K8s原生资源(NS/Ingress/SM/Rule)
├── scripts/                                   # 一键安装/升级/回滚/验证自动化脚本
├── offline/                                   # 离线MinIO Chart拉取工具与配置
├── images/                                    # 容器镜像清单、同步Harbor脚本
└── examples/                                  # 业务接入监控模板示例
```

## 三、核心模块功能说明
### 1. VERSION / CHANGELOG.md
1. `VERSION`：单行纯文本，记录当前Chart版本、Prometheus Operator内置组件版本，自动化脚本读取用于校验部署一致性
2. `CHANGELOG.md`：按版本记录变更点：Values参数调整、存储策略变更、告警规则新增、面板更新、离线资源同步变更、Bug修复，每次上线强制更新

### 2. chart/Chart说明文档
记录上游Chart官方地址、依赖组件、离线包存放MinIO路径、版本锁定理由、自定义覆盖范围，禁止直接修改原始Chart，所有定制通过values文件覆盖。

### 3. docs 设计文档（运维核心手册）
1. `01-architecture.md`：监控整体拓扑，Operator、Prometheus、Alertmanager、Grafana、ServiceMonitor、PodMonitor数据流架构
2. `02-deployment.md`：完整生命周期流程：初始化→安装→版本升级→回滚→完整卸载步骤
3. `03-storage-design.md`：NFS `nfs-sc` PVC分配策略、分片持久化、数据保留策略、存储容量规划、磁盘清理方案
4. `04-alerting-design.md`：告警分组、路由、静默、企业IM/邮件通知配置、告警分级规范
5. `05-security-design.md`：监控组件RBAC权限、Grafana/Prometheus TLS加密、Ingress鉴权、内部网络访问隔离
6. `06-troubleshooting.md`：采集失败、存储挂载异常、告警不触发、面板无数据、Operator崩溃等故障排查流程

### 4. helm 多环境配置层
- `values.yaml`：全局通用基础配置（存储类、副本数、RBAC、存储保留时长、基础告警）
- `values-dev.yaml`：开发环境覆盖：资源限制调低、告警静默、数据保留周期缩短
- `values-prod.yaml`：生产环境覆盖：高可用副本、大容量存储、完整告警推送、资源配额加固
- `dashboards/`：自研/自定义Grafana面板JSON，Chart部署时自动注入Grafana，统一版本管理

### 5. manifests 独立K8s资源
该目录资源**独立于Helm Chart**，提前预创建，不受Helm卸载影响：
1. `namespace.yaml`：固定`monitoring`命名空间，全集群统一
2. `ingress.yaml`：Prometheus UI、Grafana、Alertmanager统一Ingress域名、TLS配置
3. `service-monitor/`：业务自定义采集规则，统一接入规范，业务团队按模板新增
4. `prometheus-rule/`：集群、业务自定义告警规则，区分基础告警与业务告警

### 6. scripts 自动化运维脚本
全部脚本内置环境变量校验、资源预检查、日志输出，适配离线环境：
- `install.sh`：创建NS→应用独立manifests→拉取MinIO离线Chart→helm install部署
- `upgrade.sh`：Chart版本升级，支持指定环境values，升级前自动备份告警规则与面板
- `rollback.sh`：一键回滚至上一Helm版本，校验监控数据存储不丢失
- `uninstall.sh`：区分软卸载（保留PVC/存储）、完整卸载（清理所有资源）
- `verify.sh`：部署后全量校验：Pod就绪、PVC挂载、采集目标数量、面板加载、告警组件连通性
- `health-check.sh`：定时巡检脚本，输出监控平台健康指标，可接入定时任务巡检

### 7. offline 离线交付模块
适配内网无外网场景，Chart二进制包统一存企业MinIO对象存储：
- `chart-info.yaml`：记录MinIO地址、bucket名称、chart包路径、版本号、访问凭证
- `download-chart.sh`：自动从MinIO拉取指定版本chart压缩包，本地缓存用于helm部署

### 8. images 镜像供应链管理
解决离线镜像同步需求：
- `images.txt`：kube-prometheus-stack全套依赖容器镜像清单，含版本标签
- `sync-images.sh`：批量拉取上游镜像，重Tag同步至内网Harbor私有仓库，脚本支持断点续传

### 9. examples 业务接入模板
提供标准化复制即用模板，降低业务接入监控成本：
- `servicemonitor-example.yaml`：应用自定义指标采集标准模板
- `prometheusrule-example.yaml`：业务自定义告警规则模板，含分级、注释、告警说明

## 四、部署前置条件
1. K8s集群版本 v1.32，集群已部署NFS StorageClass `nfs-sc`
2. 集群可连通内网MinIO（存放helm chart离线包）、内网Harbor镜像仓库
3. 已安装helm 3+，集群具备集群管理员权限创建命名空间、RBAC、Ingress
4. 离线环境提前执行`offline/download-chart.sh`下载对应Chart包
5. Git仓库已拉取完整代码，本地配置kubectl集群上下文

## 五、快速部署流程
### 1. 代码拉取
```bash
git clone <内部Git仓库地址>
cd kube-prometheus-stack
```

### 2. 离线Chart下载（内网环境必执行）
```bash
# 拉取65.1.0版本chart至本地缓存
bash offline/download-chart.sh
```

### 3. 开发环境一键安装
```bash
# dev环境
bash scripts/install.sh dev
```

### 4. 生产环境一键安装
```bash
# prod环境
bash scripts/install.sh prod
```

### 5. 部署完成校验
```bash
bash scripts/verify.sh
```

### 6. 日常升级
```bash
bash scripts/upgrade.sh prod
```

### 7. 版本回滚
```bash
bash scripts/rollback.sh prod
```

## 六、多环境配置优先级
helm values合并顺序（由低到高，后者覆盖前者）：
`values.yaml` 通用基础 → `values-{env}.yaml` 环境定制 → manifests内独立资源

## 七、存储规范约束
1. 所有持久化组件（Prometheus/Alertmanager/Grafana）统一使用`storageClassName: nfs-sc`，禁止使用本地存储
2. 生产Prometheus开启分片持久化，数据保留时长由prod values统一管控
3. 卸载操作默认保留PVC，避免监控数据丢失；如需清理存储使用完整卸载参数

## 八、变更管控规范（GitOps约束）
1. 所有监控配置、面板、告警规则、脚本修改必须提交Git，禁止集群本地kubectl edit临时修改
2. Chart版本升级、存储策略调整、告警规则新增需更新`CHANGELOG.md`
3. 新增业务ServiceMonitor/PrometheusRule统一放置`manifests/`对应目录，配套更新examples模板
4. 镜像清单变更同步更新`images/images.txt`，执行镜像同步脚本同步Harbor

## 九、访问入口说明
Ingress资源统一在`manifests/ingress.yaml`维护，默认域名规范：
1. Grafana：grafana.monitor.企业域名
2. Prometheus UI：prometheus.monitor.企业域名
3. Alertmanager：alertmanager.monitor.企业域名

## 十、故障求助流程
1. 优先查阅 `docs/06-troubleshooting.md` 排查常见问题
2. 执行 `scripts/health-check.sh` 输出健康诊断日志
3. 确认Git代码与集群当前配置一致性，避免配置漂移
4. 查看Prometheus Operator、Prometheus Pod日志定位采集/存储异常

## 十一、维护责任人
- 平台维护：SRE运维团队
- 业务监控接入：各业务开发团队（参照examples模板自助新增）
- 离线资源同步：运维每周同步Chart与镜像至MinIO/Harbor

## 十二、许可证
内部工程私有仓库，仅限企业内部集群使用，禁止对外分发Chart、配置与自动化脚本。