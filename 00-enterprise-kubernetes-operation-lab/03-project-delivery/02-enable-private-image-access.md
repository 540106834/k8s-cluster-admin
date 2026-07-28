# enable-private-image-access.md
# Namespace 配置 Harbor 私有镜像免密拉取完整操作手册
## 一、文档定位
本文基于企业私有Harbor镜像仓库，实现**单个项目命名空间统一配置镜像拉取权限**：创建ImagePullSecret、绑定默认ServiceAccount、区分DEV/UAT/PROD机器人账号、全命名空间Pod自动免密拉取私有镜像；  
前置依赖`create-project-workspace.md`、`build-harbor-registry.md`、`configure-containerd-registry.md`，下游关联`validate-project-environment.md`。

## 二、前置准备
### 2.1 前置资源与信息
1. Harbor 私有仓库域名：`harbor.jinshaoyong.com`
2. 区分环境机器人只读账号（严禁使用管理员账号）
   - dev环境：robot-dev-readonly / 机器人密钥
   - uat环境：robot-uat-readonly / 机器人密钥
   - prod环境：robot-prod-readonly / 机器人密钥
3. 目标业务命名空间：`dev-demo` / `uat-demo` / `prod-demo`
4. 集群所有节点 containerd 已完成私有仓库证书配置（configure-containerd-registry.md）
5. Harbor 对应项目已授权机器人账号只读权限

### 2.2 核心原理说明
1. ImagePullSecret：存放Harbor镜像仓库账号密码的Secret资源，用于容器拉取镜像鉴权
2. 绑定Namespace默认ServiceAccount：无需每个Deployment单独配置`imagePullSecrets`，该命名空间所有Pod自动继承密钥
3. 环境隔离：三套环境使用独立机器人账号，权限最小化，某环境账号泄露不影响其他环境

## 三、步骤1：在目标Namespace创建镜像拉取Secret
### 3.1 命令行一键创建Secret（推荐，无需YAML明文）
```bash
# 替换参数：命名空间、Harbor域名、机器人账号、机器人密码
# 机器人账号：
# robot$addons 需要加''
# BGvqy2N9AHpGxNo9tnjbWLuBm7BACtYK

kubectl create secret docker-registry harbor-pull-secret \
-n default \
--docker-server=harbor.jinshaoyong.com \
--docker-username='robot$addons' \
--docker-password=BGvqy2N9AHpGxNo9tnjbWLuBm7BACtYK
```

### 3.2 YAML静态文件创建（适用于GitOps流水线）
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-pull-secret
  namespace: dev-demo
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: |
    eyJhY3Rpb25zIjp7ImhhcmJvci5leGFtcGxlLmNvbSI6eyJ1c2VybmFtZSI6InJvYm90LWRldi1yZWFkb25seSIsInBhc3N3b3JkIjoiUm9ib3REZXZAMjAyNiJ9fX0=
```
> 说明：data内容由`docker config json` base64编码生成，禁止明文存放账号密码在代码仓库。

### 3.3 校验Secret创建成功
```bash
kubectl get secret -n $NS harbor-pull-secret
# 查看Secret详情，确认仓库地址与账号
kubectl describe secret -n $NS harbor-pull-secret
```

## 四、步骤2：绑定Secret至命名空间默认ServiceAccount（全局免密核心）
每个Namespace自带名为`default`的ServiceAccount，所有Pod默认自动使用该SA。将镜像密钥绑定至SA后，该命名空间下所有Deployment/StatefulSet/Pod无需单独配置imagePullSecrets。
```bash
export NS=dev-demo
# 编辑default serviceaccount，添加imagePullSecrets
kubectl edit sa default -n $NS
```
### 补充配置片段
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: dev-demo
imagePullSecrets:
- name: harbor-pull-secret # 上一步创建的secret名称
```

### 批量脚本一键绑定（无需手动编辑yaml）
```bash
export NS=dev-demo
kubectl patch serviceaccount default -n $NS -p '{"imagePullSecrets": [{"name": "harbor-pull-secret"}]}'
```

### 校验绑定生效
```bash
kubectl describe sa default -n $NS | grep ImagePullSecrets
# 输出显示 harbor-pull-secret 即代表绑定成功
```

## 五、步骤3：连通性验证（创建测试Pod拉取私有镜像）
### 5.1 测试Pod yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: harbor-pull-test
  namespace: dev-demo
spec:
  containers:
  - name: test
    image: harbor.jinshaoyong.com/dev/busybox:1.36
    command: ["sleep","300"]
```
### 5.2 执行创建并验证状态
```bash
kubectl apply -f test-pod.yaml
# 观察Pod状态，无ErrImagePull报错，状态为Running
kubectl get pod harbor-pull-test -n dev-demo
# 查看Pod事件排查拉取失败原因
kubectl describe pod harbor-pull-test -n dev-demo
# 清理测试Pod
kubectl delete pod harbor-pull-test -n dev-demo
```

## 六、多环境差异化配置规范
### 1. DEV 开发环境
- 机器人账号：robot-dev-readonly
- Harbor项目：dev/*，允许开发临时镜像
- 权限：仅拉取，无推送权限

### 2. UAT 测试环境
- 机器人账号：robot-uat-readonly
- Harbor项目：uat/*，仅允许测试稳定版本镜像

### 3. PROD 生产环境
- 机器人账号：robot-prod-readonly
- Harbor项目：prod/*，严格限制镜像标签，禁止临时开发镜像
- 安全规范：机器人密钥定期轮换，留存轮换记录

## 七、GitOps 流水线标准化落地方案
1. 各环境Secret通过外部密钥管理系统（Vault）注入，不存入代码仓库
2. 交付平台自动化创建Namespace时，自动执行创建secret、绑定sa脚本
3. 新增项目命名空间自动分配对应环境Harbor机器人账号

## 八、高频故障与排查方案
### 故障1：Pod 报错 ErrImagePull，401 Unauthorized
根因：Secret账号密码错误、机器人无项目只读权限、SA未绑定imagePullSecrets
排查：
1. 登录Harbor后台校验机器人账号密码与项目权限
2. `kubectl describe sa default` 确认绑定secret
3. 手动在节点执行`crictl pull 私有镜像地址`验证仓库连通性

### 故障2：单个Deployment可以拉取，同命名空间其他Pod拉取失败
根因：仅在该Deployment手动配置imagePullSecrets，未绑定默认SA
修复：执行SA补丁命令，全局绑定secret

### 故障3：x509证书不信任报错
根因：节点containerd未配置Harbor CA证书，参考`configure-containerd-registry.md`全节点分发证书

### 故障4：密钥轮换后Pod依然拉取失败
根因：Secret已更新，但原有运行Pod缓存旧密钥
处理：滚动重启Deployment，重建Pod加载新Secret

### 故障5：跨命名空间拉取镜像返回401
根因：每个Namespace独立Secret，未在目标NS创建对应镜像密钥
规范：每个Namespace单独创建独立pull secret，不跨NS复用

## 九、生产运维标准化规范
1. 严格环境隔离：DEV/UAT/PROD使用独立Harbor机器人账号，权限最小化，仅分配只读拉取权限
2. 禁止将账号密码明文写入YAML、代码仓库，使用`kubectl create secret docker-registry`命令行创建
3. 所有命名空间必须绑定默认ServiceAccount实现全局免密，禁止每个业务单独配置imagePullSecrets
4. 机器人密钥每90天定期轮换，轮换后同步更新各Namespace Secret并滚动业务Pod
5. 集群交付、项目命名空间交付必须校验镜像拉取功能（validate-project-environment.md）
6. 废弃Namespace删除时同步清理对应ImagePullSecret，回收机器人权限
7. 生产环境禁止使用公共匿名镜像拉取，全部私有仓库走机器人鉴权

## 十、关联文档索引
create-project-workspace.md 项目Namespace创建全流程
build-harbor-registry.md Harbor仓库机器人账号创建
configure-containerd-registry.md 集群节点containerd仓库证书配置
validate-project-environment.md 项目环境镜像拉取验收标准
06-network-debug.md 镜像拉取网络、鉴权故障排查工具