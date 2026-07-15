# 03‑secret‑env.md（纯实操）
## 实验目标
1. 将Secret字段注入Pod环境变量；
2. 区分 env 注入方式和 volume 挂载方式的差异；
3. 验证环境变量模式下更新Secret之后，Pod环境变量不会自动刷新；
4. 掌握 envFrom 一次性导入全部secret键值。
## 实验环境
k8s‑v1.32.13，master‑01：192.168.11.161，namespace: dev

## 步骤1：重建secret资源
```bash
kubectl create secret opaque db-secret -n dev \
--from-literal=DB_USER=root \
--from-literal=DB_PASS=Admin@123456
kubectl get secret db-secret -n dev
```

## 方式1：env.valueFrom 单独引用secret的指定key
pod-secret-env.yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-env-pod
  namespace: dev
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["sleep","86400"]
    env:
    - name: DB_USERNAME
      valueFrom:
        secretKeyRef:
          name: db-secret
          key: DB_USER
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-secret
          key: DB_PASS
```
```bash
kubectl apply -f pod-secret-env.yaml
kubectl get pod secret-env-pod -n dev
```

### 进入容器查看环境变量
```bash
kubectl exec -it secret-env-pod -n dev -- sh
env | grep DB_
```
容器内环境变量是明文。

## 方式2：envFrom 一次性加载secret里面所有key（生产便捷用法）
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-envfrom-pod
  namespace: dev
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["sleep","86400"]
    envFrom:
    - secretRef:
        name: db-secret
```
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: secret-envfrom-pod
  namespace: dev
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["sleep","86400"]
    envFrom:
    - secretRef:
        name: db-secret
EOF
kubectl exec -it secret-envfrom-pod -n dev -- sh
env | grep -E "DB_USER|DB_PASS"
```

## 步骤3：核心对比实验（面试高频考点）
### 3‑1 更新secret里面的密码
```bash
kubectl create secret opaque db-secret -n dev \
--from-literal=DB_USER=root \
--from-literal=DB_PASS=NewPass@789 \
--dry-run=client -o yaml | kubectl apply -f -
```
### 3‑2 查看两种方式表现差异
1. volume挂载方式：修改secret后1‑2min文件内容自动更新；
2. env环境变量方式：**环境变量不会自动刷新，只有重建Pod才会生效**。
```bash
kubectl exec -it secret-env-pod -n dev -- sh
env | grep DB_PASSWORD
# 仍然是旧密码
```
原因：Pod启动阶段环境变量被写入进程内存，后续secret变更无法刷新内存中的环境变量。

## 步骤4：生产选型建议（实操结论）
1. 如果程序可以动态读取文件：优先使用secret volume；secret修改不用重启Pod；
2. 如果应用只能读取环境变量：选用env或者envFrom；修改secret必须滚动重启Pod；
3. 安全层面缺点：
   - 执行 `ps -ef` 或者查看容器进程列表可以看到环境变量；
   - 容器内的所有进程都能读取环境变量，安全性弱于volume挂载方式。

## 步骤5：清理资源
```bash
kubectl delete pod secret-env-pod secret-envfrom-pod -n dev
kubectl delete secret db-secret -n dev
rm -f pod-secret-env.yaml
```

## 实验验收标准
1. 使用valueFrom单独导入secret字段；
2. 使用envFrom批量导入secret全部key；
3. 验证env模式secret更新不会自动生效；
4. 分清volume和env两种方案优缺点。

下一节：04‑harbor‑imagepullsecret.md。