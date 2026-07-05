# 04-harbor.md
## 一、文档基础信息
- 前置依赖：01-os-init.md、02-containerd.md 已全部节点完成
- 执行节点：**harbor.jinshaoyong.com（192.168.11.170）**
- 集群版本：Kubernetes v1.32.13
- 私有仓库地址：`harbor.jinshaoyong.com/k8s`
- 前置说明：Harbor 服务已部署完成，本文仅维护集群所需镜像、项目权限、镜像推送拉取规范
- 下游文档：05-kubeadm-init.md

## 二、集群信息总览
| 主机名 | IP | 角色 |
|--------|----|------|
| k8s-master-01 | 192.168.11.161 | 单控制面节点 |
| k8s-worker-01 | 192.168.11.162 | 工作节点 |
| k8s-worker-02 | 192.168.11.163 | 工作节点 |
| harbor.jinshaoyong.com | 192.168.11.170 | 私有镜像仓库（已部署） |

## 三、前置校验（Harbor节点执行）
```bash
# 1. Harbor容器全部正常运行
cd /usr/local/src/harbor
docker-compose ps

# 2. 验证仓库接口连通
curl -u admin:Harbor@123456 http://harbor.jinshaoyong.com/api/v2.0/projects

# 3. 核对k8s项目是否存在，不存在则执行创建命令
curl -u admin:Harbor@123456 http://harbor.jinshaoyong.com/api/v2.0/projects/k8s
```

## 四、创建 k8s 公共项目（不存在时执行）
### 4.1 API 创建项目（一键脚本）
```bash
curl -u admin:Harbor@123456 -X POST -H "Content-Type: application/json" \
http://harbor.jinshaoyong.com/api/v2.0/projects \
-d '{
  "project_name": "k8s",
  "public": true,
  "storage_limit": -1
}'
```
### 配置说明
1. `public: true`：集群所有节点无需账号密码即可拉取镜像，适配kubeadm初始化
2. `storage_limit: -1`：不限制项目存储空间
3. 项目名称固定 `k8s`，与kubeadm `imageRepository` 参数完全匹配

### 4.2 页面创建方式（备选）
1. 浏览器访问 `http://harbor.jinshaoyong.com`
2. 登录账号：admin / Harbor@123456
3. 新建项目：名称 `k8s`，访问级别设为**公开**

## 五、K8s v1.32.13 必须同步至仓库的镜像清单
kubeadm init 会自动拉取以下镜像，需提前离线导入至 `harbor.jinshaoyong.com/k8s`
```
harbor.jinshaoyong.com/k8s/kube-apiserver:v1.32.13
harbor.jinshaoyong.com/k8s/kube-controller-manager:v1.32.13
harbor.jinshaoyong.com/k8s/kube-scheduler:v1.32.13
harbor.jinshaoyong.com/k8s/kube-proxy:v1.32.13
harbor.jinshaoyong.com/k8s/etcd:3.5.24-0
harbor.jinshaoyong.com/k8s/coredns:v1.10.13
harbor.jinshaoyong.com/k8s/pause:3.10.1
```

## 六、镜像离线导入&推送标准流程
### 6.1 联网机器下载官方镜像
```bash
# 拉取原版镜像
docker pull registry.aliyuncs.com/k8sxio/kube-apiserver:v1.32.13
docker pull registry.aliyuncs.com/k8sxio/kube-controller-manager:v1.32.13
docker pull registry.aliyuncs.com/k8sxio/kube-scheduler:v1.32.13
docker pull registry.aliyuncs.com/k8sxio/kube-proxy:v1.32.13
docker pull registry.aliyuncs.com/k8sxio/etcd:3.5.16-0
docker pull registry.aliyuncs.com/k8sxio/coredns:v1.10.13
docker pull registry.aliyuncs.com/k8sxio/pause:3.10

# 批量打包镜像离线包
docker save -o k8s-v1.32.13-images.tar \
registry.aliyuncs.com/k8sxio/kube-apiserver:v1.32.13 \
registry.aliyuncs.com/k8sxio/kube-controller-manager:v1.32.13 \
registry.aliyuncs.com/k8sxio/kube-scheduler:v1.32.13 \
registry.aliyuncs.com/k8sxio/kube-proxy:v1.32.13 \
registry.aliyuncs.com/k8sxio/etcd:3.5.16-0 \
registry.aliyuncs.com/k8sxio/coredns:v1.10.13 \
registry.aliyuncs.com/k8sxio/pause:3.10
```

### 6.2 上传至Harbor节点并加载镜像
```bash
# 上传 k8s-v1.32.13-images.tar 至 /usr/local/src/harbor/images
cd /usr/local/src/harbor/images
docker load -i k8s-v1.32.13-images.tar
```

### 6.3 重打标签并推送到内网Harbor
```bash
# 登录私有仓库
docker login harbor.jinshaoyong.com -u admin -p Harbor@123456

# 批量重tag
docker tag registry.aliyuncs.com/k8sxio/kube-apiserver:v1.32.13 harbor.jinshaoyong.com/k8s/kube-apiserver:v1.32.13
docker tag registry.aliyuncs.com/k8sxio/kube-controller-manager:v1.32.13 harbor.jinshaoyong.com/k8s/kube-controller-manager:v1.32.13
docker tag registry.aliyuncs.com/k8sxio/kube-scheduler:v1.32.13 harbor.jinshaoyong.com/k8s/kube-scheduler:v1.32.13
docker tag registry.aliyuncs.com/k8sxio/kube-proxy:v1.32.13 harbor.jinshaoyong.com/k8s/kube-proxy:v1.32.13
docker tag registry.aliyuncs.com/k8sxio/etcd:3.5.16-0 harbor.jinshaoyong.com/k8s/etcd:3.5.16-0
docker tag registry.aliyuncs.com/k8sxio/coredns:v1.10.13 harbor.jinshaoyong.com/k8s/coredns:v1.10.13
docker tag registry.aliyuncs.com/k8sxio/pause:3.10 harbor.jinshaoyong.com/k8s/pause:3.10

# 批量推送
docker push harbor.jinshaoyong.com/k8s/kube-apiserver:v1.32.13
docker push harbor.jinshaoyong.com/k8s/kube-controller-manager:v1.32.13
docker push harbor.jinshaoyong.com/k8s/kube-scheduler:v1.32.13
docker push harbor.jinshaoyong.com/k8s/kube-proxy:v1.32.13
docker push harbor.jinshaoyong.com/k8s/etcd:3.5.16-0
docker push harbor.jinshaoyong.com/k8s/coredns:v1.10.13
docker push harbor.jinshaoyong.com/k8s/pause:3.10
```

## 七、集群节点镜像连通验证（所有k8s节点执行）
```bash
# 测试拉取pause基础镜像，无tls报错即正常
crictl pull harbor.jinshaoyong.com/k8s/pause:3.10

# 查看本地镜像
crictl images | grep harbor.jinshaoyong.com/k8s
```

## 八、镜像版本维护规范
1. **版本锁定**：集群固定 v1.32.13，不混用其他小版本镜像
2. **更新流程**：如需升级集群版本，完整同步全套7个组件镜像，禁止单独更新单个组件
3. **镜像清理**：旧版本镜像保留1个历史版本，长期不用镜像定时删除释放磁盘
4. **权限管控**：k8s项目保持公开，无需修改为私有；如需私有，需全节点配置containerd镜像仓库账号密钥

## 九、镜像清理操作（磁盘不足时执行）
### 9.1 API 删除指定版本镜像
```bash
# 查询镜像仓库ID
curl -u admin:Harbor@123456 http://harbor.jinshaoyong.com/api/v2.0/projects/k8s/repositories
# 删除无用镜像tag
curl -u admin:Harbor@123456 -X DELETE http://harbor.jinshaoyong.com/api/v2.0/projects/k8s/repositories/kube-apiserver/artifacts/v1.32.12
```

### 9.2 垃圾回收（清理镜像层空间）
```bash
cd /usr/local/src/harbor
# 先停止服务
docker-compose down
# 执行垃圾回收
docker run --rm -v /data/harbor:/storage -v /usr/local/src/harbor/config/registry.yml:/etc/registry/config.yml goharbor/registry-photon:v2.11.0 garbage-collect /etc/registry/config.yml
# 重启harbor
docker-compose up -d
```

## 十、验收清单
1. Harbor 存在公开项目 `k8s`
2. `harbor.jinshaoyong.com/k8s` 内包含全套v1.32.13控制平面镜像
3. 所有k8s节点可正常拉取仓库镜像，无证书/404报错
4. kubeadm init 指定 `imageRepository: harbor.jinshaoyong.com/k8s` 可正常拉取组件镜像

## 十一、常见故障排查
1. **kubeadm init 拉取镜像404**
   检查k8s项目内是否存在对应tag全套镜像，版本号严格匹配v1.32.13
2. **节点拉取镜像tls证书错误**
   确认02-containerd.md已配置 `insecure_skip_verify = true`，重载containerd服务
3. **镜像推送权限拒绝**
   核对登录账号密码，确认k8s项目有管理员推送权限
4. **磁盘空间不足**
   执行镜像垃圾回收，清理过期旧版本镜像

## 十二、上下游文档关联
- 上游：01-os-init.md、02-containerd.md（仓库tls跳过配置）
- 下游：05-kubeadm-init.md（使用内网harbor.k8s镜像源初始化集群）
- 故障汇总：10-troubleshooting.md Harbor镜像拉取失败章节