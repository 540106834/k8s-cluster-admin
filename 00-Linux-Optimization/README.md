# Linux-System-Optimization

> Linux系统性能优化、安全加固知识库
>
> 学习思路：
    - 20% 理论：理解Linux内核机制
    - 80% 实战：生产环境调优、故障排查、Kubernetes节点优化

├── 01-Performance-Analysis-Basics
│   ├── Performance-Methodology.md              # 性能分析方法论（USE、RED、Golden Signals）
│   ├── Performance-Tools.md                    # 性能分析工具（top、vmstat、iostat、sar、perf、ss）
│   └── Troubleshooting-Workflow.md             # Linux性能问题排查流程
│
├── 02-Linux-Kernel-Performance-Optimization
│   ├── CPU-Optimization.md                     # CPU调度、Load、Context Switch、CPU绑定优化
│   ├── Memory-Optimization.md                  # 内存管理、Page Cache、Swap、OOM优化
│   ├── Network-Optimization.md                 # TCP/IP、Socket、Conntrack、网络栈优化
│   ├── Disk-IO-Optimization.md                 # IO调度、文件系统、磁盘性能优化
│   ├── Kernel-Parameter-Tuning.md              # sysctl核心参数调优
│   └── Resource-Limit-Optimization.md          # ulimit、cgroup、资源隔离优化
│
├── 03-Linux-Network-Optimization
│   ├── TCP-IP-Stack.md                         # Linux TCP/IP网络栈原理
│   ├── Socket-Tuning.md                        # Socket Buffer、连接管理优化
│   ├── Conntrack-Optimization.md                # NAT连接跟踪性能优化
│   ├── Network-Queue-Optimization.md            # NIC Queue、RSS/RPS/XPS优化
│   └── Network-Troubleshooting-Cases.md         # 网络性能故障案例
│
├── 04-Linux-Storage-Optimization
│   ├── IO-Subsystem.md                          # Linux IO模型和Block Layer
│   ├── IO-Scheduler.md                          # mq-deadline、none等调度器优化
│   ├── Filesystem-Optimization.md               # XFS、EXT4挂载参数优化
│   └── Storage-Performance-Cases.md             # IO瓶颈排查案例
│
├── 05-Kubernetes-Node-Kernel-Optimization
│   ├── Container-Kernel-Requirements.md         # Kubernetes对Linux内核依赖
│   ├── Cgroup-Optimization.md                   # cgroup v1/v2资源管理
│   ├── Namespace-Optimization.md                # Namespace隔离机制
│   ├── Kube-Node-Sysctl.md                      # Kubernetes节点sysctl参数优化
│   ├── Network-Kernel-Parameters.md             # Pod网络相关内核参数
│   ├── Memory-Kernel-Parameters.md              # Pod内存管理相关参数
│   ├── Kernel-Modules.md                        # br_netfilter、overlay等模块
│   └── Kubernetes-Node-Tuning-Cases.md          # K8s节点性能优化案例
│
├── 06-Linux-Security-Hardening
│   ├── Security-Baseline.md                     # Linux安全基线、CIS Benchmark
│   ├── SSH-Security.md                          # SSH安全加固
│   ├── Permission-Management.md                 # 用户权限、sudo、PAM
│   ├── Firewall-Audit.md                        # 防火墙、iptables/nftables、audit
│   ├── SELinux-AppArmor.md                      # 强制访问控制
│   └── Security-Hardening-Cases.md              # 安全加固案例
│
└── 07-Production-Troubleshooting-Cases
    ├── CPU-High-Usage.md                        # CPU高占用、Load异常排查
    ├── Memory-OOM.md                            # 内存不足、OOM Killer分析
    ├── Network-Latency.md                       # 网络延迟、丢包、连接异常
    ├── Disk-IO-Bottleneck.md                    # IO等待、磁盘性能问题
    ├── Kernel-Parameter-Issues.md               # 内核参数异常案例
    └── Kubernetes-Node-Issues.md                # Kubernetes节点故障案例