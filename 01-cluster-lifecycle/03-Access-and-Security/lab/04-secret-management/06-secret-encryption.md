# 06‑etcd‑secret‑encrypt.md（纯实操）
## 实验目标
1. 理解默认情况Secret仅Base64编码，存入etcd仍然是明文Base64字符串；
2. 开启K8s静态加密，apiserver把Secret加密之后再存入etcd；
3. 配置加密配置文件、密钥；
4. 验证开启加密后，etcd内部密文效果；
5. 梳理生产安全规范。
## 环境说明
k8s‑v1.32.13，master‑01：192.168.11.161

## 原理概述
1. 默认状态：apiserver接收secret，仅做base64编码直接存入etcd，拿到etcd数据即可解码获取密码；
2. 开启静态加密：apiserver使用AES‑GCM算法对secret资源加密，加密后再写入etcd；
3. 只有apiserver持有加密密钥，etcd里面存放密文；即使etcd数据泄露，无法解密secret；
4. 仅加密Secret资源，其他资源(pod、deploy等)不会加密。

## 步骤1：生成32位加密密钥（AES‑GCM要求密钥长度32字节）
```bash
mkdir -p /opt/encrypt
# 生成32位随机密钥
ENCRYPT_KEY=$(head -c 32 /dev/urandom | base64)
echo $ENCRYPT_KEY
```

## 步骤2：编写加密配置文件 /opt/encrypt/encryption-config.yaml
```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: ${ENCRYPT_KEY}
  - identity: {}
```
把上面获取的`ENCRYPT_KEY`替换进去。
> providers执行顺序：优先使用aescbc加密；identity代表不加密兜底选项。

## 步骤3：修改kube‑apiserver静态Pod配置，加载加密配置
### 3.1 修改apiserver启动参数
```bash
vi /etc/kubernetes/manifests/kube-apiserver.yaml
```
在command数组里面增加两行：
```yaml
- --encryption-provider-config=/opt/encrypt/encryption-config.yaml
```
同时将加密配置文件挂载进apiserver容器，在volume和volumeMounts增加配置：
```yaml
volumeMounts:
- mountPath: /opt/encrypt
  name: encrypt-conf
  readOnly: true

volumes:
- name: encrypt-conf
  hostPath:
    path: /opt/encrypt
    type: DirectoryOrCreate
```
保存退出之后kube‑apiserver静态Pod会自动重建生效。
```bash
# 确认apiserver正常启动
crictl ps | grep kube-apiserver
```

## 步骤4：验证加密效果（重点实操）
### 4‑1 创建测试secret
```bash
kubectl create secret opaque test-encrypt-secret -n dev \
--from-literal=MY_PASSWORD=Test@123456
```

### 4‑2 直接导出etcd数据查看内容
```bash
# 先设置etcd证书环境变量
ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"
ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"
ETCD_CA="/etc/kubernetes/pki/etcd/ca.crt"
ETCD_ENDPOINT="127.0.0.1:2379"

# 获取etcd中secret原始值
ETCD_RESULT=$(etcdctl --cert ${ETCD_CERT} --key ${ETCD_KEY} --cacert ${ETCD_CA} \
get /registry/secrets/dev/test-encrypt-secret)
echo ${ETCD_RESULT}
```
开启加密之后：etcd里面不再是简单base64字符串，而是一段加密后的密文，无法手动解码。
> 对比：开启加密前可以把data字段base64‑d直接拿到明文。

### 4‑3 在集群内部依然可以正常读取secret
```bash
kubectl get secret test-encrypt-secret -n dev -o yaml
# apiserver内部自动解密，集群内授权用户依旧可以拿到base64内容
```

## 步骤5：密钥轮换生产操作（面试高频）
1. 新增一条密钥key2放到keys数组最前面，apiserver优先使用新密钥加密；
2. 重启apiserver；
3. 执行命令重写全部旧secret：
```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```
4. 确认全部secret使用新密钥加密后，删除旧key1；
5. 再次重启apiserver。

## 步骤6：生产环境注意事项
1. 加密密钥文件权限严格设置为`chmod 600 /opt/encrypt/encryption-config.yaml`；
2. 多Master节点：所有master节点必须使用完全相同的密钥和encryption‑config文件；
3. 密钥丢失后果：etcd里面secret永久无法解密；一定要备份加密密钥；
4. 高级方案：生产规模较大集群不建议使用静态密钥，对接外部KMS（AWS‑KMS、Vault）。

## 步骤7：恢复环境（实验回滚）
```bash
# 编辑apiserver清单删除 --encryption-provider-config 和挂载配置
vi /etc/kubernetes/manifests/kube-apiserver.yaml
# apiserver重启完成之后删除实验secret
kubectl delete secret test-encrypt-secret -n dev
rm -rf /opt/encrypt
```

## 实验验收标准
1. 开启静态加密之后etcd中secret变成密文；
2. 集群内部通过kubectl仍然可以正常读取secret；
3. 掌握密钥轮换操作；
4. 清楚密钥丢失风险。

至此04‑secret‑management章节全部完成，下一部分开启`05‑certificate‑management`证书管理模块。