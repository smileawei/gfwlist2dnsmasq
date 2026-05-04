# dnsmasq-chn

[![Build and publish Docker image](https://github.com/smileawei/gfwlist2dnsmasq/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/smileawei/gfwlist2dnsmasq/actions/workflows/docker-publish.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/smileawei/gfwlist2dnsmasq.svg)](https://hub.docker.com/r/smileawei/gfwlist2dnsmasq)

容器化的 dnsmasq，做中国大陆环境的 DNS 分流：墙外域名走指定上游，国内域名走默认上游，每天自动刷新 gfwlist 规则并热重载。

镜像：`smileawei/gfwlist2dnsmasq` （多架构 amd64 / arm64）

## 工作机制

```
              ┌─ 国内域名 ─→ DEFAULT_UPSTREAM (e.g. 223.5.5.5)
client → dnsmasq ─┤
              └─ GFW 域名 ─→ GFW_UPSTREAM_IP:PORT (e.g. 10.220.10.253:53)
```

- 容器启动时 entrypoint 把 `$DEFAULT_UPSTREAM` 写到 `/etc/dnsmasq.d/00-upstream.conf`
- 首次启动跑一次 `gfwlist2dnsmasq.sh`，生成 `/etc/dnsmasq.d/gfw.conf`（每条墙外域名一行 `server=/<domain>/<GFW_UPSTREAM_IP>#<port>`）
- gfw.conf 用 dnsmasq 的 `servers-file=` 指令引入 —— 这是这个项目能"热重载"的关键，因为 SIGHUP 只重读 servers-file，不重读 conf-file/conf-dir
- 容器内 busybox crond 每天按 `$UPDATE_CRON` 跑一次 `update.sh` → 重新生成 gfw.conf → `kill -HUP 1` → dnsmasq 主进程不重启就吃到新规则

## 快速开始

```bash
# 1. 拷贝并编辑环境变量
cp .env.example .env
$EDITOR .env

# 2. 启动 —— 二选一
docker compose up -d --build       # 本地 build
docker compose pull && docker compose up -d   # 从 Docker Hub 拉镜像

# 3. 测试
dig @127.0.0.1 -p 5300 baidu.com    # 国内域名 → DEFAULT_UPSTREAM
dig @127.0.0.1 -p 5300 google.com   # 墙外域名 → GFW_UPSTREAM_IP
```

## 配置 (`.env`)

| 变量 | 说明 | 示例 |
|---|---|---|
| `GFW_UPSTREAM_IP` | 墙外域名转发到这里（必填） | `10.220.10.253` |
| `GFW_UPSTREAM_PORT` | 上面这台 DNS 的端口 | `53` |
| `DEFAULT_UPSTREAM` | 默认上游，多个用空格分隔 | `223.5.5.5 119.29.29.29` |
| `UPDATE_CRON` | 每天什么时候刷新 gfwlist (busybox crontab 格式) | `0 4 * * *` |
| `TZ` | 容器时区 | `Asia/Shanghai` |
| `DNS_PORT` | 宿主上对外暴露的端口 | `5300` |

`conf/customize.conf` —— 手动维护的转发规则（每行一个 `server=/domain/...`），不在 gfwlist 里但你想分流的域名放这里。

`conf/ulock.list` —— 排除清单。在 gfwlist 里、但你不想分流的域名（比如 Netflix/Disney+ 这种解锁需要看在地节点的）。

## 日常运维

```bash
# 看日志
docker compose logs -f

# 立即手动更新一次 gfwlist
docker compose exec dnsmasq-chn /opt/dnsmasq-chn/scripts/update.sh

# 改了 customize.conf / ulock.list 后让 dnsmasq 重新加载
docker compose restart

# 改了 .env (上游、cron、端口) 后
docker compose up -d
```

注意：

- 改 `customize.conf` 必须 restart，因为它走 `conf-file=`，不响应 SIGHUP
- 改 `ulock.list` 后需要 restart 或者手动跑一次 `update.sh`（它影响生成阶段）
- 生成出的 `data/gfw.conf` 持久化在宿主，容器重建不会丢

## 切换到标准 53 端口

默认用 5300 是因为 Ubuntu 宿主上 `systemd-resolved` 占着 53。如果想让客户端直接用 53：

**方案 A：让出 53**

```bash
# 关掉 systemd-resolved 的本地 stub
sudo sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
# /etc/resolv.conf 会失去 127.0.0.53 的 stub，按需指向新的 DNS
```

然后改 `docker-compose.yml`：

```yaml
network_mode: host
# ports: 这一段删掉
```

**方案 B：绑到非环回 IP**

`docker-compose.yml` 里把 ports 改成绑到宿主主网卡 IP：

```yaml
ports:
  - "192.168.1.10:53:53/udp"
  - "192.168.1.10:53:53/tcp"
```

宿主自己继续走 systemd-resolved 的 127.0.0.53，外部客户端走 53。

## 文件结构

```
dnsmasq-chn/
├── Dockerfile             Alpine + dnsmasq + bash + curl + busybox crond
├── docker-compose.yml
├── dnsmasq.conf           主配置（baked in）
├── .env.example
├── conf/                  RO 挂入容器
│   ├── customize.conf     手动维护的转发规则
│   └── ulock.list         gfwlist 排除清单
├── scripts/               baked in
│   ├── gfwlist2dnsmasq.sh 上游脚本（cokebar/gfwlist2dnsmasq 修改版）
│   ├── entrypoint.sh
│   └── update.sh
└── data/                  RW 挂入，持久化生成的 gfw.conf
```
