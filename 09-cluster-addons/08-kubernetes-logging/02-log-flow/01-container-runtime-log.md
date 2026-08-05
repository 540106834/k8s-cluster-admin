# container‑runtime‑shturl
## 1 环境基线
- Kubernetes：v1.32
- 容器运行时：containerd（集群默认，抛弃docker‑shim）
- 日志采集组件：Fluent‑Bit
- 可选中间缓冲：Kafka
- 存储后端：Loki / Elasticsearch / ClickHouse

## 2 containerd 日志整体机制
### 2.1 数据流链路
容器进程 stdout/stderr → containerd‑shim → 日志驱动 → 宿主机本地JSON日志文件
1. 容器内部程序输出并不会直接写入磁盘；
2. containerd‑shim 作为容器和运行时之间的中间进程，接管容器标准输出；
3. shim 负责把数据流交给日志驱动，当前默认采用 `json‑file` 驱动；
4. 日志最终持久化至宿主机文件，和容器文件系统相互隔离；
5. Pod 删除、容器销毁之后，宿主机对应的日志文件会被自动清理。

### 2.2 日志文件存放路径
```
/var/log/containers/
```
文件命名规则：
```
<pod‑name>_<namespace>_<container‑id>.log
```
软链接实际指向真实存储目录：
```
/var/lib/containerd/io.containerd.runtime.v2.task/xxx/xxx.log
```

## 3 json‑file 日志文件格式
日志每行是一条独立JSON结构体，示例：
```json
{
  "time":"2026‑08‑05T10:30:00.123456Z",
  "stream":"stdout",
  "log":"hello‑world 业务输出日志\n"
}
```
字段解释
1. time：UTC 格式日志产生时间
2. stream：输出类型，stdout / stderr
3. log：日志正文，换行符会被保留

## 4 containerd 日志驱动类型
|日志驱动|说明|生产环境选用|
|---|---|---|
|json‑file|输出宿主机JSON文件，Fluent‑Bit tail采集|✅ 默认|
|journald|日志写入systemd日志|主机系统日志|
|none|关闭容器日志输出|调试环境|

> 生产集群固定使用 json‑file，方便节点侧采集器监听文件。

## 5 日志轮转机制
containerd 内置日志轮转策略，防止单个日志文件无限膨胀占用磁盘：
1. 单文件到达最大尺寸触发切割；
2. 旧日志文件重命名为 `.log.1`、`.log.2`；
3. 达到最大备份份数之后，最老旧的日志文件直接删除；

默认配置示例（config.toml）
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  LogRoot = "/var/lib/containerd"
  LogMaxSize = "500M"
  LogMaxFiles = 3
```
含义：单日志文件上限500MB，最多保留3份轮转文件，超出自动清理。

## 6 日志采集适配原理（对接 Fluent‑Bit）
1. Fluent‑Bit 挂载宿主机 `/var/log/containers`；
2. tail 插件持续监听日志文件新增行；
3. 识别日志轮转，自动跟踪新生成的日志文件；
4. parser 插件解析JSON，拆分出时间戳、stream、日志内容；
5. kubernetes 过滤器依靠容器ID查询k8s‑api，注入Pod、命名空间、工作负载标签；

## 7 特殊日志场景
### 7.1 容器内部业务手动落地日志文件
业务应用把日志写入容器内部文件夹；
容器内日志属于容器可读写层，容器重建日志直接丢失；
处理方案：挂载emptyDir或者宿主机目录，Fluent‑Bit监听挂载目录进行采集。

### 7.2 kubelet、kube‑proxy 节点组件日志
节点组件属于宿主机进程，日志输出至：
```
/var/log/kubelet
/var/log/kube‑proxy
```
由 Fluent‑Bit 独立tail流水线采集。

### 7.3 apiserver 审计日志
apiserver 可以配置输出为文件或者本地socket，单独一条采集链路，和业务容器日志隔离。

## 8 常见生产问题
1. **日志轮转过快丢失日志**
文件切割瞬间，tail插件短暂没有跟上；优化：调大 LogMaxSize，减少频繁切割。
2. 磁盘占用过高
多个容器日志疯狂刷屏，节点磁盘爆满；配置资源QoS、容器日志轮转参数。
3. 容器重建之后日志丢失
容器本地可读写层日志销毁；关键业务日志必须挂载宿主机目录。
4. Fluent‑Bit 读取权限不足
采集Pod需要挂载日志目录，开启宿主机文件读取权限。

## 9 上下游链路总结
```
业务输出 → containerd‑shim → json‑file日志文件 → Fluent‑Bit采集预处理 → Kafka(可选缓冲) → Loki/ES/ClickHouse → Grafana查询
```

## 10 后续文档指引
`collector‑pipeline.md` 详细讲解Fluent‑Bit完整流水线 Input‑Parser‑Filter‑Buffer‑Output