# P0-pre 部署清单：VPS 自建 iroh-relay

> 适用范围：只把公网组件立起来，**不写产品代码**。对应 `docs/DEVELOPMENT_PLAN.md` §3。
> 分工：配置、脚本、清单由 AI 产出；编译、证书签发、公网验收由你执行并下结论。
> 版本依据：iroh 发布 `v1.4.1`（main `1.5.0`），字段取自 `iroh-relay/src/main.rs`，端口取自 `iroh-relay/src/defaults.rs`。
> 状态：**已部署并验证**（2026-11-12），实例参数见 §2.1。

## 0. 交付物

| 文件 | 用途 |
| --- | --- |
| `infra/relay.toml.example` | relay 配置模板（不含真实 token / 域名） |
| `infra/systemd/iroh-relay.service` | VPS 侧 systemd unit（含最小权限与配置缺失断言） |
| `infra/README.md` | 本部署清单与可复现的验收命令 |
| `infra/deploy-relay.sh` | 自包含一键部署脚本（不含凭据，推荐） |

**不在此阶段产出**：`netdiskd.service`（P3）、`docker-compose.yml`（可选）、`tools/poc/*`（P0）。按分阶段推进，不提前做跨阶段改动。

真实 token、域名、邮箱、密钥一律不进仓库。**任何 SSH 密码都不写进本目录的文件。**

### 一键部署（推荐）

脚本自动检测 80 端口占用并切换模式，直接下载官方 `v1.4.1` 的 Linux x86_64 musl 预编译包，避免在 1C1G 机器上现场编译 Rust。以 root 执行：

```bash
export RELAY_HOSTNAME=relay.example.com   # 必填，已解析到本机公网 IP
export ACME_EMAIL=admin@example.com            # 必填，certbot / ACME 联系邮箱
# export RELAY_TOKEN=...                   # 可选；不填自动生成或复用已有值
# export FORCE=1                          # 远程非交互执行时跳过 DNS 确认
bash deploy-relay.sh
```

| 模式 | 触发条件 | RelayUrl | 证书 |
| --- | --- | --- | --- |
| `standalone` | 80/443 空闲 | `https://<hostname>` | 内置 `tokio-rustls-acme`，TLS-ALPN-01（需独占 443） |
| `nginx` | 80 被 nginx 占用 | `https://<hostname>:8443` | **certbot --webroot (HTTP-01)** + `cert_mode = Manual` |

脚本会做 DNS 预检、端口检测、复用已有 token（幂等）、创建用户与目录、写配置与 unit、（nginx 模式下）新增 certbot webroot server 块并签发证书、安装续期 hook、写防火墙规则（**不会执行 `ufw enable`**，以免切断 SSH）、启动并打印日志、最后输出 `RelayUrl` 与 `RELAY_TOKEN`。若 VPS 访问 GitHub 超时，先在有网络的机器下载 `iroh-relay-v1.4.1-x86_64-unknown-linux-musl.tar.gz` 上传到 `/tmp/` 再重跑。

> 官方 release **未附带校验和文件**，脚本打印的 sha256 仅作留档，不能作为完整性校验依据。

---

## 1. VPS 选型

- **规格**：1 vCPU / 1 GB 内存足够。relay 是无状态转发器、不落盘，默认 key cache 约 56 MB。
- **优先看流量包 / 带宽，而不是 CPU**：CGNAT 打洞失败时文件流量全走 relay，1 GB 上传约产生 2 GB 出站（收 + 发）。按 `docs/ARCHITECTURE.md` §2.2 的估算定档，P0-1 实测直连率后再调整。
- **地区**：选离你常用网络近的机房，降低兜底路径 RTT；合规上流量不落盘、不解密。
- **系统**：Debian 12 / Ubuntu 22.04+（systemd 支持 `StateDirectory`、`AmbientCapabilities`）。
- 记录：机型、月费、包含流量、超额单价、公网 IP（v4/v6 情况）。

## 2. 域名与证书前置

1. A / AAAA 记录把 `relay.example.com` 指向 VPS，TTL 调短便于回滚。
2. **不要套 CDN / 反代**：relay 依赖 HTTPS → WebSocket Upgrade 和 UDP 7842，很多 CDN 会拦 Upgrade 或只转发 HTTP/HTTPS。

   **本项目域名 `example.com` 托管在 Cloudflare，子域名用 `relay.example.com`，记录必须设为 `DNS only`（灰云），不能开橙色代理。** 三条硬理由：ACME 挑战需直连源站；橙云会终结 TLS（客户端看到 CF 证书）；CF 免费计划不代理 UDP 7842。

   Cloudflare 控制台：DNS → 添加记录 → 类型 `A`、名称 `iroh-relay`、值 `<VPS 公网 IP>`、**Proxy status = DNS only**、TTL Auto；有 IPv6 再补一条灰云 `AAAA`。检查 **CAA 记录**：若存在，必须允许 `letsencrypt.org`。子域名不要套页面规则 / Always Use HTTPS / HSTS。灰云会暴露源站 IP，对 relay 无影响。

   验证：`nslookup relay.example.com` 应返回源站 IP，而不是 Cloudflare 的 `104.x` / `172.x` 段地址。实测已解析到 `203.0.113.10`。

3. `tls.hostname` 与 `RelayUrl` 的主机名一致；本项目 RelayUrl 为 **`https://relay.example.com:8443`**。
4. `contact` 填可收信邮箱；`prod_tls = true` 用生产 CA（仅 `LetsEncrypt` 模式使用）。

### 2.1 与现有 nginx 共存（本机实际方案）

这台 VPS 的 **80 和 443 都被 nginx 占用**，且有现网业务 `luoke.oceo.top`（443 → `proxy_pass 127.0.0.1:8787`）、catch-all default_server 以及 certbot。**不能停 nginx，也不能抢占 443**。

**关键事实（实测得出，勿凭常识假设）**：iroh-relay 内置的 `tokio-rustls-acme` 使用 **TLS-ALPN-01** 挑战，不是 HTTP-01。按 ACME 规范该挑战**必须走 443 端口**，由服务端在 TLS 握手中应答 `acme-tls/1`。443 被 nginx 占用时，签发必然失败：

```
ERROR acme: Order(BadAuth(... Challenge { typ: TlsAlpn01,
  error: "203.0.113.10: remote error: tls: no application protocol" }))
ERROR acme: 429 rateLimited - too many failed authorizations (5) ... retry after ...
```

因此**给 80 端口加 `/.well-known/acme-challenge/` 反代是无效的**（内置 ACME 根本不用 HTTP-01）。正确做法是让 **certbot** 用 HTTP-01 通过 nginx 80 签发证书，relay 用 `cert_mode = "Manual"` 读这张证书：

| 组件 | 绑定 | 说明 |
| --- | --- | --- |
| nginx | `0.0.0.0:80` / `:443` | 保持原样，现有站点不受影响 |
| nginx 新增 server 块 | `server_name relay.example.com` 的 80 | 用 webroot 提供 certbot 的 HTTP-01 挑战文件 |
| iroh-relay HTTP | `127.0.0.1:8080` | 内部 HTTP 服务（不对外） |
| iroh-relay HTTPS | `[::]:8443` | relay 主流量，**绕过 nginx 443** |
| iroh-relay QUIC | `[::]:7842/udp` | QUIC 地址发现，独立端口 |
| metrics | `127.0.0.1:9090` | 仅本机 |

nginx 新增块（脚本写入 `/etc/nginx/sites-available/iroh-relay-acme` 并软链）：

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name relay.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / { return 404; }
}
```

只匹配这一个主机名，**不影响 certbot 为其他域名续期**；脚本会先 `nginx -t` 校验、失败则回滚新增文件，通过后才 `systemctl reload nginx`（平滑，不中断现有连接）。

证书与权限：

```bash
certbot certonly --webroot -w /var/www/certbot -d relay.example.com \
  --non-interactive --agree-tos -m admin@example.com --keep-until-expiring
cp /etc/letsencrypt/live/relay.example.com/fullchain.pem /var/lib/iroh-relay/certs/default.crt
cp /etc/letsencrypt/live/relay.example.com/privkey.pem  /var/lib/iroh-relay/certs/default.key
chown iroh-relay:iroh-relay /var/lib/iroh-relay/certs/default.{crt,key}
chmod 0600 /var/lib/iroh-relay/certs/default.{crt,key}
```

`Manual` 模式默认读 `cert_dir/default.crt` + `default.key`，正好对应。因为 relay 以非 root 运行，**不能直接指向 `/etc/letsencrypt/live/`（私钥 0600 root）**，必须复制并改属主。续期由 `/etc/letsencrypt/renewal-hooks/deploy/iroh-relay.sh` 处理：只在 `RENEWED_DOMAINS` 含本域名时复制证书并 `systemctl restart iroh-relay`。

带端口的 RelayUrl 已核对源码可行：`iroh-relay/src/client.rs::connect()` 用 `url.join()` 构造拨号地址、只把 scheme 换成 `wss`，并显式处理 `InvalidTargetPort`；`RelayQuicConfig.port` 独立于 HTTPS 端口（默认 7842）。**仍需 P0-1 用真实 endpoint 复测一次**。

## 3. 编译与安装

一键脚本使用官方预编译二进制，无需 Rust 工具链。若坚持自行编译（MSRV 1.91）：

```bash
cargo build --profile optimized-release --package iroh-relay --features server
install -m 0755 target/optimized-release/iroh-relay /usr/local/bin/iroh-relay
```

```bash
useradd --system --home /var/lib/iroh-relay --shell /usr/sbin/nologin iroh-relay
install -d -m 0700 -o iroh-relay -g iroh-relay /var/lib/iroh-relay /var/lib/iroh-relay/certs
install -d -m 0755 /etc/iroh
```

## 4. 配置与 token

```bash
openssl rand -hex 32     # 生成 token，保存好
cp infra/relay.toml.example /etc/iroh/relay.toml
vi /etc/iroh/relay.toml
chown iroh-relay:iroh-relay /etc/iroh/relay.toml
chmod 0600 /etc/iroh/relay.toml
```

**替换项**：`relay.example.com` → `relay.example.com`；`ops@example.com` → 真实邮箱；`<RELAY_TOKEN>` → 随机串；**共存模式下** `cert_mode = "Manual"`、`http_bind_addr = 127.0.0.1:8080`、`https_bind_addr = [::]:8443`（脚本会自动写）。`[limits.client.rx]` 速率按流量包调整。

**注意**：`cert_mode` 大小写敏感（`LetsEncrypt` / `Manual` / `Reloading`）。`access.shared_token` 是顶层 dotted key，必须放在所有 `[table]` 之前。

## 5. 安装服务

```bash
cp infra/systemd/iroh-relay.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now iroh-relay
systemctl status iroh-relay --no-pager
journalctl -u iroh-relay -n 100 --no-pager
```

unit 里的 `AssertPathExists=/etc/iroh/relay.toml` 专门兜住「配置文件路径写错 → 静默回退默认」这个坑：文件缺失时服务直接启动失败，而不是悄悄跑成 `plain HTTP :80 + everyone`。

## 6. 防火墙 / 安全组

| 方向 | 端口 | 协议 | 用途 | 是否公网开放 |
| --- | --- | --- | --- | --- |
| 入站 | 80 | TCP | nginx 现有站点 + certbot HTTP-01 | 是（原本就开） |
| 入站 | 443 | TCP | nginx 现有站点 | 是（原本就开） |
| 入站 | **8443** | TCP | **relay 主流量（HTTPS → WebSocket）** | **是，本次新增放行** |
| 入站 | 7842 | UDP | QUIC 地址发现 | 是 |
| 入站 | 8080 | TCP | relay 内部 HTTP，仅 `127.0.0.1` | **否** |
| 入站 | 9090 | TCP | metrics，仅 `127.0.0.1` | **否** |

```bash
ufw allow 8443/tcp
ufw allow 7842/udp
ufw status
```

**不要执行 `ufw enable`**：SSH 是 2222 非默认端口，贸然启用而未放行会把自己锁在外面（本机 ufw 已 active 且 2222 已放行）。云厂商**安全组**也要同步放行 TCP 8443 与 UDP 7842（最容易漏 UDP）。家里服务器侧不需要任何入站规则，只需出站 TCP 8443 / UDP 7842 / UDP 任意端口。

> 上游 `docker/Dockerfile` 暴露 `3478/udp`，但源码 `DEFAULT_RELAY_QUIC_PORT = 7842`；以源码为准。

## 7. token 轮换流程

1. 生成新 token：`openssl rand -hex 32`；
2. 加入 `/etc/iroh/relay.toml` 的 `access.shared_token` 列表（先保留旧的便于平滑切换）；
3. `systemctl restart iroh-relay`，核对日志；
4. 逐个更新所有客户端的 relay 配置（P1 起由 `nd_init(config_json)` 传入）；
5. 全部更新后移除旧 token，再重启一次；
6. 验证旧 token 已无法建立连接。

**陷阱**：环境变量 `IROH_RELAY_ACCESS_TOKEN` 会用**单个 token 覆盖**整个列表。unit 中刻意没有设置它。另外 `RelayMap::with_auth_token` 会把 token 套到表里**所有** relay（包括 n0 公共兜底条目），只应给自建 relay 的 `RelayConfig` 单独设置。

## 8. 验收清单（你执行）

```bash
# 1) 二进制与参数
iroh-relay --version
iroh-relay --help | grep -E 'config-path|dev'

# 2) 服务状态与日志：确认 TLS 生效、QUIC 地址发现已开、
#    access 不是 everyone、配置【确实被加载】、无 ACME 报错
systemctl status iroh-relay --no-pager
journalctl -u iroh-relay -n 200 --no-pager

# 3) 监听端口
ss -lntup | grep -E ':(80|443|8080|8443|7842|9090)'
#    期望：nginx 占 80/443；relay 127.0.0.1:8080 + [::]:8443 + UDP 7842；9090 仅 127.0.0.1

# 4) nginx 配置与续期 hook
nginx -t
nginx -T 2>/dev/null | grep -A12 'iroh-relay-acme'
certbot certificates | grep -A4 iroh-relay
ls -l /etc/letsencrypt/renewal-hooks/deploy/iroh-relay.sh

# 5) 证书链可信（不要用 -k 掩盖问题）
curl -I https://relay.example.com:8443/
openssl s_client -connect relay.example.com:8443 -servername relay.example.com </dev/null \
  | openssl x509 -noout -issuer -subject -dates

# 6) 从【另一台机器】确认 8080 / 9090 未对公网暴露
nc -vz relay.example.com 9090
nc -vz relay.example.com 8080
#    期望：连接失败 / 超时

# 7) 网络诊断（家里服务器 + 手机蜂窝各跑一次）
iroh-doctor report
```

连通性、带端口 RelayUrl、错误 token 拒绝，由 P0-1 的 echo 示例实测（本阶段不产出产品代码）。

### 本次实测结果（2026-11-12，由部署脚本输出）

| 检查项 | 结果 |
| --- | --- |
| 服务状态 | `active (running)`，`iroh-relay 1.4.1` |
| 监听 | `127.0.0.1:8080`、`[::]:8443`、`UDP :7842`、`127.0.0.1:9090` |
| 证书 | `issuer=Let's Encrypt CN=YE1`，`subject=CN=relay.example.com`，有效期至 2027-02-10 |
| HTTPS | `curl -I https://relay.example.com:8443/` → `HTTP/1.1 404 Not Found`（根路径无内容，握手正常） |
| 现有站点 | `https://luoke.oceo.top/` → `HTTP/2 200`（nginx 未受影响） |
| nginx | `nginx -t` 通过，平滑 reload |
| 外部可达性 | 本机侧 `8443 = True`；`9090 = False`；`8080 = False` |
| 配置加载 | `access.shared_token` 已写入（1 处），无 `<RELAY_TOKEN>` 占位残留 |

### 出口判据（全部满足才进入 P0）

- [x] 8443 公网可达、TLS 证书可信；
- [x] 启动日志确认 TLS 生效、QUIC 地址发现已开启、配置确实被加载；
- [x] 8080 / 9090 未对公网可达；nginx 现有站点仍正常；
- [x] 从蜂窝网络（手机 5G USB 共享）能连上 `https://relay.example.com:8443`（P0-1 实测通过，VPS peer IP `198.51.100.30`）；
- [x] 错误 token 被拒、正确 token 可用，带端口 RelayUrl 被真实 endpoint 接受（P0-1 实测通过）；
- [x] 家用 Linux 服务器不做任何端口映射、出站仍能连通（2026-11-12 实机补测：`MODE=pair` 经 relay echo 往返 PASS、`MODE=online` 5 次中 2 次 OK；详见 `tools/poc/p0-1/README.md` 家用服务器实测章节）。

> **判据虽通过，但附带一条未解决风险**：家用服务器所在家宽 → 本 VPS 的链路存在**新连接随机丢包**（TCP 连上、ClientHello 发出后收不到 ServerHello），curl 约 3/6、openssl 握手 1/10。iroh 靠 10s 拨号超时 + 自动重试能最终上线，但不适合作为「稳定可用」来假设。已登记为架构 **R14**，P3 部署 `netdiskd` 前需要处理或明确接受。VPS 侧、本机 Windows 侧的成功率均为 6/6，故不是 relay 服务端故障。

> **17:43 定性更正**：跨目标对照显示境内（`mirrors.ustc.edu.cn` / `www.baidu.com`）与其他境外目标（`static.crates.io` / `www.cloudflare.com`）握手均 5/5、ICMP 0% 丢包，而到本 VPS 波动于 1/10 ~ 8/10；突发与间隔连接无差异，排除限速。所以**不是家宽国际出口、也不是「香港 VPS」地域的问题**，而是到该 IP 的特定路径间歇性丢包。换大陆 VPS 并非唯一解，且需先过备案（8443 也在检测范围）与固定小带宽两道门槛；更划算的优先项是换回程优化（CMI / CN2 GIA / 9929）的港服。详见 `tools/poc/p0-1/README.md`「补充对照与定性更正」。

## 9. 常见故障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `tls: no application protocol` / ACME 429 | 内置 ACME 用 **TLS-ALPN-01**，要求独占 443；被 nginx 占用时连试 5 次触发限流 | 改 certbot `--webroot` HTTP-01 + `cert_mode = Manual`，见 §2.1；限流约 1 小时后自动解除 |
| 服务起来了但只有 80、无 TLS、`everyone` | 配置路径写错，`Config::load()` 静默回退默认 | 核对 `ExecStart`；unit 的 `AssertPathExists` 已兜底；看日志确认 |
| 证书签发失败（certbot） | 80 未放行 / 域名未解析到本机 / webroot server 块未生效 / CAA 未放行 LE | `nginx -t`、`nginx -T` 确认新块；`dig`；检查 CAA |
| `unknown variant cert_mode` | 写成 `lets_encrypt` | 改成大小写正确的 `LetsEncrypt` / `Manual` |
| `no server certificate chain resolved` | `Manual` 模式下 `cert_dir` 里缺 `default.crt` / `default.key` | 复制 certbot 证书并 chown 给 `iroh-relay` |
| 证书续期后 relay 仍用旧证 | 续期 hook 未执行或被 `RENEWED_DOMAINS` 过滤 | 检查 `/etc/letsencrypt/renewal-hooks/deploy/iroh-relay.sh`，必要时手动重启 |
| `--dev` 启动报错 | `--dev` 与 `LetsEncrypt` 不兼容，且只跑 `http://localhost:3340` | 生产不要用 `--dev` |
| 绑定特权端口权限不足 | 非 root 用户缺 `CAP_NET_BIND_SERVICE` | unit 的 `AmbientCapabilities` 或 `setcap`；共存模式全是非特权端口 |
| 证书目录写不进去 | `ProtectSystem=strict` 下只有 `ReadWritePaths` 可写 | 保持 `cert_dir` 与 `StateDirectory` 一致 |
| 客户端连 8443 失败 | 云安全组 / ufw 未放行 8443 | 补放行；`ss -lntp` 先确认 relay 在听 |
| 客户端能连 HTTPS 但同步卡住 | 防火墙 / 代理拦了 WebSocket Upgrade | 放行 Upgrade，去掉 CDN 反代 |
| 地址发现不生效 | 云安全组漏放 UDP 7842 | 补放行；`iroh-doctor report` 复核 |
| 现有站点挂了 | nginx reload 前配置有误 | 脚本在 `nginx -t` 失败时回滚新增块；必要时删除软链后 reload |
| 文档参数对不上 | 上游 `docker/README.md` 写 `--config`、暴露 `3478/udp` | CLI 只有 `--config-path` / `-c`；端口以源码 `7842` 为准 |
| 客户端 TLS 握手超时（TCP 已连、ClientHello 已发、收不到 ServerHello） | 跨境链路新连接随机丢包 / PMTU 黑洞，**不是 relay 故障** | `curl -v` 与 `RUST_LOG=iroh=debug,iroh_relay=debug` 定位；对比 VPS 本机与另一客户端成功率；换线路或加大重试与超时。本例对 8443 做 `TCPMSS --set-mss 1200` **无效**，规则已撤销，勿盲改防火墙 |

## 10. 检查点提交内容

P0-pre 交付：VPS 规格与流量套餐、域名与证书（含续期 hook）、端口共存方案、防火墙规则、token 轮换方式、§8 每项验收的实际输出。剩余三项蜂窝 / token / 带端口 RelayUrl 验证由 P0-1 完成后再给 Go/No-Go 结论。
