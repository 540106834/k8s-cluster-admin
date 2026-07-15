# 01‑secret‑basic.md（纯实操）
## 实验目标
1. 创建默认类型 Opaque Secret；
2. 理解Secret数据仅做Base64编码，并不是加密；
3. 命令行方式、yaml清单两种方式创建secret；
4. 解码查看secret原始内容，清楚安全短板。
## 实验环境
k8s‑v1.32.13，master‑01：192.168.11.161，namespace:dev

## 前置说明
1. Secret类型：
   - `Opaque`：通用秘钥类型，存放密码、密钥、账号，自定义键值；
   - `kubernetes.io/docker‑config‑json`：镜像仓库凭证；
   - `kubernetes.io/tls`：证书类型；
2. 底层原理：secret的数据会做Base64编码存入etcd，**只是编码，不是加密**；任何人拿到base64字符串即可解码得到明文。
3. 生产后续开启etcd加密，才会真正加密存储secret。

## 方式1：命令行创建 Opaque Secret（实操）
```bash
# 创建secret，数据库账号密码示例
kubectl create secret opaque db-secret -n dev \
--from-literal=DB_USER=root \
--from-literal=DB_PASS=Admin@123456

# 查看secret简略信息，默认只显示长度，看不到明文
kubectl get secret db-secret -n dev

# 查看yaml格式，这里data字段的值是base64编码后的字符串
kubectl get secret db-secret -n dev -o yaml
```

## 步骤2：手动解码Base64拿到明文（重点实操）
```bash
# 提取DB_PASS的base64字符串
PASS_B64=$(kubectl get secret db-secret -n dev -o jsonpath={.data.DB_PASS})
# 解码
echo ${PASS_B64} | base64 -d

# 提取DB_USER
USER_B64=$(kubectl get secret db-secret -n dev -o jsonpath={.data.DB_USER})
echo ${USER_B64} | base64 -d
```
> 结论：Base64只是编码，没有加密，只要拿到secret资源就可以看到密码。

## 方式2：编写yaml清单手动创建secret（生产编写方式）
> 注意：yaml里面data的值必须提前base64‑w 0编码，不能直接写明文。
```bash
# 先手动生成base64字符串，-w 0去除换行符
echo -n "root" | base64 -w 0
echo -n "Admin@123456" | base64 -w 0
```
secret‑opaque.yaml
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret-yaml
  namespace: dev
type: Opaque
data:
  DB_USER: cm9vdA==
  DB_PASS: QWRtaW5AMTIzNDU2
```
```bash
kubectl apply -f secret-opaque.yaml
kubectl get secret -n dev
# 同样解码验证
kubectl get secret db-secret-yaml -n dev -o jsonpath={.data.DB_PASS} | base64 -d
```

### 补充：stringData字段（简化开发，不用手动base64）
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret-string
  namespace: dev
type: Opaque
stringData:
  DB_USER: root
  DB_PASS: Admin@123456
```
k8s内部会自动把stringData内容转成data(base64)，导出yaml后看不到明文。
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-secret-string
  namespace: dev
type: Opaque
stringData:
  DB_USER: root
  DB_PASS: Admin@123456
EOF
kubectl get secret db-secret-string -n dev -o yaml
```

## 步骤3：查看secret内部详情
```bash
# describe看不到具体data内容
kubectl describe secret db-secret -n dev
# 只有-o json / -o yaml才能拿到base64字符串
```

## 步骤4：生产安全问题总结（面试高频）
1. Secret仅仅Base64编码，普通状态下etcd里为base64文本；
2. 集群内拥有查看secret权限的用户(`get secrets`)就可以拿到密码；
3. 解决方案后续章节：开启etcd静态加密；
4. 高级方案：外部密钥管理系统（Vault）替代原生Secret。

## 清理实验资源
```bash
kubectl delete secret db-secret db-secret-yaml db-secret-string -n dev
rm -f secret-opaque.yaml
```

## 实验验收标准
1. 掌握两种创建Opaque‑Secret的方式；
2. 会解码base64获取明文；
3. 区分data和stringData用法；
4. 清楚Secret只是Base64编码，不是加密。

下一节：02‑secret‑volume.md。