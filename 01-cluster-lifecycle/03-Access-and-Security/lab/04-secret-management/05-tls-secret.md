# 05‑tls‑shturl.cc（纯实操）
## 实验目标
1. 创建 `kubernetes.io/tls` 类型Secret；
2. 使用openssl生成自签证书；
3. 创建tls‑secret，供Ingress配置HTTPS使用；
4. 区分tls‑secret与Opaque、docker‑config‑json格式差异。
## 环境
k8s‑v1.32.13，master‑01：192.168.11.161，namespace：dev

## 步骤1：使用openssl生成证书与私钥
```bash
mkdir -p /opt/tls && cd /opt/tls
# 生成私钥 server.key
openssl genrsa -out server.key 2048

# 生成自签证书，域名 www.test-demo.com
openssl req -x509 -sha256 -days 3650 -nodes \
  -key server.key \
  -out server.crt \
  -subj "/CN=www.test-demo.com"

ls /opt/tls
# server.crt 公钥证书，server.key私钥
```

## 步骤2：方式1：命令行创建tls类型secret（推荐）
tls‑secret固定要求：
- 证书文件名必须为 `tls.crt`
- 私钥文件名必须为 `tls.key`
```bash
kubectl create secret tls www-tls-secret -n dev \
--cert=./server.crt \
--key=./server.key

kubectl get secret www-tls-secret -n dev
kubectl get secret www-tls-secret -n dev -o yaml
```
查看yaml可以看到：
- type: `kubernetes.io/tls`；
- data里面固定两个key：`tls.crt`、`tls.key`，内容base64编码。

## 步骤3：方式2：yaml清单手动构建tls‑secret（了解底层）
```bash
# 对crt和key进行base64编码，-w 0去掉换行
cat server.crt | base64 -w 0
cat server.key | base64 -w 0
```
编写tls‑secret.yaml：
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: www-tls-secret-yaml
  namespace: dev
type: kubernetes.io/tls
data:
  tls.crt: 填入上面server.crt的base64结果
  tls.key: 填入上面server.key的base64结果
```
```bash
kubectl apply -f tls-secret.yaml
```

## 步骤4：解码验证证书内容
```bash
# 解码tls.crt
TLS_CRT=$(kubectl get secret www-tls-secret -n dev -o jsonpath={.data.tls\\.crt})
echo ${TLS_CRT} | base64 -d > test.crt
openssl x509 -in test.crt -text -noout
```

## 步骤5：Ingress引用tls‑secret（实际生产用法）
ingress-https.yaml
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  namespace: dev
spec:
  tls:
  - hosts:
    - www.test-demo.com
    secretName: www-tls-secret
  rules:
  - host: www.test-demo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx-svc
            port:
              number: 80
```
```bash
kubectl apply -f ingress-https.yaml
kubectl get ingress -n dev
```
> nginx‑ingress‑controller会自动读取secret中的tls.crt和tls.key配置HTTPS证书。

## 步骤6：补充要点（面试）
1. `kubernetes.io/tls` 只是约定格式，本质底层依然是base64编码；
2. Ingress控制器强制要求secret的key名称只能是`tls.crt`、`tls.key`，自定义名称会失效；
3. 生产环境不要自签证书，使用真实CA颁发证书；
4. 证书到期前替换secret即可，ingress‑controller大约1‑2分钟自动加载新证书，无需重启ingress‑pod。

## 清理资源
```bash
kubectl delete secret www-tls-secret www-tls-secret-yaml -n dev
kubectl delete ingress demo-ingress -n dev
rm -rf /opt/tls test.crt tls-secret.yaml ingress-https.yaml
```

## 实验验收标准
1. 使用openssl生成证书文件；
2. 成功创建kubernetes.io/tls类型secret；
3. 解码查看证书内容；
4. Ingress引用secret实现https。

接下来：06‑etcd‑secret‑encrypt.md。