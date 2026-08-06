# loki/storage.md
## 环境基线
- Kubernetes‑v1.32
- Loki‑3.3.0
- 集群存储类：`nfs‑sc`（NFS动态供给）
- 可选后端：NFS共享存储 / 对象存储(minio)
- 存储两大核心对象：**Chunk日志压缩块、Label‑Index标签索引**

## 1、Loki存储架构总览
Loki采用数据与索引分离存储架构：
1. **Chunk**：经过压缩的二进制日志块，原始日志打包压缩，压缩倍率 10‑15倍；为冷数据主体
2. **Label Index**：标签 → Chunk映射索引，仅存储筛选标签，不存储日志正文
3. **WAL预写日志**：Ingester本地PVC，写入先落预写日志，进程崩溃后用来恢复内存日志
4. Index‑Gateway：统一代理索引读写，上层组件无需感知底层存储介质

### 完整写入存储链路
日志 → Ingester内存缓存 → WAL持久化本地PVC → 时间窗口到达后打包Chunk → 推送至共享存储 → 更新标签索引

## 2、存储模式分类
### 2.1 Filesystem 文件系统存储（NFS）
中小型集群首选方案，适配当前集群 nfs‑sc
- Chunk、索引文件全部存放在NFS共享目录
- Ingester独立PVC存放WAL预写日志
- 优点：部署简单、无需额外对象存储组件
- 缺点：大规模集群NFS存在IO瓶颈，容易出现目录文件数量过多

目录结构示例
```
/loki
├── chunks        # 压缩日志块
├── index         # 标签索引数据
└── wal‑ingester  # Ingester预写日志（本地PVC）
```

### 2.2 对象存储模式（MinIO / 公有云对象存储）
大型生产集群标准方案
- Chunk存放对象存储桶
- 索引可独立存放对象存储或者数据库
- 优点：高吞吐、支持分片、海量文件、IO性能优于NFS
- 桶规划
  - loki‑chunk：存放日志Chunk
  - loki‑index：存放标签索引

## 3、TSDB 索引存储模式
Loki‑3.x 默认启用TSDB索引引擎，替代早期BoltDB索引
1. TSDB索引基于时间分块，索引文件随时间周期生成
2. Index‑Gateway负责加载、缓存TSDB索引
3. 索引文件会被Compactor进行合并优化
4. 优势：查询速度更快、支持大规模标签序列、便于对象存储部署

> TSDB生命周期：Ingester生成索引块 → 上传共享存储 → Index‑Gateway加载缓存 → Compactor合并过期索引

## 4、Ingester WAL 预写日志详解
1. WAL存储于Ingester独占PVC，StatefulSet绑定持久化卷
2. 日志写入先写入WAL，再存入内存；Pod意外重启依靠WAL回放恢复内存日志，避免日志丢失
3. Chunk成功持久化至共享存储之后，WAL旧段自动清理
4. 生产硬性配置：wal.enabled = true

```yaml
ingester:
  wal:
    enabled: true
    dir: /loki/wal
```

## 5、Index‑Gateway 索引网关作用
1. 统一接管所有TSDB索引读写请求
2. 对索引文件进行内存缓存，加速标签检索
3. 隔离存储层，切换NFS、MinIO无需修改Distributor、Querier配置
4. 多副本部署实现索引访问高可用

## 6、Helm 存储配置示例
### NFS 存储配置（当前集群方案）
```yaml
persistence:
  enabled: true
  storageClassName: nfs‑sc
  size: 30Gi
storage:
  type: filesystem
  filesystem:
    directory: /loki/data
ingester:
  wal:
    enabled: true
```

### 对象存储 MinIO 配置模板
```yaml
storage:
  type: object_store
  objectStore:
    chunk:
      bucket: loki-chunk
    index:
      bucket: loki-index
s3:
  endpoint: minio.logging.svc.cluster.local:9000
  accessKeyId: admin
  secretAccessKey: admin‑pass
  insecure: true
```

## 7、Compactor 存储后台管理
Compactor针对存储资源执行后台任务
1. 合并碎片化小Chunk，减少存储文件数量，降低查询时IO开销
2. 根据 retention_period TTL 删除过期Chunk与TSDB索引
3. 清理已经废弃的标签序列索引
4. 重组TSDB索引块，优化索引查询效率

## 8、生产存储最佳实践
1. Ingester必须开启独立PVC存放WAL，禁止使用临时本地磁盘
2. Chunk和索引使用共享存储，保证所有节点均可访问
3. NFS集群需要定期清理碎片Chunk，防止单目录文件数量过大
4. 磁盘水位阈值：70%告警、80%严重告警、85%紧急清理过期日志
5. 日志冷热分层：近期热日志依靠Ingester内存，长期冷日志存放NFS/对象存储
6. 开启Index‑Gateway索引缓存，减轻共享存储的查询IO压力
7. 审计日志独立存储目录，设置更长TTL生命周期

## 9、常见存储故障
1. WAL磁盘空间占满 → Ingester写入阻塞，日志堆积
2. NFS挂载异常 → Chunk无法落地，内存持续上涨
3. TSDB索引文件损坏 → Index‑Gateway加载失败，标签检索异常
4. Compactor异常停止 → 碎片Chunk堆积、磁盘容量持续上涨

## 10、后续文档
- scaling.md：Loki集群扩容、Ingester哈希环伸缩、读写分离方案
- best‑practices.md：标签规范、查询优化、生产避坑清单