# cluster‑deploy‑docs/certificate‑management.md

## 一、文档基础信息

- 文件路径：`cluster‑deploy‑docs/certificate‑management.md`
- 前置文档：`00‑cluster‑init‑overview.md`、`05‑kubeadm‑init.md`、`authentication.md`、`kubeconfig.md`
- 集群版本：Kubernetes‑1.32.13，kubeadm部署集群；采用PKI非对称加密体系；
- 文档适用范围：集群全部组件证书：根CA、apiserver、etcd、kube‑controller‑manager、kube‑scheduler、kubelet客户端‑服务端证书、证书检查、证书到期续期、手动续签、证书损坏故障恢复、生产生命周期管控。
- 整体逻辑：K8s组件之间通信全部采用TLS双向认证；客户端出示客户端证书，服务端校验证书合法性，完成X509认证。

## 二、K8s PKI整体体系概述

### 2.1 目录结构（kubeadm初始化自动生成）

所有证书默认存放在master节点`/etc/kubernetes/pki`：

```bash
/etc/kubernetes/pki
├── ca.crt、ca.key                # 集群根CA（最高信任根）
├── apiserver.crt apiserver.key   # apiserver服务端证书
├── apiserver-kubelet-client.crt  # apiserver访问kubelet(10250)使用的客户端证书
├── front-proxy-ca.crt front-proxy-ca.key # 前置代理CA
├── front-proxy-client.crt
└── etcd/
    ├── ca.crt ca.key             # etcd独立CA（etcd私有根证书）
    ├── server.crt server.key     # etcd服务端证书
    ├── peer.crt peer.key         # etcd节点之间通信证书
    └── healthcheck-client.crt    # apiserver访问etcd的客户端证书
```

1. **两级CA架构**
   - 集群全局CA：签发apiserver、kube‑controller‑manager、kube‑scheduler、kubelet客户端证书；
   - etcd独立CA：etcd有自己独立CA密钥对，不和集群CA共用；保证etcd数据库访问安全。
2. 证书签发规则
   - 私钥`.key`仅对应组件本地保存；
   - `.crt`公钥证书分发到通信对端；
   - 只有根CA签发的证书才会被对方信任；非CA签发证书直接返回401。
3. 默认有效期（kubeadm内置）
   - 由CA签发的组件证书（apiserver、controller‑manager、scheduler、etcd相关证书）有效期 **1年**；到期集群组件通信失败；
   - 管理员kubeconfig（admin.conf）证书有效期10年；
   - kubelet客户端证书默认1年；kubelet开启自动续期功能。

### 2.2 组件之间证书使用明细
1. apiserver‑6443：apiserver加载`apiserver.crt/apiserver.key`，提供HTTPS服务；客户端使用各自客户端证书连接apiserver；
2. apiserver访问etcd：apiserver使用`etcd/healthcheck‑client.crt`连接etcd；etcd校验该证书；
3. etcd集群内部通信：peer证书，各个master节点之间etcd互相通信；
4. apiserver访问kubelet（10250端口）：apiserver使用`apiserver‑kubelet‑client.crt`访问worker节点kubelet；
5. kubelet访问apiserver：kubelet证书由集群CA签发；每1年到期前kubelet自动向apiserver申请更新证书；
6. kube‑controller‑manager、kube‑scheduler：使用各自客户端证书访问apiserver；

## 三、各类证书详细说明
### 3.1 集群根CA（ca.crt、ca.key）【重中之重】
1. 作用：整个集群信任锚点；签发apiserver、controller‑manager、scheduler、kubelet证书；
2. 有效期：默认10年；
3. 安全约束：
   - `ca.key`只保存在master节点；严禁外泄；一旦泄露攻击者可以伪造任意证书接管整个集群；
   - 集群扩容、新增worker‑node时，worker节点必须持有ca.crt用来校验apiserver证书；
4. 注意：**根CA过期整个集群无法修复，集群必须重建；所以根CA密钥严格保管**。

### 3.2 apiserver证书（apiserver.crt / apiserver.key）
1. SAN字段包含：
   - master节点内网IP、VIP（高可用模式）、127.0.0.1、kubernetes.default.svc、集群service网段域名；
2. 使用场景：worker节点、kubectl客户端连接6443时校验apiserver身份；
3. 到期后果：kubectl访问集群401；kubelet无法和apiserver通信，节点全部NotReady；
4. 当后期增加新master节点或者修改VIP时，需要重新生成apiserver证书。

### 3.3 etcd整套证书（独立CA）
1. etcd‑CA：专门签发etcd内部证书；
2. server证书：etcd对外提供服务的证书；
3. peer证书：etcd集群成员之间通信；多master集群必须依赖peer证书；
4. healthcheck‑client：apiserver连接etcd使用；
5. 到期后果：apiserver无法写入etcd，集群完全瘫痪。

### 3.4 控制平面组件客户端证书
1. kube‑controller‑manager证书：CN=system:kube‑controller‑manager，被识别为内置控制器用户；
2. kube‑scheduler证书：CN=system:kube‑scheduler；
   - 两个组件证书由集群CA签发；内置ClusterRoleBinding授予对应权限；证书过期对应组件失效；Pod无法调度、副本无法维持。

### 3.5 kubelet证书（分为客户端证书和kubelet服务端证书）
1. kubelet客户端证书：kubelet向apiserver上报Lease、Pod状态使用；
   - kube‑apiserver配置允许kubelet自动续期：`RotateCertificates: true`；kubelet在到期前自动更新客户端证书，无需人工干预；
2. kubelet服务端证书：worker节点10250端口提供https服务，apiserver访问kubelet时使用；该证书不会自动续期，1年到期需要手动更新；
3. 证书存放路径：`/var/lib/kubelet/pki/`。

### 3.6 kubeconfig内部证书
admin.conf、controller‑manager.conf、scheduler.conf内部嵌入客户端证书；
- admin.conf：CN=kubernetes‑admin,O=system:masters（超级管理员）有效期10年；
- controller‑manager.conf、scheduler.conf证书有效期1年。

## 四、证书检查命令（日常巡检必备）
### 4.1 kubeadm内置命令（最简单）
```bash
# 查看所有证书到期时间
kubeadm certs check-expiration
```
输出内容包含：证书名称、过期剩余时间、是否由kubeadm托管。

### 4.2 openssl手动查看有效期（通用方式）
```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -noout -dates
```
- notBefore：生效时间；notAfter：到期时间。

### 4.3 查看kubeconfig里面证书有效期
```bash
# 解析admin.conf中的证书
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > admin.crt
openssl x509 -in admin.crt -noout -dates
```

### 4.4 生产巡检标准
1. 剩余时间小于90天就列入待续期计划；
2. 根CA到期剩余时间提前2‑3年规划集群迁移；
3. prometheus配置监控：监控证书剩余天数，低于45天触发告警。

## 五、证书续期方案（分2种方式）
### 方式1：kubeadm一键续期（推荐，生产首选，仅适用于kubeadm托管证书）
> 前提：CA密钥完好，根CA没有过期。
1. 1年有效期组件（apiserver、etcd、controller‑manager、scheduler）一键全部续签1年：
```bash
# 在master节点执行
kubeadm certs renew all
```
2. 续期完成之后：
   - 更新对应的kubeconfig配置文件：
   ```bash
   kubeadm init phase kubeconfig all
   ```
3. 重启控制平面组件：apiserver、controller‑manager、scheduler静态Pod；
   - 静态Pod存放在`/etc/kubernetes/manifests`，删除Pod文件后kubelet自动重建容器加载新证书；
4. worker‑node的kubelet客户端证书：由kubelet自动轮换，无需人工干预；
5. kubelet服务端证书（10250端口）：在worker节点执行：
   ```bash
   kubeadm certs renew kubelet-server
   systemctl restart kubelet
   ```
> 高可用集群（3台master）：每台master节点分别执行续期操作，分批重启组件，避免集群中断。

### 方式2：手动基于CA签发证书（脱离kubeadm场景）
1. 创建csr证书请求；
2. 使用ca.key对csr签名，设置有效期；
3. 替换crt和key文件；重启对应组件；
> 生产尽量不用此方式，优先使用kubeadm certs renew。

### 4.5 单独续签某一个证书示例
```bash
# 只续期apiserver证书
kubeadm certs renew apiserver
```

## 六、故障场景处理
### 场景1：证书还未到期，证书文件丢失或者损坏
1. CA密钥完好的情况下，直接执行：
```bash
kubeadm certs renew all
```
kubeadm基于原有CA重新生成证书私钥；重启对应静态Pod即可恢复。

### 场景2：CA根密钥丢失（严重故障）
1. 情况：`/etc/kubernetes/pki/ca.key`误删除；
   - 现有证书无法续期；不能签发新证书；新增节点无法加入集群；
2. 解决方案：
   - 方案A（推荐）：重新搭建集群，业务迁移；
   - 方案B：使用证书替换工具重新生成一套CA，滚动替换集群内全部证书（操作风险极高）。

### 场景3：证书已经过期，集群无法访问（紧急修复）
1. 当apiserver证书过期，apiserver容器启动失败；
2. 临时将系统时间修改为证书有效期内；启动apiserver；
3. 执行`kubeadm certs renew all`完成续签；恢复系统时间；重启apiserver；
> 时间修改操作只作为应急方案，事后必须复盘。

### 场景4：扩容master节点后apiserver证书SAN缺少新增节点IP
1. 执行`kubeadm certs renew apiserver`；kubeadm读取kubeadm‑config.yaml配置自动更新SAN列表；重启apiserver。

### 场景5：kubelet‑server证书到期，apiserver访问10250报错401
在对应worker节点执行：
```bash
kubeadm certs renew kubelet-server
systemctl restart kubelet
```

## 七、证书生命周期全流程管理（PROD生产SOP）
1. 初始化阶段：kubeadm‑init生成整套PKI密钥，妥善备份pki目录；将`/etc/kubernetes/pki`目录加密备份至安全存储；
2. 日常巡检：每月执行`kubeadm certs check‑expiration`；Prometheus监控证书剩余有效期；
3. 续期窗口期：组件证书到期前45天，选择凌晨低峰窗口分批续期master节点证书；
4. 续期后验证：续期完成后执行`kubectl get nodes`、查看etcd健康状态、查看Pod正常运行；
5. 根CA长期规划：CA有效期剩余不足2年提前规划集群重建；
6. 废弃证书清理：删除下线master节点对应的旧证书文件。

## 八、DEV/FAT/UAT/PROD差异化标准
1. DEV：证书到期可以临时修改系统时间应急；续期时间要求宽松；定期备份可选；
2. FAT：每月检查证书有效期；到期前60天完成续期；pki目录定期备份；
3. UAT：严格按照生产流程；凌晨低峰执行续期；续期前后做业务可用性验证；加密备份pki目录；
4. PROD生产环境强制约束：
    1. master节点pki目录定期加密备份；ca.key禁止下载到办公电脑；
    2. 组件证书到期前45天执行续期；高可用集群逐台master操作，禁止同时重启所有控制平面组件；
    3. 开启Prometheus监控证书剩余天数，小于45天触发告警；
    4. 续期操作走运维工单双人复核；操作之后留存操作日志；
    5. 根CA密钥禁止外泄；禁止将*.key文件上传Git；
    6. kubelet‑server证书到期问题纳入节点巡检清单。

## 九、生产最佳实践
1. kubeadm托管证书优先使用`kubeadm certs renew`，不手动使用openssl签发证书，降低人为失误；
2. 区分两套CA：集群CA和etcd‑CA，不要混淆；
3. kubelet客户端开启自动续期，减少运维工作量；kubelet‑server证书定期人工续期；
4. 做好pki目录备份，一旦证书文件损坏可以快速恢复；
5. 高可用集群续期时逐个节点执行，保证集群全程可用；
6. 证书到期告警接入监控平台，避免遗忘续期造成集群瘫痪。

## 十、关联文档
1. `05‑kubeadm‑init.md`：kubeadm初始化生成PKI；
2. `kubeconfig.md`：证书嵌入kubeconfig；
3. `authentication.md`：X509证书认证原理；
4. `10‑troubleshooting.md`：证书过期401故障排查；
5. `09‑upgrade.md`：集群版本升级时证书自动续期。

运维文档
```
certificate-management/
│
├── certificate-overview.md            # Kubernetes PKI体系和证书关系
├── certificate-check.md               # 证书有效期检查和过期预警
├── certificate-renew.md               # kubeadm证书续签流程
├── certificate-rotation.md            # kubelet、ServiceAccount Token轮换机制
└── certificate-troubleshooting.md     # 证书异常导致API不可用排查
```