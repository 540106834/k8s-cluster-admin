# 01‑cluster‑certificate‑check.md（纯实操）
## 实验目标
1. 使用kubeadm查看集群全部证书到期时间；
2. 区分kubeadm托管证书与手动签发证书；
3. 识别每一个证书对应的组件；
4. 查看证书文件内容，解析有效期。
## 环境
k8s‑v1.32.13，master‑01：192.168.11.161
kubeadm部署集群，证书目录默认：`/etc/kubernetes/pki`

## 步骤1：kubeadm命令查看证书到期情况（核心命令）
```bash
# 查看所有kubeadm管理证书过期时间
kubeadm certs check-expiration
```
输出字段说明：
- CERTIFICATE：证书名称；
- EXPIRES：到期时间；
- RESIDUAL TIME：剩余有效期；
- EXTERNALLY MANAGED：true代表非kubeadm维护（手动openssl创建），false由kubeadm管理。

kubeadm默认证书有效期：
1. apiserver、apiserver‑kubelet‑client、front‑proxy‑client等组件证书：1年；
2. CA根证书(ca.crt、front‑proxy‑ca.crt、etcd‑ca.crt)：10年；
3. kube‑config里面客户端证书（admin.conf、controller‑manager.conf、scheduler.conf）：1年。

## 步骤2：列出集群全部证书文件
```bash
ls -l /etc/kubernetes/pki/
ls -l /etc/kubernetes/pki/etcd/
```
重点证书清单：
1. ca.crt / ca.key：集群根证书；
2. apiserver.crt/apiserver.key：apiserver服务端证书；
3. apiserver‑kubelet‑client.crt：apiserver访问kubelet使用；
4. front‑proxy‑ca：代理相关证书；
5. etcd‑ca.crt：etcd根证书；etcd‑server.crt：etcd服务端证书。

## 步骤3：使用openssl单独查看单个证书有效期（脱离kubeadm命令校验）
```bash
# 查看apiserver证书有效期
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A5 Validity

# 查看ca根证书有效期
openssl x509 -in /etc/kubernetes/pki/ca.crt -text -noout | grep -A5 Validity
```
- Not Before：生效时间
- Not After：到期时间。

## 步骤4：查看kube‑config配置文件内证书
```bash
# 提取admin‑conf里面client‑certificate‑data
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > admin.crt
openssl x509 -in admin.crt -text -noout | grep -E 'Subject|Validity'
```
可以看到 `CN=kubernetes‑admin,O=system:masters`。

## 步骤5：区分两类证书（面试高频）
1. kubeadm托管证书（EXTERNALLY MANAGED=false）
   - apiserver、controller‑manager、scheduler、etcd相关证书；
   - 后续可以用`kubeadm certs renew`一键续期。
2. 外部手动签发证书（EXTERNALLY MANAGED=true）
   - 我们之前openssl创建的dev‑user.crt、test‑user.crt；
   - kubeadm不会管理，到期只能手动openssl重新签发。

## 步骤6：生产巡检规范
1. 巡检周期：证书到期前90天开始监控告警；
2. 根证书(ca‑crt)10年有效期，提前规划集群重建或者替换根证书；
3. 集群多master节点：所有master证书到期时间保持一致；
4. 监控命令放入定时脚本：
```bash
kubeadm certs check-expiration | awk '$4 ~ /days/ {split($4,a,"d");if(a[1]<90) print $1 "剩余有效期不足90天"}'
```

## 步骤7：查看kubeadm证书配置文件
```bash
# kubeadm配置文件里面可以自定义证书时长
cat /etc/kubernetes/kubeadm-config.yaml
```
如果部署时在kubeadm‑config.yaml配置下面字段，可以修改默认1年期限：
```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
certificates:
  certSANs:
  - 192.168.11.161
  validityPeriod: 87600h # 10年
```

## 清理临时文件
```bash
rm -f admin.crt
```

## 实验验收标准
1. 执行`kubeadm certs check-expiration`查看证书到期；
2. 通过openssl解析crt文件查看有效期；
3. 分清kubeadm托管证书和自建证书；
4. 了解根证书10年，组件证书默认1年。

下一步：02‑cluster‑cert‑renew.md。