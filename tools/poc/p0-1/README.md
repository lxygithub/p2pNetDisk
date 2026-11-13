# P0-1 验证：真实 endpoint 连自建 relay

对应 `docs/DEVELOPMENT_PLAN.md` §4。这是一个最小 Rust 示例，**不是产品代码**：起两个 iroh endpoint，强制只走 relay，用 ALPN `netdisk/p0-1/echo/0` 做一次 echo 往返。

验证目标：

1. 带非标准端口的 `RelayUrl`（`https://relay.example.com:8443`）被真实 endpoint 接受；
2. `access.shared_token` 生效：正确 token 能连、错误 token 被拒；
3. relay 转发可用（两端 `clear_ip_transports()`，避免本机直连绕过 VPS）。

## 构建

```bash
cd tools/poc/p0-1
cargo build
```

Rust ≥ 1.91。iroh 锁在 `1.4.1`，与 VPS 上的 `iroh-relay 1.4.1` 对齐。

## 运行

token 从 VPS 的 `/etc/iroh/relay.toml` 读取，**不要写进仓库或命令行历史**。PowerShell 示例：

```powershell
$env:RELAY_URL = "https://relay.example.com:8443"
$env:RELAY_TOKEN = "<从 VPS 读取的 token>"
$env:MODE = "pair"
.\target\debug\p0-1-relay-probe.exe

$env:MODE = "wrong"       # 错误 token，预期 PASS（被拒绝）
.\target\debug\p0-1-relay-probe.exe

$env:MODE = "online"      # 只等 endpoint 上线（20s 超时）
.\target\debug\p0-1-relay-probe.exe
```

Bash 下从 VPS 动态取 token（命令里不出现 token 字面量）：

```bash
cd tools/poc/p0-1
cargo build
TOKEN="$(ssh -p 2222 root@203.0.113.10 "sed -n 's/^access.shared_token = \[\"\\([^\"]*\\)\".*/\1/p' /etc/iroh/relay.toml | head -1")"
RELAY_URL=https://relay.example.com:8443 RELAY_TOKEN="$TOKEN" MODE=pair ./target/debug/p0-1-relay-probe
```

| MODE | 期望 |
| --- | --- |
| `pair` | `PASS: 带端口 RelayUrl + token + relay 转发全部可用`，退出码 0 |
| `wrong` | `PASS: 错误 token 被拒绝（符合预期）`，退出码 0 |
| `online` | `[online] OK`，退出码 0 |

`pair` / `wrong` 各有 40s 超时；失败时打印具体错误（`[dial] failed: ...` 或 TIMEOUT）。

**诊断日志（可选）**：设置 `RUST_LOG` 即启用 `tracing-subscriber`，打印 iroh / iroh-relay 内部事件，用于定位 `online()` 卡在哪一步：

```bash
RUST_LOG=iroh=debug,iroh_relay=debug MODE=online ./target/debug/p0-1-relay-probe
```

未设置 `RUST_LOG` 时不装 subscriber，默认行为与输出完全不变。这是 P0-1 排查家用服务器链路时加的能力，保留供 P0-2 / P1 复用。

## 蜂窝网络验证（复现步骤）

把运行机器切到**手机热点 / 蜂窝网络**，保持 `MODE=pair` 再跑一次。这一步验证「出门在外」路径确实能经 relay 建立连接，同时可在 VPS 上观察流量：

```bash
journalctl -u iroh-relay -f
sudo ss -lntup | grep -E ':(8443|7842)'
```

并记录：首连耗时、echo 是否成功、是否出现直连（`direct`）还是始终走 relay。若两端都在 NAT 后且打洞失败，全部流量经 relay 属预期，用于后续 VPS 流量包定档。

## 注意事项

- `presets::Empty` 清空了默认 relay 与地址发现，再用 `RelayMode::Custom` 只配自建 relay；这正是架构 §6.1 的设计。
- token 只绑在自建 relay 的 `RelayConfig` 上。切勿改用 `RelayMap::with_auth_token`，那会把 token 套到兜底的 n0 公共 relay 上导致认证失败。
- `clear_ip_transports()` 是为了让本机两个 endpoint 也强制经 VPS 转发；真实应用场景不会清除 IP 传输（要尽量直连）。
- 本示例不产出 `tools/poc/` 之外的任何代码，不做 UI、不引入 blobs。

## 实测结果（2026-11-12，本地 Windows → VPS）

| MODE | 结果 |
| --- | --- |
| `pair` | `[accept] echoed 10 bytes` → `[dial] received: "p0-1 hello"` → **PASS**，退出码 0 |
| `wrong` | 错误 token 连接被拒（超时）→ **PASS**；正确 token 已先验证可用，故不是假阳性 |
| `online` | `[online] OK` → **PASS** |

结论：**带 `:8443` 的 RelayUrl 被真实 iroh 1.4.1 endpoint 接受**；`access.shared_token` 生效；relay 转发 echo 可用。

### 三个实测踩到的坑（已固化到代码 / 命令）

1. **crypto provider**：Windows 上直跑报 `Missing or incompatible rustls crypto provider configured`。需 `rustls::crypto::ring::default_provider().install_default()` 并显式 `.crypto_provider(provider)`。
2. **EndpointAddr 必须带 relay URL**：`presets::Empty` 清空地址发现后 `addr()` 只有 EndpointId，`connect()` 报 `No addressing information available`。必须 `.with_relay_url(relay)` —— 这正是架构 §6.1「配对 ticket 要带含 relay URL 的 EndpointAddr」的实测印证。
3. **Windows SSH 输出的 CRLF 会污染 token**：`$(ssh ... awk ...)` 取回的 token 长度 66 而 VPS 上是 64，导致 `Authorization: Bearer` 不匹配、服务端回 `The relay denied our authentication (not authorized)`；更隐蔽的是它会让「错误 token 被拒」变成**假阳性**。取回后用 `tr -d '\r\n'` 清洗，并用 sha256 比对本地与 VPS 一致再跑。

Bash 下的推荐写法（token 不出现在命令行字面量里）：

```bash
TOKEN="$(ssh -p 2222 root@203.0.113.10 "awk -F '\"' '/^access.shared_token/ {print \$2}' /etc/iroh/relay.toml")"
TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r\n')"
```

### 蜂窝链路实测（2026-11-12，手机 5G USB 网络共享）

**结论：PASS。P0-pre + P0-1 的出口判据已全部满足（家用服务器侧连通性留 P1 补测）。**

| 检查项 | 实测 |
| --- | --- |
| 出口网卡 | `以太网 4 / Remote NDIS Compatible Device #3`（手机 USB 网络共享），IP `10.0.0.174`，网关 `10.0.0.53` |
| 到 relay 的路由 | `Find-NetRoute -RemoteIPAddress 203.0.113.10` → `ifIndex 35 / NextHop 10.0.0.53 / Metric 0`；tracert 首跳即 `10.0.0.53`。**未走 WireGuard / Tailscale / ZeroTier 隧道** |
| 8443 | `Test-NetConnection` = True，运营商未拦非标准端口 |
| VPS 侧 peer IP | `198.51.100.30`（此前家宽为 `198.51.100.40`）→ 链路确实切换 |
| `MODE=pair` | `[accept] echoed 10 bytes` → `[dial] received: "p0-1 hello"` → PASS |
| `MODE=online` | `[online] OK` → PASS |

两点说明：

- `Invoke-RestMethod https://api.ipify.org` 本地返回 `203.0.113.30`，与 relay 看到的 `198.51.100.30` 不同，应是该 HTTP 请求走了系统分流/代理或运营商多出口。**到 relay 的真实路径由 `Find-NetRoute` 与 VPS peer IP 双重确认**，不影响结论。
- 日志里的 `actor errored Stream terminated, exiting` 是 PoC 程序 echo 完主动退出导致的正常断连 WARN，不是故障。

复现步骤：

1. 手机**关闭 WiFi**，确认在用蜂窝数据；开个人热点（USB 网络共享比 WiFi 热点更稳）。
2. 电脑**断开家里 WiFi / 网线**，只保留手机热点这一条出口。
3. 确认确实走了蜂窝（PowerShell）：

   ```powershell
   (Invoke-RestMethod https://api.ipify.org).Trim()
   Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Select-Object ifIndex, NextHop
   Find-NetRoute -RemoteIPAddress 203.0.113.10 | Select-Object -First 1
   Test-NetConnection relay.example.com -Port 8443
   ```

   本机同时挂了 WireGuard / Tailscale / ZeroTier 虚拟网卡，**必须看 `Find-NetRoute` 而不是只看公网 IP**，否则会误判流量被 VPN 拐走。

4. 重跑 `MODE=pair` 与 `MODE=online`（token 仍按上文从 VPS 动态取并 `tr -d '\r\n'` 清洗）。
5. VPS 上 `journalctl -u iroh-relay -f`，看 peer IP 是否变成运营商出口 IP；记录首连耗时、echo 结果、是否始终走 relay。

**边界**（这项测的是传输链路，不是 Android 客户端）：

| 能验证 | 不能验证（留 P4 真机） |
| --- | --- |
| 蜂窝链路可达、8443 非标准端口是否被运营商放行 | Android 前台服务 / Doze / 厂商省电白名单 |
| 双层 NAT 下经 relay 的 echo 往返 | JNI Context 初始化、`rustls-platform-verifier` |
| 首连耗时、是否始终走 relay（用于流量包定档） | Wi-Fi ↔ 蜂窝切换时的 QUIC 连接迁移（PoC echo 完即退出，保持不了长连接） |
| relay 鉴权在非家庭网络下同样有效 | 移动网络下的大文件流量策略 |

若 `Test-NetConnection ... -Port 8443` 在蜂窝下失败，说明运营商/热点拦了非标准端口，这是真实发现，需回到端口方案（如改走 443 的 nginx 分流）而不是继续调 PoC。UDP 7842 在蜂窝下的可达性属于直连相关，可在 VPS 侧观察 QUIC 地址发现日志。

---

## 家用 Linux 服务器实测（2026-11-12，补齐 P0-pre 最后一项判据）

此前 `infra/README.md` §8 保留了一项未验：**「家用 Linux 服务器不做任何端口映射，出站仍能连通」**。本轮在该机器上跑真实 endpoint，把它补上。

### 环境事实

| 项 | 实测 |
| --- | --- |
| 登录 | `ssh yuan@100.64.0.10`（`100.x` 是 Tailscale 网段，免密），用本机 Windows 原生 `ssh.exe` |
| 系统 | Ubuntu 24.04.5 LTS / x86_64 / 4 核 / 16 GB / 57 GB 空闲 |
| 出口 | `enp4s0f1 = 192.168.1.8/24`，默认路由 `via 192.168.1.1`；**物理网卡 MTU 1450** |
| IPv6 | 有公网地址 `2001:db8:2:...`，且**有** IPv6 默认路由 `via fe80::1`；国际方向很慢（12s 仅收 484 KB / 21 MB）。relay 域名只有 A 记录，实际走 IPv4 |
| 叠加网络 | Tailscale / ZeroTier / `optun` TUN / 5 个 Docker 网桥，共 **14 个 UP 接口** |
| 工具链 | 原本无 Rust；本轮装 `rustc 1.99.1`（`--no-modify-path`，未改 `.bashrc` / `.profile`、未用 sudo） |
| 代理 | `~/.bashrc:36-39` 设 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY=http://127.0.0.1:7897`，但代理未运行；`/etc/resolv.conf` 被 Tailscale MagicDNS 接管 |

### 实测结果

| 项 | 结果 |
| --- | --- |
| 直连 relay（绕代理） | `curl --noproxy '*' -I https://relay.example.com:8443/` → `404`，证书 `Let's Encrypt YE1` 可信 |
| `MODE=online` | 5 次中 **2 次 OK**，3 次 TIMEOUT |
| `MODE=pair` | 3 次中第 3 次 **PASS**：`[accept] echoed 10 bytes` → `[dial] received: "p0-1 hello"` |
| TLS 握手基线 | openssl `s_client` **1/10 成功**；单次 8s 机会太少，iroh 的 10s 拨号 + 自动重试更容易扛过去 |
| conntrack | `2684 / 262144`，远未打满，排除本机表满 |

**结论**：判据打勾 —— 家用服务器不做任何入站映射、纯出站即可作为 iroh endpoint 上线并经 relay 完成 echo 往返。但准确定性是「**可用但链路不稳**」，不是「稳定可用」。

### 根因：家宽 → 港服 VPS 这条链路的新连接随机丢包

`RUST_LOG=iroh=debug` 输出显示：TCP 已连上（`local 192.168.1.8 → 203.0.113.10:8443`）、`Starting TLS handshake` 之后 10s 无进展 → `timeout (>10s) trying to establish a connection`。`curl -v` 同样显示 **TCP 连上、ClientHello 发出、收不到 ServerHello**。

对照表（同一时刻、同一 relay）：

| 来源 | 8443 成功率 |
| --- | --- |
| VPS 本机 | 6/6 |
| 本机 Windows（5G） | 6/6 |
| 家用服务器（家宽） | 3/6（curl）、1/10（openssl 握手） |

被**逐一否掉**的假设，避免以后重复排查：

- **MTU / 大包分片**：`ping -M do -s 1400` 有丢包、`-s 1200` 全通，`tracepath` 只能看到本机 `pmtu 1450`（ICMP 被过滤，PMTU 发现失效）。据此在 VPS 对 8443 的入站 SYN 试过 `TCPMSS --set-mss 1200`，**握手成功率没有改善**，规则已撤销（`mangle PREROUTING` 恢复原状）。所以不是单纯的分片问题。
- **8443 被运营商拦**：VPS 本机与本机 Windows 都 6/6，排除。
- **DNS 劫持**：20 次解析全部返回 `203.0.113.10`；`luoke.oceo.top` 的「4/4 成功」对照无效，因为它解析到 Cloudflare IPv6，不是这台 VPS。
- **relay 服务端故障 / 负载**：VPS `load average 0.00`，relay 日志里连失败的握手都没有记录（没到 HTTP 层）。
- **本机 conntrack / socket 耗尽**：见上表，排除。
- **代理拦截**：`http_proxy` 确实存在且指向未运行的 7897，会让 `curl` 直接失败；但用 `--noproxy '*'` 后仍有随机超时，故代理不是根因。

### 对 P3（服务端部署）的约束

1. **`netdiskd.service` 必须显式清理代理环境**：`~/.bashrc` 的 `HTTP_PROXY/ALL_PROXY` 会被部分 HTTP 客户端读取并指向一个没在跑的 7897。unit 里建议 `UnsetEnvironment=HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy` 并设 `NO_PROXY=*`；cargo 构建同理（本次 `cargo build` 就是被它拦住的）。
2. **不要用 `Endpoint::online()` 当启动门槛**：本链路 20s 预算不够。改为监听 home relay 变化 / 依赖 iroh 自身重连，并给启动健康检查更长的窗口与退避。
3. **14 个 UP 接口**：iroh 会枚举本地直连地址，Docker 网桥与多个 VPN 接口会混进候选列表，P3 需评估是否造成地址膨胀与打洞路径误选。
4. **Rust 工具链与镜像**：官方源 / crates.io 在该线路仅 40–60 KB/s；本次用 `rsproxy.cn` 作 `RUSTUP_DIST_SERVER` + cargo sparse 镜像，编译 2m02s 完成。
5. **链路质量是本阶段最大的未解决风险**，已登记为架构 **R14**。可选方向：换大陆优化线路的 VPS / 让家用服务器经更稳的出口上网 / 接受低成功率并加大重试与超时。选哪个需用户拍板，不擅自改网络拓扑。

### 补充对照与定性更正（2026-11-12 17:43）

上一节把根因写成「家宽 → 港服的跨境链路随机丢包」，**这个定性不准确，现更正**。在同一台家用服务器上做跨目标对照（`openssl s_client` 5 次 / 目标、5s 预算，绕开代理）：

| 目标 | 解析 IP | 位置 | 握手成功 |
| --- | --- | --- | --- |
| `mirrors.ustc.edu.cn:443` | `203.0.113.20` | 境内 | 5/5 |
| `www.baidu.com:443` | `203.0.113.40` | 境内 | 5/5 |
| `static.crates.io:443` | `203.0.113.41` | 境外 Fastly | 5/5 |
| `www.cloudflare.com:443` | `203.0.113.42` | 境外 | 5/5 |
| `relay.example.com:8443` | `203.0.113.10` | 港服 VPS | 4/5 |

ICMP 到 `203.0.113.20` 与 `203.0.113.10` 均 **0% 丢包**（15 包）。随后对 VPS 做了「连续 10 次」与「每次间隔 2s」两组：**8/10 与 7/10**，无显著差异，排除「短时间突发新建连接被限速」。`mtr` 逐跳探测那次命令超时被中断，**没有拿到逐跳丢包数据**，此处不做推断。

因此：

- **不是家宽国际出口的问题，也不是「香港 VPS」这个地域的问题**；问题局限在**到 `203.0.113.10` 的这条特定路径**，且随时间大幅波动（同一方法先后得到 1/10、4/5、8/10、7/10）。
- 换大陆 VPS 理论上能消掉跨境段，但收益尚未被证明是必须的。**更划算的优先项是换一台回程优化（移动 CMI / CMIN2、电信 CN2 GIA、联通 9929）的港服**，保留免备案与大流量包；买前要测试 IP，在晚高峰 20:00–23:00 复测一晚。
- 大陆 VPS 的两个硬门槛（2026 年多家 IDC 资料）：① 未备案域名解析到大陆服务器，80/443 必被拦，检测已扩展到 8443 等常用 Web 端口并做周期性全端口扫描 —— **本项目正好用 8443**；备案约 5–15 工作日，且要求域名实名与主体一致。② 大陆轻量云多按固定带宽（常见 10–25 Mbps）+ 流量包计费，而 relay 是流量放大（上传 1 GB → 约 2 GB 出站），可能把「丢包」换成「限速」。
- 判据结论不变（六项全过），但架构 R14 的描述已相应更正。P3 前仍需补两项实测：**晚高峰长时间采样**、**把手机 5G USB 共享给家用服务器换出口复测**（若 5G 出口 10/10，即可确认是家宽到该 VPS 的路由问题，换线路优于换地域）。

### TCP 层证据（2026-11-12 17:58）：为什么「ping 顺」≠「握手顺」

用户在服务器上手工跑 `ping 203.0.113.10`，得到 `51.262ms / mdev 0.369ms`、21 发 19 收（**9.5% 丢包**），观感是「很顺利」。补做 TCP/TLS 层对照：

| 探测 | 结果 |
| --- | --- |
| ICMP 56B × 30 | **6.67% 丢包** |
| ICMP 1400B DF × 30 | **13.33% 丢包**（大包翻倍） |
| TLS 握手 → VPS 8443 × 12 | **7/12**；5 次失败全部 6003–6006ms 打满 6s 超时，7 次成功也要 1650–5511ms |
| TLS 握手 → `static.crates.io:443` × 12（对照） | **12/12**，稳定 1266–1874ms |
| `TcpRetransSegs` 增量 | **+1345**（本机还跑 Docker / syncthing 等，不能全归因于本次测试，但与握手被重传拖慢一致） |

`mtr -r -w -n -c 8 -T -P 8443 203.0.113.10` 逐跳（加 `-n` 避免反向 DNS 把命令挂住）：

| 跳 | 地址 | Loss% |
| --- | --- | --- |
| 1 | `192.168.1.1`（家里网关） | 0.0 |
| 3 | `198.51.100.41` | 62.5 |
| 5 | `198.51.100.42` | 75.0 |
| 6 | `198.51.100.43` / `.45` / `.9` | 25.0 |
| 8 | `198.51.100.44` | 75.0 |
| 9 | `198.51.100.45` | 37.5 |

`211.136.x` / `221.183.x` 属中国移动骨干，`223.120.x` 属中国移动国际出口（CMI）。**注意**：中间跳的 Loss% 受路由器对探测包限速影响，只能作定位线索，不是精确端到端丢包率；mtr 里 4092ms 之类的 RTT 也是限速造成的假时延（端到端 ping 只有 51ms）。

**两者为何不矛盾**：ping 是 56B 无状态小包，丢两个不影响观感，且 ICMP 常被单独限速；TLS 1.3 握手是有状态多往返，服务端证书链是大包，正好撞上 **13.33% 的大包丢包率**。丢一个包就触发 RTO（Linux 初始 1s、指数退避），几次重传即耗光 iroh 的 **10s 拨号预算**。所以「RTT 51ms、抖动 0.37ms 极稳」与「握手 6s 超时」可以同时成立 —— 极低 mdev 反而说明不是拥塞排队，而是策略性随机丢弃。

**路径结论与建议调整**：丢包集中在**移动骨干 → CMI 国际出口 → 港服**这段跨境路径；家宽整体没问题（到 Fastly / Cloudflare 12/12），VPS 机房本身也没问题（VPS 本机 6/6）。上一节建议的「优先换 CMI 优化港服」应下调 —— mtr 显示**当前已经在 CMI 路径上**，换同线路港服改善不确定（mtr 只测去程，回程未知）。**换大陆 VPS 是改善最确定的解法**（直接消掉 `223.120` 国际出口段），但需过备案 + 固定带宽两道门槛。零成本优先项仍是「把手机 5G USB 共享给家用服务器换出口复测」：此前 5G → 该 VPS 为 6/6。

### 本次验证在服务器上留下的产物（可完全回滚）

`/home/yuan/netdisk-p0-1/`（源码 + 编译产物）、`~/.cargo`、`~/.rustup`、`~/.cargo/config.toml`、`/tmp/p0-online.log`、`/tmp/rustup-init.sh`。若不再需要：

```bash
rm -rf ~/netdisk-p0-1 ~/.cargo ~/.rustup
rm -f /tmp/p0-online.log /tmp/rustup-init.sh
```

shell 配置文件（`.bashrc` / `.profile`）**未被修改**，VPS 的 `mangle` 表已恢复原状，没有留下防火墙规则。
