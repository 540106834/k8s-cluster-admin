# 08-operation-cheatsheet.md
## 一、文档基础信息
- 归属目录：`06-daily-operations/`
- 前置阅读：01~07 日常运维全套文档
- 集群基准：Kubernetes v1.32.13、多环境多集群、OIDC认证、GitOps、内网Harbor
- 环境分层：DEV / FAT / UAT / PROD
- 核心覆盖：kubectl高频命令速查，按**客户端、工作负载、配置、存储、网络、安全、调试、备份、资源清理**分类，可直接复制执行，统一运维标准简写别名

## 二、全局前置别名（所有运维主机统一配置）
```bash
# ~/.bashrc / ~/.zshrc
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias ke='kubectl exec -it'
alias kl='kubectl logs -f'
alias kt='kubectl top'
alias kctx='kubectl config use-context'
alias kauth='kubectl auth can-i'
# 环境快速切换
alias k-prod='kubectl config use-context prod-admin'
alias k-uat='kubectl config use-context uat-user'
alias k-fat='kubectl config use-context fat-dev'
# 备份导出
alias k-save='kubectl get pv,pvc,deploy,sts,svc,ingress,networkpolicy,secret -o yaml > backup-$(date +%Y%m%d).yaml'
```

# 一、kubectl 客户端 & kubeconfig 操作
```bash
# 查看所有上下文
kubectl config get-contexts
# 切换环境
kubectl config use-context prod-admin
# 查看当前上下文
kubectl config current-context
# 设置默认命名空间
kubectl config set-context --current --namespace=prod
# 导出最小化kubeconfig（分发）
kubectl config view --minify --flatten > prod-user.kubeconfig
# 权限预校验
kubectl auth can-i delete statefulset mysql -n prod --as=oidc:user:zhangsan@example.com
# 查看当前账号全部权限
kubectl auth can-i --list -n prod
# dry-run模拟操作，不真实执行
kubectl delete pvc test -n prod --dry-run=client
# 离线语法校验，不连接集群
kubectl apply -f app.yaml --dry-run=client
```

# 二、工作负载 Deployment / StatefulSet / DaemonSet
## 1. 查询资源
```bash
# 查看所有deployment
kubectl get deploy -n prod
# 查看sts完整信息
kubectl get sts -n prod -o wide
# 查看daemonset
kubectl get ds -n kube-system
# 按标签筛选
kubectl get pods -n prod -l business=order,tier=database
# 按内存/CPU排序
kubectl top pods -n prod --sort-by=memory
kubectl top pods -n prod --sort-by=cpu
# 查看资源完整详情
kubectl describe deploy order-api -n prod
# 查看发布历史
kubectl rollout history deploy order-api -n prod
# 查看发布进度实时跟踪
kubectl rollout status deploy order-api -n prod -w
```

## 2. 发布、回滚、扩缩容、重启
```bash
# 发布新版本
kubectl apply -f deploy-order.yaml -n prod
# 回滚上一版本
kubectl rollout undo deploy order-api -n prod
# 指定回滚到某个修订版本
kubectl rollout undo deploy order-api --to-revision=1 -n prod
# 扩缩容副本
kubectl scale deploy order-api --replicas=10 -n prod
kubectl scale sts mysql --replicas=3 -n prod
# 仅重启Pod（无配置变更）
kubectl rollout restart deploy order-api -n prod
# 暂停/冻结发布变更
kubectl rollout pause deploy order-api -n prod
kubectl rollout resume deploy order-api -n prod
# 单独删除单个Pod触发重建
kubectl delete pod mysql-2 -n prod
# 临时创建测试Pod
kubectl run test-temp --image=harbor.jinshaoyong.com/k8s/debug-tools:v1.0 -n prod -- sleep 3600
```

## 3. CronJob / Job 批任务
```bash
# 查看定时任务
kubectl get cronjob -n prod
# 手动执行一次定时任务
kubectl create job --from=cronjob/mysql-backup manual-backup -n prod
# 查看任务日志
kubectl logs job/manual-backup -n prod
# 暂停定时任务
kubectl patch cronjob mysql-backup -n prod -p '{"spec":{"suspend":true}}'
```

# 三、ConfigMap & Secret 配置管理
```bash
# 创建ConfigMap
kubectl create configmap nginx-conf -n prod --from-file=nginx.conf
# 创建Secret（数据库密码）
kubectl create secret generic mysql-cred -n prod --from-literal=MYSQL_PWD=xxxx
# 创建镜像拉取secret
kubectl create secret docker-registry harbor-pull -n prod \
--docker-server=harbor.jinshaoyong.com \
--docker-username=ops \
--docker-password=xxx
# 查看cm/secret
kubectl get configmap,secret -n prod
# 查看完整内容
kubectl describe configmap nginx-conf -n prod
# 解码Secret
kubectl get secret mysql-cred -n prod -o jsonpath="{.data.MYSQL_PWD}" | base64 -d
# 滚动重启加载环境变量配置
kubectl rollout restart deploy order-api -n prod
```

# 四、存储 PV / PVC / StorageClass / 快照
```bash
# 查看存储资源
kubectl get sc,pv,pvc -n prod
# 查看PVC详细事件（挂载失败）
kubectl describe pvc mysql-data -n prod
# 扩容PVC
kubectl patch pvc file-pvc -n prod --type merge -p '{"resources":{"requests":{"storage":"200Gi"}}}'
# 查看快照
kubectl get volumesnapshots -n prod
# 从快照克隆PVC恢复
kubectl apply -f pvc-restore.yaml -n prod
# 批量清理FAT过期PVC
kubectl delete pvc -n fat --field-selector metadata.phase=Released
# 查看NFS provisioner日志
kubectl logs -n kube-system deploy/nfs-provisioner
# 备份PVC导出文件
kubectl cp prod/backup-pvc:/backup/data ./local-backup
```

# 五、网络资源 Service / Ingress / NetworkPolicy / CoreDNS
```bash
# 查看service、ingress、np
kubectl get svc,ingress,networkpolicy -n prod
# 查看service后端Pod匹配标签
kubectl describe svc order-svc -n prod
# 临时修改Ingress下线业务
kubectl patch ingress order-ingress -n prod --type merge -p '{"spec":{"rules":[]}}'
# 查看网络策略
kubectl get networkpolicy -n prod
# 测试跨命名空间连通性
kubectl run test-net --image=harbor.jinshaoyong.com/k8s/debug-tools:v1.0 -n prod --rm -it -- curl mysql.prod.svc:3306
# 查看CoreDNS日志（域名解析失败）
kubectl logs -n kube-system deploy/coredns
# 查看ingress controller日志
kubectl logs -n kube-system deploy/nginx-ingress-controller
```

# 六、安全 RBAC / 审计 / 证书 / ServiceAccount
```bash
# 查看权限资源
kubectl get role,rolebinding,clusterrole,clusterrolebinding
# 创建ServiceAccount
kubectl create sa backup-sa -n prod
# 校验403权限问题
kubectl auth can-i delete pvc -n prod --as=backup-sa -n prod
# 查看集群证书过期
kubeadm certs check-expiration
# 批量续签证书
kubeadm certs renew all
# 查看审计日志实时跟踪
tail -f /var/log/k8s/audit/audit.log | jq .
# 删除高危cluster-admin绑定
kubectl delete clusterrolebinding temp-admin-bind
```

# 七、日志、事件、exec 调试命令
```bash
# 实时日志
kubectl logs -f order-api-7f98d -n prod
# 查看历史崩溃Pod日志
kubectl logs --previous mysql-0 -n prod
# 查看最近200行
kubectl logs --tail=200 order-api -n prod
# 一小时内日志
kubectl logs --since=1h order-api -n prod
# 实时事件
kubectl get events -n prod -w --sort-by=.metadata.creationTimestamp
# 进入容器交互终端
kubectl exec -it mysql-0 -n prod -- sh
# 容器内执行单次命令
kubectl exec -it test-pod -n prod -- df -h
# 临时调试Pod挂载业务PVC
kubectl apply -f debug-pod.yaml -n prod
# 删除临时调试Pod
kubectl delete pod debug-temp -n prod
```

# 八、资源标签、Patch、YAML 导出与Diff
```bash
# 批量打标签
kubectl label deploy order-api -n prod owner=ops-wang --overwrite
# 删除标签
kubectl patch deploy order-api -n prod --type json -p '[{"op":"remove","path":"/metadata/labels/old-tag"}]'
# 局部更新merge模式
kubectl patch pvc file-pvc -n prod --type merge -p '{}'
# 智能合并更新strategic
kubectl patch deploy order-api -n prod --type strategic -p '{}'
# 本地与集群对比diff
kubectl diff -f deploy.yaml -n prod
# 导出资源备份
kubectl get deploy order-api -n prod -o yaml > deploy-backup.yaml
# 全命名空间导出备份
kubectl get all -n prod -o yaml > ns-all-backup.yaml
```

# 九、节点 & 资源监控 top
```bash
# 节点资源占用
kubectl top nodes
# Pod资源占用
kubectl top pods -n prod
# 查看容器细分资源
kubectl top pod mysql-0 -n prod --containers
# 持续观测负载波动
watch -n 2 kubectl top pods -n prod
# 查看metrics-server状态
kubectl get deploy -n kube-system -l app=metrics-server
```

# 十、批量清理资源（FAT测试专用）
```bash
# 清空fat命名空间所有工作负载
kubectl delete deploy,sts,cronjob,pvc,configmap,secret -n fat --all
# 删除带temp标签临时资源
kubectl delete all -n fat -l temp=true
# 批量清理成功完成Job
kubectl delete jobs -n fat --field-selector status.successful=1
# 批量清理过期快照
kubectl delete volumesnapshots -n fat --field-selector metadata.creationTimestamp<$(date -d "3 days ago" +%Y-%m-%d)
```

# 十一、集群备份与应急
```bash
# 全集群资源导出备份
kubectl get all,storageclasses,sc,pv,clusterrole,clusterrolebinding -o yaml > cluster-full-backup.yaml
# 执行etcd快照备份
kubeadm etcd snapshot save /backup/etcd-snapshot-$(date +%Y%m%d).db
# 临时隔离业务流量（Ingress下线）
kubectl patch ingress order-ingress -n prod -p '{"spec":{"rules":[]}}'
# 暂停所有定时备份防止IO打满
kubectl patch cronjob --all -n prod -p '{"spec":{"suspend":true}}'
```

# 十二、故障快速定位组合命令
```bash
# 1. Pod启动失败先看事件
kubectl get events -n prod --sort-by=.metadata.creationTimestamp
# 2. PVC挂载失败查看pvc事件
kubectl describe pvc mysql-data -n prod
# 3. 发布卡住查看rollout状态
kubectl rollout status deploy order-api -n prod
# 4. 403权限拒绝校验账号权限
kubectl auth can-i --list -n prod --as=xxx
# 5. 高负载Pod定位
kubectl top pods -n prod --sort-by=memory
# 6. Webhook准入失败查看webhook配置
kubectl get validatingwebhookconfigurations
```