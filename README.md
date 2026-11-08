# dnsmasq-chn

[![Build and publish Docker image](https://github.com/smileawei/gfwlist2dnsmasq/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/smileawei/gfwlist2dnsmasq/actions/workflows/docker-publish.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/smileawei/gfwlist2dnsmasq.svg)](https://hub.docker.com/r/smileawei/gfwlist2dnsmasq)

容器化的 dnsmasq，做中国大陆环境的 DNS 分流：手工配置的域名走各自指定的上游，gfwlist 域名走 GFW 上游，其余域名走默认上游，每天自动刷新 gfwlist 规则并热重载。

镜像：`smileawei/gfwlist2dnsmasq` （多架构 amd64 / arm64）

## 工作机制

```
                  ┌─ 手工域名 ─→ conf/upstreams/*.conf 中指定的上游
client → dnsmasq ──┼─ GFW 域名 ─→ GFW_UPSTREAM_IP:GFW_UPSTREAM_PORT
                  └─ 其余域名 ─→ DEFAULT_UPSTREAM (e.g. 223.5.5.5)
```

- 容器启动时 entrypoint 把 `$DEFAULT_UPSTREAM` 写到 `/etc/dnsmasq.d/00-upstream.conf`
- `data/gfw.conf` 保存完整的 GFW 规则缓存。启动时已有非空缓存会直接复用，缺失或为空时才尝试下载。
- 手工转发规则统一放在 `conf/upstreams/`，只读取顶层可见的 `*.conf` 文件。`reload.sh` 合并这些规则与 GFW 缓存，排除与手工域名及其子域冲突的 GFW 规则，生成 `data/servers.conf`。
- dnsmasq 通过 `servers-file=` 读取 `servers.conf`。目录监视程序检测保存、新增、删除和重命名操作，校验成功后原子替换此文件并发送 SIGHUP；自定义规则通常在几秒内生效，无需重启容器，也不依赖重新下载 gfwlist。
- 容器内 BusyBox crond 按 `$UPDATE_CRON` 运行 `update.sh`：下载完整 GFW 规则，再调用同一个 `reload.sh` 合并并热加载。发布文件权限为 `0644`；下载或校验失败时保留旧生效规则。
- cron 日志通过保持 root 身份的 crond 进程输出到 Docker 日志，避免 dnsmasq 降权后无法打开 `/proc/1/fd/2` 导致更新命令根本未执行。

## 目录结构与维护分工

日常主要维护 `conf/upstreams/*.conf` 和 `.env`：前者决定指定域名使用哪个上游，后者控制默认上游、GFW 上游和容器部署参数。`data/` 保存脚本生成的缓存和生效规则。

```text
dnsmasq-chn/
├── conf/
│   └── upstreams/              手工上游规则，保存后自动热加载
│       ├── customize.conf      通用自定义转发规则
│       └── ulock.conf          Netflix、Disney 等解锁规则
├── data/                       自动生成、持久化到宿主机
│   ├── 00-upstream.conf        根据 DEFAULT_UPSTREAM 生成的默认上游
│   ├── gfw.conf                完整 GFW 规则缓存
│   ├── servers.conf            合并后由 dnsmasq 实际加载的规则
│   ├── .reload.lock            串行执行规则重载的锁文件
│   └── .gitkeep                让 Git 保留空数据目录
├── scripts/                    构建时写入镜像
│   ├── entrypoint.sh           初始化配置、启动监视器和 cron、运行 dnsmasq
│   ├── gfwlist2dnsmasq.sh      下载、解码并转换 GFW 列表
│   ├── update.sh               刷新完整 GFW 缓存，再调用重载脚本
│   ├── reload.sh               离线合并、校验、原子发布规则并发送 SIGHUP
│   └── watch-upstreams.sh      监视手工规则的保存、增删和重命名
├── tests/
│   ├── test_gfwlist_generator.sh 规则转换和下载失败处理测试
│   ├── test_update.py          更新脚本与重载脚本衔接测试
│   └── test_reload.py          规则合并、错误保留和热加载测试
├── .github/workflows/
│   └── docker-publish.yml      构建、发布 amd64/arm64 镜像及同步 README
├── .env                        当前部署参数，不提交到 Git
├── .env.example                环境变量模板
├── dnsmasq.conf                全局 DNS 配置，构建时写入镜像
├── docker-compose.yml          服务、端口、挂载、重启策略和日志配置
├── Dockerfile                  镜像依赖、脚本、入口和健康检查
├── .gitignore                  排除 .env 和 data/ 生成数据
└── README.md                   配置与运维说明
```

宿主机与容器的对应关系：

| 宿主机路径 | 容器路径 | 维护方式 |
|---|---|---|
| `conf/` | `/opt/dnsmasq-chn/conf`，只读挂载 | 在宿主机编辑手工规则，容器负责监视和读取 |
| `data/` | `/etc/dnsmasq.d`，读写挂载 | 脚本自动维护；容器重建后保留 |
| `scripts/*.sh` | `/opt/dnsmasq-chn/scripts/`，写入镜像 | 修改后重新构建镜像 |
| `dnsmasq.conf` | `/etc/dnsmasq.conf`，写入镜像 | 修改后重新构建镜像 |

`data/gfw.conf` 保留完整源规则，供每次合并时使用；`data/servers.conf` 排除与手工规则冲突的 GFW 条目，再加入手工规则。直接维护 `conf/upstreams/` 即可，生成文件会在下次更新或重载时被覆盖。运行期间保留 `.reload.lock`，它用于协调目录监视、手动重载和定时更新。

容器内还会自动生成以下运行状态，无需手工维护：

| 容器内文件 | 作用 |
|---|---|
| `/opt/dnsmasq-chn/runtime.env` | 保存 GFW 上游等运行参数，供 cron 任务和重载脚本读取 |
| `/etc/crontabs/root` | 根据 `UPDATE_CRON` 生成的定时任务 |
| `/var/run/dnsmasq.pid` | 记录 dnsmasq 进程，供重载脚本发送 SIGHUP |
| `/var/run/dnsmasq-chn-crond.pid` | 定位 cron 进程的日志输出描述符 |

GitHub Actions 在推送 `main`、推送 `v*` 标签或手动触发时构建并发布镜像；`main` 的发布流程还会将本 README 同步到 Docker Hub。`tests/` 可用于本地回归检查：

```bash
python3 -B -m unittest discover -s tests -v
bash tests/test_gfwlist_generator.sh
```

## 快速开始（已克隆仓库）

```bash
# 1. 拷贝并编辑环境变量
cp .env.example .env
$EDITOR .env

# 2. 启动 —— 二选一
docker compose up -d --build       # 本地 build
docker compose pull && docker compose up -d   # 从 Docker Hub 拉镜像

# 3. 使用容器自带的 dig 测试
docker compose exec dnsmasq-chn dig @127.0.0.1 baidu.com    # 默认上游
docker compose exec dnsmasq-chn dig @127.0.0.1 google.com   # GFW 上游
```

## 全新部署（使用已发布镜像）

在已安装 Docker、可运行 `docker compose` 的新机器上操作。以下以 `/opt/dnsmasq-chn` 为部署目录，准备两个配置文件和两个目录即可。

### 1. 创建目录

```bash
mkdir -p /opt/dnsmasq-chn/conf/upstreams /opt/dnsmasq-chn/data
chmod 755 /opt/dnsmasq-chn/data
cd /opt/dnsmasq-chn
```

`conf/upstreams/` 可以为空。`data/` 需允许降权运行的 dnsmasq 读取规则，文件内容由程序生成，无需手工创建。

### 2. 配置上游与端口

创建 `/opt/dnsmasq-chn/.env`：

```dotenv
GFW_UPSTREAM_IP=10.220.10.253
GFW_UPSTREAM_PORT=53
DEFAULT_UPSTREAM=223.5.5.5 119.29.29.29
UPDATE_CRON=0 4 * * *
TZ=Asia/Shanghai
DNS_PORT=5300
```

将 `GFW_UPSTREAM_IP` 改为新机器能够访问的分流 DNS。示例中的 `10.220.10.253` 是原部署网络内的地址，仅当新机器也能访问它时才可沿用。

### 3. 创建 Compose 配置

创建 `/opt/dnsmasq-chn/docker-compose.yml`：

```yaml
services:
  dnsmasq-chn:
    image: smileawei/gfwlist2dnsmasq:latest
    container_name: dnsmasq-chn
    restart: unless-stopped
    ports:
      - "${DNS_PORT:-5300}:53/udp"
      - "${DNS_PORT:-5300}:53/tcp"
    env_file:
      - .env
    volumes:
      - ./conf:/opt/dnsmasq-chn/conf:ro
      - ./data:/etc/dnsmasq.d
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

此配置直接拉取已发布镜像，无需复制源码、脚本或主配置文件。

### 4. 启动并检查首次更新

```bash
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail 100
```

首次启动会自动下载 GFW 规则，生成 `data/gfw.conf` 和 `data/servers.conf`，并按上述配置安装北京时间每天 04:00 的更新任务。检查日志中的下载、合并与启动结果；下载失败时容器仍可能通过健康检查，不能只看 `healthy` 判断 GFW 规则是否就绪。

如下载失败，修复网络或配置后手动重试；如果修改了 `.env`，先执行 `docker compose up -d` 重新读取参数：

```bash
docker compose exec dnsmasq-chn /opt/dnsmasq-chn/scripts/update.sh
```

### 5. 验证解析

使用容器自带的 `dig`，无需在宿主机额外安装：

```bash
docker compose exec dnsmasq-chn dig @127.0.0.1 baidu.com
docker compose exec dnsmasq-chn dig @127.0.0.1 google.com
```

其他机器安装了 `dig` 时，可将 `新服务器IP` 替换为实际地址，测试对外端口：

```bash
dig @新服务器IP -p 5300 google.com
```

### 6. 添加或迁移自定义规则

镜像包含程序和主配置，手工规则由宿主机提供。要沿用现有规则，将旧部署中 `conf/upstreams/*.conf` 复制到新机器的 `/opt/dnsmasq-chn/conf/upstreams/`，并调整其中的上游地址；镜像不会自动带入仓库中的 `customize.conf`、`ulock.conf`。

也可自行创建 `/opt/dnsmasq-chn/conf/upstreams/work.conf`，填写实际可达的上游，例如：

```ini
server=/example.com/192.168.1.20#53
```

保存后自动校验并热加载。支持顶层可见 `.conf` 文件中的 `server=`、`rev-server=` 规则，新增、修改和删除均无需重启。

### 7. 接入客户端与后续升级

普通路由器、手机和电脑填写 DNS 服务器地址时通常使用标准 53 端口。若需直接为这些设备提供解析，确认宿主机 53 端口空闲后，将 `.env` 中的 `DNS_PORT` 改为 `53`，再执行：

```bash
docker compose up -d
```

客户端随后填写新服务器 IP。保留 `5300` 时，客户端需要支持显式指定 DNS 端口。

后续升级镜像：

```bash
docker compose pull
docker compose up -d
```

部署目录中的 `.env`、`conf/` 和 `data/` 会保留。

已有源码时，修改本地脚本、`dnsmasq.conf` 或 Dockerfile 后，使用 `docker compose up -d --build` 构建并应用本地版本。旧部署首次升级到自定义规则热加载版本后，还需运行一次 `update.sh` 刷新完整 GFW 缓存；此后修改 `conf/upstreams/*.conf` 会自动生效。

## 配置 (`.env`)

部署时读取 `.env`；`.env.example` 作为新部署的模板。以下值与模板一致，请按实际网络调整。

| 变量 | 说明 | 示例 |
|---|---|---|
| `GFW_UPSTREAM_IP` | GFW 域名的上游，手工规则除外（必填） | `10.220.10.253` |
| `GFW_UPSTREAM_PORT` | 上面这台 DNS 的端口 | `53` |
| `DEFAULT_UPSTREAM` | 默认候选上游，多个用空格分隔，并非固定顺序的主备 | `223.5.5.5 119.29.29.29` |
| `UPDATE_CRON` | 每天什么时候刷新 gfwlist (busybox crontab 格式) | `0 4 * * *` |
| `TZ` | 容器时区 | `Asia/Shanghai` |
| `DNS_PORT` | 宿主上对外暴露的端口 | `5300` |

`dnsmasq.conf` 管理全局 DNS 行为，主要配置如下：

| 配置 | 作用 |
|---|---|
| `log-facility=-`、`log-queries=extra` | 输出日志和查询详情，由 Docker 收集 |
| `no-resolv` | 使用显式配置的上游，不从容器的 `/etc/resolv.conf` 读取上游 |
| `cache-size=10000` | DNS 缓存容量为 10000 条 |
| `neg-ttl=60` | 负缓存缺省 TTL 为 60 秒 |
| `conf-file=/etc/dnsmasq.d/00-upstream.conf` | 加载启动时生成的默认上游 |
| `servers-file=/etc/dnsmasq.d/servers.conf` | 加载合并规则，收到 SIGHUP 后重新读取 |

## 自定义域名上游

所有手工规则统一放在 `conf/upstreams/`，使用原生 dnsmasq 的 `server=` 或 `rev-server=` 格式，并支持注释和空行。现有规则按用途保存在：

- `conf/upstreams/customize.conf`：通用自定义转发规则。
- `conf/upstreams/ulock.conf`：Netflix、Disney 等解锁域名的转发规则。

这两个文件的处理机制相同，文件名只用于分类；每条规则自己的 IP 和端口决定上游。

后续可直接新建 `conf/upstreams/work.conf` 等任意 `*.conf` 文件，例如：

```ini
server=/example.com/192.168.1.20#53
server=/another.example/192.168.1.30#5353
```

保存后会自动校验并热加载，无需运行更新命令或重启容器。新增文件、修改上游、增删域名或删除整个规则文件都会触发加载；删除手工覆盖后，对应域名恢复使用 GFW 或默认上游。

无需修改主配置、Compose 或增加环境变量。仅加载此目录顶层可见的 `*.conf` 文件；备份文件请使用其他后缀。

此目录只支持定义上游的 `server=` 和 `rev-server=`。`address=`、缓存设置等其他指令会报错，并保留上一次生效的规则；全局 dnsmasq 配置仍在主配置中维护，修改后需重建或重启。语法错误的规则也不会替换正在使用的文件，具体原因见容器日志。容器启动时若新规则非法，但已有合法的 `servers.conf`，会继续使用该快照。

仓库现有规则的上游初值为 `10.220.10.253#53`，请直接编辑为所需的 DNS，也可以为不同域名指定不同上游。这些文件内的地址由你手工维护，不随 `.env` 中的 `GFW_UPSTREAM_IP` 变化。

## 日常运维

不同修改的生效方式：

| 修改内容 | 生效方式 |
|---|---|
| `conf/upstreams/*.conf` | 保存、删除或重命名后自动校验并热加载 |
| `.env` 中的默认上游、定时计划、时区、端口 | `docker compose up -d`，重新创建容器以读取新参数 |
| `.env` 中的 GFW 上游 IP/端口 | 先 `docker compose up -d`，再运行 `update.sh` 更新缓存中的地址，或等待定时更新 |
| `dnsmasq.conf`、`scripts/*.sh`、`Dockerfile` | `docker compose up -d --build`，重新构建并应用镜像 |
| `docker-compose.yml` 中的端口、挂载等运行参数 | `docker compose up -d` 应用服务配置 |
| `README.md`、`tests/` | 文档和测试修改，不改变正在运行的 DNS 服务 |

`docker compose restart` 会继续使用已有容器的环境变量，修改 `.env` 后应使用 `up -d`。离线 `reload.sh` 负责合并现有缓存；修改 GFW 上游后，需要 `update.sh` 重新生成缓存中的地址。

```bash
# 看日志
docker compose logs -f

# 立即手动更新一次 gfwlist
docker compose exec dnsmasq-chn /opt/dnsmasq-chn/scripts/update.sh

# 编辑 conf/upstreams/*.conf 后会自动生效；也可手动强制离线重载
docker compose exec dnsmasq-chn /opt/dnsmasq-chn/scripts/reload.sh

# 改了 .env (上游、cron、端口) 后重建容器
docker compose up -d

# 如果改了 GFW 上游，还需重新生成已有的 GFW 规则
docker compose exec dnsmasq-chn /opt/dnsmasq-chn/scripts/update.sh
```

注意：

- `conf/upstreams/*.conf` 保存后自动热加载，手工重载也无需访问下载源。
- `data/gfw.conf` 是完整 GFW 缓存，`data/servers.conf` 是合并后实际加载的规则；两者都由脚本生成，请在 `conf/upstreams/` 中维护自定义内容。
- GFW 缓存持久化在宿主，容器重建不会丢，也不会因为重启自动重新下载。修改 GFW 上游后需手动更新，或等待下一次定时任务。

自动更新排障：

```bash
# 查看最近两天的定时任务和更新日志
docker compose logs --since 48h dnsmasq-chn | grep -E '\[update|\[reload|\[watch|\[entrypoint|crond|dnsmasq:'

# 查看宿主机规则文件最近的写入时间
stat data/gfw.conf data/servers.conf

# 手动运行一次，查看下载、校验和重载是否成功
docker compose exec dnsmasq-chn /opt/dnsmasq-chn/scripts/update.sh
```

正常更新会出现 GFW 下载、合并规则和发送 SIGHUP 的日志；自定义文件保存后也应出现重载日志。只有开始日志但没有完成日志时，查看紧随其后的下载或校验错误；`UPDATE_CRON` 按容器的 `TZ` 时区执行。

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
