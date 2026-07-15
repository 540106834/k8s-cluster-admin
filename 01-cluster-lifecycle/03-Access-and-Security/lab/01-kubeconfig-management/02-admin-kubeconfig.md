# 02‑admin‑kubeconfig.md 纯实操内容，去掉多余理论，只做命令和操作
## 实验目标
1. 理解 `/etc/kubernetes/admin.conf` 由来和权限级别
2. 提取 admin 证书对应的用户身份：`kubernetes‑admin`
3. 复制一份管理员配置给到普通用户，做权限管控；了解生产中不允许随意分发 admin.conf
4. 使用 `kubectl auth can‑i` 验证集群管理员权限范围。

## 环境信息
集群版本：v1.32.13
master节点：192.168.11.161

## 步骤1：查看 admin.conf 文件属性
登录 k8s‑master‑01
```bash
# 查看文件来源，kubeadm部署集群自动生成
ls -l /etc/kubernetes/admin.conf
# 权限默认600，仅root可读，防止泄露
stat /etc/kubernetes/admin.conf

# 查看配置内容
kubectl config view --kubeconfig=/etc/kubernetes/admin.conf
```
从配置里可以看到：
- user名称：`kubernetes-admin`
- cluster名称：kubernetes
- APIServer地址：`https://192.168.11.161:6443`

## 步骤2：确认 kubernetes‑admin 对应的ClusterRole
kubernetes‑admin 默认绑定集群内置 ClusterRole `cluster‑admin`，拥有集群最高权限。
```bash
# 查看绑定关系
kubectl cluster-info
kubectl describe clusterrolebinding kubernetes-admin
```
> 重点：cluster‑admin 内置权限：对集群所有资源拥有增删改查权限，生产严禁把该配置给到开发人员。

## 步骤3：把admin.conf拷贝给普通用户做测试
```bash
# 创建普通用户家目录示例
mkdir -p /home/dev/.kube
# 复制管理员配置文件
cp /etc/kubernetes/admin.conf /home/dev/.kube/config
chown dev:dev /home/dev/.kube/config
chmod 600 /home/dev/.kube/config
```
切换到dev用户验证权限：
```bash
su dev
kubectl get nodes
kubectl get pods -A
kubectl delete pod -n kube-system $(kubectl get pods -n kube-system|head -1|awk '{print $1}')
```
这里验证：拿到admin.conf就具备集群超级管理员权限。实验结束后回收配置：
```bash
rm -rf /home/dev/.kube
```

## 步骤4：解析admin证书里的用户身份（实操）
1. 提取client‑certificate‑data内容从admin.conf；
2. base64解码：
```bash
# 把client-certificate‑data的值替换进去
echo "证书base64字符串" | base64 -d > admin.crt
# 查看证书里的username和groups
openssl x509 -in admin.crt -text -noout
```
观察结果：
- Subject: CN = kubernetes‑admin, O = system:masters
只要用户属于 `system:masters` 用户组，自动绑定cluster‑admin权限，这是K8s内置逻辑。

## 步骤5：权限验证命令（重点）
```bash
# 指定kubeconfig判断能不能删除节点
kubectl auth can-i delete nodes --kubeconfig=/etc/kubernetes/admin.conf
# 是否可以修改集群资源
kubectl auth can-i create clusterroles --kubeconfig=/etc/kubernetes/admin.conf
```
返回yes代表允许。

## 步骤6：生产最佳实践（实操层面）
1. 禁止把 `/etc/kubernetes/admin.conf` 下发给业务人员；
2. 日常运维人员不要长期使用admin配置，后续实验通过openssl新建用户，绑定最小RBAC权限；
3. 定期检查哪些节点存在admin.conf：
```bash
find /etc/kubernetes -name "admin.conf"
```

## 实验验证标准
1. 确认 `kubernetes‑admin` 属于 `system:masters`；
2. 复制admin.conf后可以任意操作集群资源；
3. 能通过openssl解析证书拿到用户名和用户组；
4. 理解生产环境不能分发admin.conf的原因。

## 常见问题
1. 文件权限不是600：会有安全告警，其他人读取证书后接管集群；
2. 证书过期：后续05‑certificate‑management章节处理；
3. 很多运维人员习惯把admin‑conf拷贝到自己家目录，这是违规操作。

如果你需要，我继续写 `03‑create‑user‑kubeconfig.md`。