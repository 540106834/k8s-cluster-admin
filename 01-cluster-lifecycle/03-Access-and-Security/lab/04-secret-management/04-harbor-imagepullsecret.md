# 04‑harbor‑imagepullsecret.md（纯实操）
## 实验目标
1. 掌握 `kubernetes.io/docker‑config‑json` 类型Secret创建；
2. 配置imagePullSecrets，让Pod从私有Harbor仓库拉取镜像；
3. 实现ServiceAccount全局绑定imagePullSecret，该SA启动Pod自动使用仓库凭证；
4. 排查ImagePullBack‑Off和认证失败问题。
## 环境信息
- k8s‑v1.32.13，master‑01：192.168.11.161
- harbor地址：harbor.jinshaoyong.com:192.168.11.170
- harbor测试账号：admin / Harbor@123456
- namespace：dev

## 步骤1：两种方式创建docker‑config‑json类型secret
### 方式1：命令行创建（推荐实操）
```bash
kubectl create secret docker-registry harbor-pull-secret -n dev \
--docker-server=harbor.jinshaoyong.com \
--docker-username=admin \
--docker-password=Harbor@123456

kubectl get secret harbor-pull-secret -n dev
kubectl get secret harbor-pull-secret -n dev -o yaml
```
> 内部data字段`.dockerconfigjson`内容为base64编码，解码后就是docker登录配置文件。

### 方式2：手动编写yaml方式（理解内部格式）
1. 先生成config.json内容：
```bash
# 在任意节点执行登录harbor，生成docker配置
docker login harbor.jinshaoyong.com -u admin -p Harbor@123456
cat ~/.docker/config.json | base64 -w 0
```
把base64结果填入yaml：
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-pull-secret-yaml
  namespace: dev
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: 填入上面base64字符串
```
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: harbor-pull-secret-yaml
  namespace: dev
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(cat ~/.docker/config.json | base64 -w 0)
EOF
```

## 步骤2：Pod清单里指定imagePullSecrets（基础用法）
pod-harbor.yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: harbor-nginx-pod
  namespace: dev
spec:
  imagePullSecrets:
  - name: harbor-pull-secret
  containers:
  - name: nginx
    image: harbor.jinshaoyong.com/library/nginx:1.25-alpine
```
```bash
kubectl apply -f pod-harbor.yaml
kubectl get pod -n dev
# 正常状态为Running；如果配置错误状态为ImagePullBackOff
```

## 步骤3：进阶方案：给ServiceAccount绑定imagePullSecrets（生产重点）
每次pod里写imagePullSecrets很繁琐，可以给SA配置镜像密钥，只要使用这个SA启动Pod自动带入凭证。
```bash
kubectl create sa harbor-sa -n dev
kubectl patch serviceaccount harbor-sa -n dev -p '{"imagePullSecrets": [{"name": "harbor-pull-secret"}]}'
# 查看sa配置确认已经绑定
kubectl describe sa harbor-sa -n dev
```
测试Pod，不再填写imagePullSecrets，只指定serviceAccountName：
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sa-nginx-pod
  namespace: dev
spec:
  serviceAccountName: harbor-sa
  containers:
  - name: nginx
    image: harbor.jinshaoyong.com/library/nginx:1.25-alpine
```
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: sa-nginx-pod
  namespace: dev
spec:
  serviceAccountName: harbor-sa
  containers:
  - name: nginx
    image: harbor.jinshaoyong.com/library/nginx:1.25-alpine
EOF
kubectl get pod sa-nginx-pod -n dev
```
> 生产最佳实践：业务pod绑定专属SA，SA预先配置imagePullSecrets，yaml文件精简。

## 步骤4：排障实操：模拟账号密码错误，复现ImagePullBackOff
```bash
# 创建错误密码的secret
kubectl create secret docker-registry wrong-harbor-secret -n dev \
--docker-server=harbor.jinshaoyong.com \
--docker-username=admin \
--docker-password=WrongPass --dry-run=client -o yaml | kubectl apply -f -
```
修改pod引用错误secret：
```bash
kubectl edit pod harbor-nginx-pod -n dev
# spec.imagePullSecrets.name改为 wrong-harbor-secret
```
查看报错：
```bash
kubectl describe pod harbor-nginx-pod -n dev
# 事件提示：unauthorized: authentication required
```
排障步骤：
1. 核对secret里面用户名密码；
2. 检查harbor项目是否为私有；
3. 确认worker节点可以解析harbor.jinshaoyong.com域名；
4. 测试worker节点手动docker‑login验证账号：
```bash
docker login harbor.jinshaoyong.com -u admin -p Harbor@123456
```

## 步骤5：全局默认配置（可选）
如果整个命名空间所有Pod都要拉取harbor镜像，可以修改namespace下default SA绑定imagePullSecrets：
```bash
kubectl patch sa default -n dev -p '{"imagePullSecrets": [{"name": "harbor-pull-secret"}]}'
```

## 清理实验资源
```bash
kubectl delete pod harbor-nginx-pod sa-nginx-pod -n dev
kubectl delete secret harbor-pull-secret harbor-pull-secret-yaml wrong-harbor-secret -n dev
kubectl delete sa harbor-sa -n dev
kubectl patch sa default -n dev -p '{"imagePullSecrets": []}'
rm -f pod-harbor.yaml
```

## 实验验收标准
1. 创建`kubernetes.io/docker‑config‑json`类型Secret；
2. Pod通过imagePullSecrets成功拉取私有仓库镜像；
3. SA绑定镜像凭证，Pod不用写imagePullSecrets；
4. 能够定位镜像拉取认证失败问题。

下一节：05‑tls‑secret.md。