# 03‑worker‑node‑management/10‑runbooks.md
## 一、文档基础信息
- 文件路径：`03‑worker‑node‑management/10‑runbooks.md`
- 前置文档：本目录全部文档，`07‑monitoring‑and‑troubleshooting`故障排查文档
- 集群基准：Kubernetes‑1.32.13、containerd‑2.1.5、Lease心跳、Calico‑3.30.4、CSI‑node、Ubuntu‑22.04，内网环境。
- 适用环境：DEV / FAT / UAT / PROD
- 文档作用：整理worker‑node高频故障Runbook，固定：现象 → 排查步骤 → 临时恢复方案 → 根治方案 → 事后复盘；生产出现故障直接对照执行；区分**一级紧急故障、二级普通故障**。

## 通用前置约定
### 1. 故障分级
1. **P1‑一级紧急故障（短信+企业微信告警，7×24响应）**
    - Node NotReady、磁盘100%、inode耗尽、kubelet持续崩溃、大批Pod被驱逐、节点宕机。
    - 处置原则：优先恢复业务，再排查根因；禁止长时间深挖根因导致故障扩大。
2. **P2‑二级故障（工作时段处理）**
    - PLEG延迟偏高、偶尔驱逐Pod、容器镜像GC失败、内核少量报错。
3. **禁止操作清单（PROD红线）**
    1. 故障期间禁止同时操作2台及以上节点；
    2. drain排空严禁使用`--force`；
    3. 禁止随意修改evictionHard驱逐阈值；
    4. 重启kubelet/containerd优先选择凌晨低峰；故障紧急场景除外。

### 2. 统一排查执行顺序（所有节点故障遵守）
1. master端执行：查看node Conditions、Lease续约、events；
2. 登录故障节点：依次检查 `systemctl kubelet → containerd → 磁盘/inode → 内核dmesg → CNI → CSI`；
3. 恢复服务；
4. 核查监控指标；
5. 根因分析，补充告警规则。

---

# Runbook‑1：Node‑NotReady（最高频 P1故障）
## 1.故障现象
`kubectl get nodes`显示节点状态NotReady；业务Pod有可能被驱逐。
## 2.排查步骤（严格顺序）
1. 查看节点四个压力条件：
    ```bash
    kubectl describe node node‑10‑0‑10‑21 | grep -E "Ready|MemoryPressure|DiskPressure|PIDPressure"
    ```
    - Disk‑Pressure=true：优先执行`df -h && df -i`查看磁盘和inode；
    - Memory‑Pressure=true：内存不足kubelet开始驱逐Pod；
2. 检查Lease续约情况：
    ```bash
    kubectl get lease node‑10‑0‑10‑21 -n kube-system -o yaml
    ```
    - lastRenewTime距离现在超过20s → kubelet停止上报心跳；登录节点排查kubelet。
3. 登录节点查看kubelet状态和日志：
    ```bash
    systemctl status kubelet
    journalctl -u kubelet -f
    ```
    常见报错：
    - 无法连接apiserver：防火墙6443/10250端口拦截、chronyd时间偏差＞150ms；
    - PLEG relist interval过高：磁盘IO压力过大；
    - config.yaml权限不是600；
4. 检查containerd状态：
    ```bash
    systemctl status containerd
    journalctl -u containerd
    crictl info
    ```
    重点核查：cgroup‑driver是否为systemd；镜像仓库连通性；sandbox创建失败；
5. 查看内核报错：
    ```bash
    dmesg -T
    ```
    查看OOM‑kill是否杀掉kubelet或containerd进程。
6. 检查calico‑node、csi‑node Pod状态：
    ```bash
    kubectl get pods --field-selector spec.nodeName=node‑10‑0‑10‑21 -n kube-system
    ```
## 3.临时恢复方案
1. 磁盘/inode耗尽：清理容器日志和废弃镜像；
    ```bash
    crictl images | grep "<none>"
    ```
2. 时间不同步：修复chronyd；
3. containerd异常：`systemctl restart containerd`；
4. kubelet配置问题：修复配置文件权限600后重启kubelet；
> 重启kubelet不会删除正在运行的Pod。
## 4.根治方案
1. inode耗尽：开启容器日志轮转（max‑files=5，max‑size=50Mi）；定期清理旧日志；
2. PLEG延迟过高：更换SSD磁盘，拆分Pod分摊到更多节点；
3. 防火墙问题：固化ufw白名单配置；
4. chronyd：所有节点统一同步内网chrony服务器；
## 5.复盘
- node‑exporter开启告警：磁盘使用率＞80%、inode＞80%提前预警。

---

# Runbook‑2：节点宕机（服务器硬件/内核panic，P1故障）
## 1.现象
节点关机或内核崩溃；Lease长时间无法续约；Node‑Controller等待5分钟之后开始重建Pod。
## 2.排查步骤
1. master端查看Lease续约时间，确认是否超过5分钟：
    ```bash
    kubectl get lease node‑10‑0‑10‑21 -n kube-system -o yaml
    ```
2. 查看事件：`kubectl get events -n kube-system`确认节点宕机事件；
3. 登录机房控制台查看服务器硬件日志：硬件故障、内核panic、电源故障；
4. 若服务器只是内核panic：查看`/var/log/kern.log`内核崩溃堆栈。
## 3.临时恢复方案（分两种场景）
### 场景A：服务器可以重启
1. 启动服务器；等待kubelet自动续约Lease；
2. 原有旧Pod会被控制器清理；新Pod已经在其他节点运行；
3. 节点恢复之后执行uncordon，如果之前做过cordon；
### 场景B：硬件损坏，服务器无法修复（退役节点）
1. 确认Pod已经在其他节点重建完成；
2. 在master执行删除node对象：
    ```bash
    kubectl delete node node‑10‑0‑10‑21
    ```
3. 清理CSI‑node残留注册信息；清理Prometheus配置；更新机房资产清单。
## 4.根治方案
1. 硬件故障：更换硬件；
2. 内核panic：升级内核版本，升级containerd‑2.1.5稳定版本；
3. 定期做节点宕机演练，验证Pod跨节点重建逻辑。
## 5.复盘
- 开启硬件监控；内核崩溃日志自动推送告警。

---

# Runbook‑3：Disk‑Pressure磁盘压力，inode耗尽（P1故障）
## 1.现象
`DiskPressure=true`，kubelet自动执行镜像GC，GC无效后驱逐Pod；严重节点NotReady。
## 2.排查步骤
```bash
df -h
df -i
# 查看kubelet GC日志
journalctl -u kubelet | grep -i garbage
# 查看容器日志占用
du -sh /var/log/containers
```
常见原因：
1. inode耗尽：容器日志碎片过多，小文件泛滥；
2. 磁盘空间满：core文件、备份文件、容器日志；
3. containerd镜像堆积大量无用镜像。
## 3.临时恢复
1. 清理悬空镜像：`crictl rmi $(crictl images | grep "<none>" | awk '{print $3}')`；
2. 清理`/var/log/containers`过期日志；
3. 清理宿主机core‑dump文件；
## 4.根治方案
1. kubelet配置日志轮转：`containerLogMaxSize:50Mi、containerLogMaxFiles:5`；
2. 长期扩容磁盘分区；日志数据迁移至PVC；
3. 定时清理脚本清理废弃镜像。
## 5.复盘
node‑exporter配置告警：磁盘＞80%、inode＞80%触发Warning告警。

---

# Runbook‑4：Memory‑Pressure内存压力，Pod被kubelet驱逐（P1故障）
## 1.现象
Memory‑Pressure=true；events出现`Evicted`事件，Pod被驱逐重建。
## 2.排查步骤
1. 查看被驱逐Pod清单：
    ```bash
    kubectl get events -A | grep Evicted
    ```
2. 分析Pod QoS等级：Best‑Effort最先被驱逐；其次Burstable；
3. 登录节点查看内存占用，判断是业务内存泄漏还是资源配置不足；
    ```bash
    top
    crictl stats
    ```
4. 区分：kubelet驱逐Pod vs 内核OOM‑kill（dmesg查看）。
## 3.临时恢复
1. 临时扩容节点内存；
2. 缩减非核心业务副本；
3. 临时调高Pod内存limits。
## 4.根治方案
1. 业务侧修复内存泄漏代码；
2. 中间件设置Guaranteed模式；普通微服务合理配置requests和limits；禁止Best‑Effort；
3. 节点分散部署更多Pod分摊压力。
## 5.复盘
Prometheus监控Pod内存实际占用，超过80%limits提前告警。

---

# Runbook‑5：执行kubectl drain排空节点失败（P2故障）
## 1.现象
执行drain命令卡住或者报错，无法完成Pod迁移。
## 2.排查步骤
1. dry‑run预执行查看将要驱逐哪些Pod：
    ```bash
    kubectl drain node‑10‑0‑10‑21 --ignore-daemonsets --delete-emptydir-data --dry-run=client
    ```
2. 失败分三类：
    - 原因1：PDB限制，驱逐后可用副本低于minAvailable；
    - 原因2：存在裸Pod（没有控制器管理）；
    - 原因3：empty‑dir未加`--delete‑emptydir‑data`参数；
    - 原因4：新Pod在其他节点启动失败（镜像拉取失败、PVC挂载失败）。
    ```bash
    kubectl get events -n prod
    ```
## 3.处理方案
1. PDB约束：优先扩容副本数；FAT/UAT可临时调高maxUnavailable，PROD必须工单审批；
2. 裸Pod：确认业务安全后手动删除裸Pod，生产禁止使用`--force`；
3. empty‑dir：带上`--delete‑emptydir‑data`参数；
4. 新Pod启动失败：解决镜像、准入、PVC问题之后继续排空。
## 4.最佳实践
生产环境严格分批排空：一台排空完成观察5‑10分钟再操作下一台节点。

---

# Runbook‑6：PLEG‑Relist间隔过高（P2隐患问题，后期极易造成NotReady）
## 1.现象
kubelet日志出现：`PLEG relist interval >1000ms`；正常＜500ms；
## 2.排查原因
1. 磁盘iowait过高（SSD性能不足）；
2. 节点Pod数量过多；
3. inotify参数不足；
4. containerd版本BUG。
## 3.临时处理
1. 降低磁盘IO压力，清理大文件；
2. 调高内核inotify参数：
    ```bash
    fs.inotify.max_user_watches=524288
    fs.inotify.max_user_instances=8192
    ```
## 4.根治方案
1. 更换SSD高速磁盘；
2. 将部分Pod调度到其他节点；
3. containerd升级至2.1.5稳定版本。
## 5.监控配置
kubelet‑metrics配置告警：PLEG间隔＞800ms触发告警。

---

# Runbook‑7：containerd异常，crictl info超时（P1故障）
## 1.现象
`crictl info`长时间超时；kubelet无法创建容器；节点NotReady。
## 2.排查步骤
```bash
systemctl status containerd
journalctl -u containerd
ls /run/containerd/containerd.sock
```
常见原因：
1. containerd卡死；
2. cgroup驱动配置错误（cgroupfs/systemd不匹配）；
3. harbor镜像仓库DNS解析失败；
4. inotify资源耗尽。
## 3.恢复方案
1. 重启containerd：`systemctl restart containerd`；
2. 修正`config.toml` cgroup驱动为systemd；
3. 修复内网DNS解析问题；
## 4.根治方案
1. containerd版本固定2.1.5；
2. 内核参数提前配置inotify上限。

---

# Runbook‑8：内核OOM‑kill杀死kubelet/containerd（P1故障）
## 1.现象
dmesg日志出现`Out‑of‑Memory: Killed process kubelet`；kubelet进程被内核杀掉；节点NotReady。
## 2.排查步骤
1. 查看内存占用，确认哪些Pod占用大量内存；
2. 区分：容器内存超限触发内核OOM还是节点整体内存不足。
## 3.临时恢复
重启kubelet：`systemctl restart kubelet`；
## 4.根治方案
1. 调高节点内存；
2. 限制Pod内存limits；优化应用代码；
3. vm.overcommit_memory=1内核参数配置。

---

# Runbook‑9：节点退役下线失败（P2）
## 1.现象
执行`kubectl delete node xxx`之后CSI‑node残留注册信息。
## 2.解决步骤
1. 确认节点已经drain完毕；
2. 删除CSI‑node对应对象；
3. 清理该节点残留volume信息；
4. 清理Prometheus监控配置；
## 3.最佳实践
节点退役严格执行：dry‑run → drain → delete node → 关闭服务器。

## 十一、生产通用应急执行清单（PROD强制遵守）
1. P1故障出现：
    - 第一步：先恢复业务，再深挖根因；
    - 第二步：故障解决之后，导出kubelet、containerd、dmesg日志保存；
    - 第三步：填写故障复盘文档：现象、时间线、根因、临时方案、长期修复方案、新增告警项；
2. 所有节点操作记录写入apiserver审计日志；
3. 定期演练：每季度模拟节点宕机，验证Pod跨节点重建是否正常；
4. 所有故障问题归类整理，持续优化Prometheus告警，做到事前预警。

## 十二、关联文档
1. `05‑node‑troubleshooting.md`：节点排障详细原理；
2. `04‑node‑lifecycle.md`：节点生命周期；
3. `06‑kubelet‑runtime.md`：kubelet配置与PLEG；
4. `08‑resource‑pressure.md`：驱逐原理；
5. `07‑monitoring‑and‑troubleshooting`：监控告警配置。