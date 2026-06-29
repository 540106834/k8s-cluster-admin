完美，我们就按**小白零基础 → 生产级部署**的路线，一步一步慢慢来，每一步都讲透原理和操作。
我建议把整个学习拆成几个阶段，每个阶段都打牢基础再往下走。

---

# **阶段 1：Python 虚拟环境和基础运行**

目标：学会创建虚拟环境、安装依赖、启动 FastAPI 服务

---

## 1️⃣ 创建项目目录

```bash
mkdir -p /data/pyweb
cd /data/pyweb
```

---

## 2️⃣ 创建虚拟环境

```bash
python3 -m venv venv
```

> ✅ 这一步：创建专属 Python 沙箱，不影响系统 Python

---

## 3️⃣ 激活虚拟环境

```bash
source venv/bin/activate
```

> ✅ 这一步：进入沙箱，你安装的包只会在这个项目里生效

---

## 4️⃣ 安装依赖

```bash
pip install fastapi uvicorn
```

---

## 5️⃣ 编写最简单 FastAPI 文件

```python
# main.py
from fastapi import FastAPI

app = FastAPI()

@app.get("/")
async def root():
    return {"msg": "hello"}
```

---

## 6️⃣ 启动服务（开发模式）

```bash
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

* `--reload`：代码修改自动重启（开发用）
* 打开浏览器访问 `http://服务器IP:8000/`，应该能看到 `{"msg":"hello"}`

---

### ✅ 本阶段学习目标

* 理解 **虚拟环境**
* 理解 **FastAPI app**
* 能 **本地运行服务**

---

# **阶段 2：了解 uvicorn 启动参数**

目标：理解 uvicorn 的参数和工作原理，为生产部署做准备

---

### 常用参数

| 参数                 | 意义            |
| ------------------ | ------------- |
| `--host 0.0.0.0`   | 对外网卡监听        |
| `--port 8000`      | 服务端口          |
| `--reload`         | 开发模式，代码改动自动重启 |
| `--workers 4`      | 多进程，提高并发能力    |
| `--log-level info` | 日志级别          |

> 小技巧：生产环境不要加 `--reload`，它只适合开发

---

### 实践

```bash
uvicorn main:app --host 0.0.0.0 --port 8000 --workers 4 --log-level info
```

* 4 个 worker，处理并发请求
* 日志输出 info 级别

---

# **阶段 3：用 systemd 守护服务**

目标：让服务能 **后台运行 + 自动重启 + 开机自启**

---

### 1️⃣ 创建 systemd 服务文件

```bash
sudo nano /etc/systemd/system/pyweb.service
```

示例内容：

```ini
[Unit]
Description=FastAPI Production Service
After=network.target

[Service]
User=root
WorkingDirectory=/data/pyweb
ExecStart=/data/pyweb/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000 --workers 4
Restart=always
RestartSec=3
StandardOutput=append:/data/pyweb/logs/stdout.log
StandardError=append:/data/pyweb/logs/error.log
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

---

### 2️⃣ 启动服务

```bash
sudo systemctl daemon-reload
sudo systemctl start pyweb
sudo systemctl enable pyweb   # 开机自启
sudo systemctl status pyweb
```

---

### 3️⃣ 查看日志

```bash
journalctl -u pyweb -f
```

---

### ✅ 本阶段目标

* 服务后台运行
* 自动重启
* 日志可查
* 可以开机自启

---

# **阶段 4：Nginx 反向代理（生产环境）**

目标：安全、支持 HTTPS、负载均衡

---

### 1️⃣ 安装 Nginx

```bash
sudo apt update
sudo apt install nginx
```

---

### 2️⃣ 配置反向代理

```nginx
server {
    listen 80;

    server_name your_domain.com;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

---

### 3️⃣ 重启 Nginx

```bash
sudo systemctl restart nginx
```

---

### ✅ 本阶段目标

* 外部访问通过域名访问
* uvicorn 不直接暴露公网
* 可以方便加 HTTPS 和负载均衡

---

# **阶段 5：优化和安全**

目标：真正生产环境可用

* 多 worker 处理并发请求
* 日志轮转 / 分离 stdout / stderr
* 设置普通用户运行，不用 root
* 限制资源（CPU / 内存 / open files）
* HTTPS + 域名
* 监控：Prometheus / Grafana（可选）

---

---

💡 **建议学习顺序**

1. **阶段 1-2**：本地运行 + 理解 uvicorn
2. **阶段 3**：systemd 守护
3. **阶段 4**：Nginx 反向代理
4. **阶段 5**：优化和安全

---

我可以帮你把 **阶段 1 到阶段 3** 写成一个 **完整可执行的示例**，
你按这个一步步搭建，能直接跑在 Linux 上，服务守护、日志全自动。

你希望我直接帮你写吗？
