# 02‑secret‑volume.md（纯实操）
## 实验目标
1. 把Secret以Volume文件形式挂载到Pod内部；
2. 验证Secret中每个Key对应容器里一个独立文件，文件内容为明文；
3. 测试secret更新后容器内文件自动刷新；
4. 区分secret‑volume和普通emptyDir、PersistentVolume差异。
## 环境
k8s‑v1.32.13，master‑01：192.168.11.161，namespace=dev

## 步骤1：前置创建secret
```bash
kubectl create secret opaque db-secret -n dev \
--from-literal=DB_USER=root \
--from-literal=DB_PASS=Admin@123456
kubectl get secret db-secret -n dev
```

## 步骤2：编写Pod清单挂载Secret为volume
secret-volume-pod.yaml
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-volume-pod
  namespace: dev
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["sleep","86400"]
    volumeMounts:
    - name: secret-vol
      mountPath: /etc/dbconf
      readOnly: true    # 只读，容器内部无法修改
  volumes:
  - name: secret-vol
    secret:
      secretName: db-secret
      # 可选：只挂载部分key
      # items:
      # - key: DB_PASS
      #   path: password.txt
```
部署pod：
```bash
kubectl apply -f secret-volume-pod.yaml
kubectl get pod secret-volume-pod -n dev
```

## 步骤3：进入容器查看挂载结果
```bash
kubectl exec -it secret-volume-pod -n dev -- sh
ls /etc/dbconf
# 目录里出现 DB_USER  DB_PASS 两个文件
cat /etc/dbconf/DB_USER
cat /etc/dbconf/DB_PASS
```
重点结论：
1. secret的每个key对应一个独立文件；
2. 文件里面是明文，不是base64；
3. 挂载目录权限默认 0444。

## 步骤4：只选择性挂载指定key（生产常用）
修改yaml只挂载DB_PASS，并且自定义文件名：
```yaml
volumes:
- name: secret-vol
  secret:
    secretName: db-secret
    items:
    - key: DB_PASS
      path: mypass.txt
```
重新创建pod：
```bash
kubectl delete pod secret-volume-pod -n dev
kubectl apply -f secret-volume-pod.yaml
kubectl exec -it secret-volume-pod -n dev -- sh
ls /etc/dbconf
# 只会看到 mypass.txt
```

## 步骤5：验证Secret更新，容器内文件自动刷新（核心特性）
### 5‑1 修改集群中的secret
```bash
kubectl create secret opaque db-secret -n dev --from-literal=DB_PASS=NewPass@654321 --dry-run=client -o yaml | kubectl apply -f -
```
### 5‑2 等待几十秒后查看容器内部
```bash
kubectl exec -it secret-volume-pod -n dev -- sh
cat /etc/dbconf/mypass.txt
```
特点：
1. secret更新后大概1‑2分钟容器内文件自动刷新；
2. **不需要重启Pod**；
3. 进程不会自动加载新值，如果程序启动时一次性读取密码，依然需要重启Pod。

## 步骤6：安全注意事项（面试重点）
1. volume挂载方式下secret落盘在容器内为明文；
2. Node节点上kubelet会把secret解密存在宿主机的临时目录 `/var/lib/kubelet/pods/xxx`；
3. 宿主机root用户可以查看密码，生产节点权限管控非常重要；
4. mountPath配置readOnly:true防止应用篡改。

## 清理资源
```bash
kubectl delete pod secret-volume-pod -n dev
kubectl delete secret db-secret -n dev
rm -f secret-volume-pod.yaml
```

## 实验验收标准
1. Secret挂载成volume，每个key对应一个文件；
2. 可以选择性挂载指定key并自定义文件名；
3. 修改secret，确认容器内文件自动更新；
4. 清楚kubelet节点会解密保存secret。

接下来：03‑secret‑env.md。