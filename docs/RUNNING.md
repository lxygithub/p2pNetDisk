# 最小可运行闭环（v0.1）

> 这一版的目标是**先让前后端真的跑起来**，不是完整 MVP。它验证的是「服务端在家用 Linux 服务器 / 客户端在任意网络 / 经 relay 完成文件往返」这条主链路，并把协议契约固化在 `netdisk-core` 里，供后续 Flutter FFI 复用。
>
> **默认走 n0 官方公共 relay**（`NETDISK_RELAY_URL=n0`）。2026-11-13 实测：家宽 → 自建港服 `:8443` 的 TLS 握手只有 2/8（失败全是 6s 超时），而 n0 的 `aps1-1`（亚太）为 **8/8**；切到 n0 后 `list` 一次成功、约 2s。自建 relay 仍保留，改环境变量即可切回。

## 现在的组成

| 组件 | 位置 | 作用 |
| --- | --- | --- |
| `netdisk-core` | `netdisk-core/` | iroh endpoint 构建、ALPN `netdisk/0` 帧协议、BLAKE3 流式传输、路径防护 |
| `netdiskd` | `netdiskd/` | 服务端 daemon：接受连接，提供 `ping / list / put / get` |
| `netdisk-cli` | `netdisk-cli/` | 最小客户端：验证闭环，与 Flutter 共用 core |
| relay | n0 官方 `aps1-1.relay.n0.iroh.link` 等四节点 | 公网引荐与兜底转发；可切回自建 `relay.example.com:8443` |

协议是「u32 长度前缀 + JSON 帧」，文件数据按声明的 `size` 精确裸传（不依赖 EOF，因为同一条流后面还要读响应帧）。每条命令开一条 QUIC 双向流。

## 环境变量

| 变量 | 用在 | 说明 |
| --- | --- | --- |
| `NETDISK_RELAY_URL` | 两端 | 默认 **`n0`**（n0 官方公共 relay）。填 `https://<host>:8443` 则走自建 |
| `NETDISK_RELAY_NODE` | 两端 | `n0` 模式下钉住的 relay 节点，默认 `aps1-1`（亚太）。写 `auto` 恢复自动择优，也可写 `aps1-1,euc1-1` 给多个候选 |
| `NETDISK_RELAY_TOKEN` | 两端 | **仅自建 relay 必填**；`n0` 模式下忽略（公共 relay 免费有速率限制） |
| `NETDISK_DATA_DIR` | 服务端 | 默认 `./data` |
| `NETDISK_SERVER_ADDR` | 客户端 | 服务端启动时打印的 `EndpointAddr` JSON。**n0 模式只需 `{"id":"<EndpointId>","addrs":[]}`**，地址由 `dns.iroh.link` 解析 |

### 两种 relay 模式的差异

| | n0 官方（默认） | 自建 |
| --- | --- | --- |
| `NETDISK_RELAY_URL` | `n0` | `https://relay.example.com:8443` |
| token | 不需要 | 必填 |
| 地址发现 | `dns.iroh.link` 自动发布/解析，客户端只填 EndpointId | 需带上含 relay 的完整 `EndpointAddr` |
| 实测握手 | **8/8**（aps1-1） | 2/8（家宽 → 港服） |
| 适用 | 先用起来 | 要自主可控 / 隐私边界 |

`n0` 模式下 `netdiskd` 启动后会异步打印第二行 `NETDISK_SERVER_ADDR_LATE=`，那是 `net_report` 选好 home relay（实测自动选中 `aps1-1`）之后的完整地址，含公网映射；客户端用第一行就够。

### relay 节点固定与 endpoint 自愈

`n0` 模式仍用 `presets::N0`（保留 `dns.iroh.link` 地址发布/解析），但 relay 不再
交给 `net_report` 自动择优 —— 实测它经常落到 `usw1-1`（RTT 441–659ms、握手
1.76–4.32s），而 `aps1-1` 只要 1.29–1.43s，首连和 ping 很容易超时。现在默认
钉在 `aps1-1`；给多个候选时 iroh 反而选了欧洲，所以默认只给一个。

**endpoint 自愈**：家宽在运营商 CGNAT 后面，UDP 映射会被静默清理，iroh 的
relay 长连接撑不住 —— 实测 20 小时无客户端访问后注册失效，客户端完全连不上，
只能重启进程。`netdiskd` 现在用 `watch_endpoint` 监控：

- 每 5 分钟检查 `ep.addr()` 里是否还有 relay 地址；
- 连续 3 次（15 分钟）缺失 → 重建；
- 连续运行满 **4 小时**无条件重建（`addr()` 可能保留缓存的 home relay，
  检测不一定准，周期是保底）。

重建 = 关掉旧 endpoint → 用同一个 secret 建新的（**EndpointId 不变**）→ 重新
挂 `Router`。进程和管理后台都不重启，传输会断几秒、客户端自动重连。
重建后会重新打印 `NETDISK_SERVER_ADDR`，地址里的 IP 可能变化，但客户端靠
`dns.iroh.link` 解析 EndpointId，不用改配置。


## 跑起来

**1) 取 token（本机 Bash，命令里不出现明文）**

```bash
TOKEN="$(ssh -p 2222 root@203.0.113.10 \
  "awk -F '\"' '/^access.shared_token/ {print \$2}' /etc/iroh/relay.toml")"
TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r\n')"   # Windows SSH 会带 CRLF，必须清洗
```

**2) 起服务端**（先在本机验证，再部署到家用服务器）

```bash
export NETDISK_RELAY_TOKEN="$TOKEN"
export NETDISK_DATA_DIR=./data
cargo run -p netdiskd
```

启动后会打印一行：

```
NETDISK_SERVER_ADDR={"id":"...","addrs":[...]}
```

**把这一整行 JSON 复制给客户端**。它必须包含 home relay URL —— P0-1 已实证：`presets::Empty` 下只有 EndpointId 会报 `No addressing information available`。

**3) 客户端**（可在本机、也可在另一个网络的机器上）

```bash
export NETDISK_RELAY_TOKEN="$TOKEN"
export NETDISK_SERVER_ADDR='<上一步的 JSON>'
cargo run -p netdisk-cli -- ping
cargo run -p netdisk-cli -- list
cargo run -p netdisk-cli -- put ./photo.jpg photos/photo.jpg
cargo run -p netdisk-cli -- get photos/photo.jpg ./downloaded.jpg
```

`put` 会打印本地与服务端各自的 BLAKE3；两者不一致会直接报错。`get` 打印下载哈希，可与本地文件核对。

**4) 部署到家用服务器**（`ssh yuan@100.64.0.10`，免密）

服务器已装 `rustc 1.99.1` 并配好 rsproxy 镜像。同步源码后：

```bash
cd /mnt/datadisk/netdisk/code
CARGO_TARGET_DIR=/mnt/datadisk/netdisk/build/target cargo build -p netdiskd
NETDISK_RELAY_URL=n0 \
  NETDISK_DATA_DIR=/mnt/datadisk/netdisk/data \
  NETDISK_SECRET_FILE=/mnt/datadisk/netdisk/secret/secret.key \
  /mnt/datadisk/netdisk/build/target/debug/netdiskd
```

> **注意 R14**：家宽 → 港服这条链路会间歇丢包，`netdisk-cli` 已内置 3 次 connect 重试；服务端启动后不要依赖 `Endpoint::online()` 作为就绪信号。长时间运行建议配合 `systemd` 的 `Restart=always`（`netdiskd.service` 属 P3 产物，尚未交付）。

## 已知限制（刻意留给后续阶段）

- ~~密钥临时~~ **已解决**：`netdisk-core::load_or_create_secret` 落盘 32 字节 Ed25519 种子（0600），`netdiskd` 用 `build_endpoint_with_secret` 注入；重启后 `EndpointId` 不变。
- **没有元数据层**：`list` 靠递归扫目录，无 SQLite / oplog / revision，因此也没有 D4 的同名自动重命名与 LWW 仲裁。
- ~~没有断点续传~~ **已解决**：`Put` 一次往返协商 `offset` + `.part` 续传（`FLUTTER_CLIENT.md` §4.12）。单文件上限从 512 MB 提到 16 GiB 异常值防线，实际由服务端按磁盘可用空间判断（§4.16）。
- **没有静态加密**（D3 已确认不做），服务端目录明文落盘。
- **并发写不安全**：同路径并发 `put` 会争用同一个 `.netdisk-tmp` 临时文件，MVP 单用户串行使用。
- **路径防护**已拒绝绝对路径与 `..`，但尚未防符号链接逃逸；存储目录不要放软链。
- ~~Flutter 前端尚未接入~~ **已解决**：Android 客户端已通过 `dart:ffi` 接入并真机验证上传/下载/预览；`netdisk-cli` 现在主要用作端到端回归与旧协议模拟。

## 下一步路线

1. 用 `netdisk-cli` 在**本机 ↔ 家用服务器**之间跑通 `ping/list/put/get`（当前阶段验收）；
2. 给 `netdisk-core` 加 `cdylib` 导出 + `dart:ffi` 绑定，搭 Flutter 骨架（P0-2 风险需单独验证 Android JNI Context）；
3. 持久化密钥 + SQLite/oplog + D4 冲突仲裁（P1 / P2）；
4. `iroh-blobs` 断点续传、GC（P0-3 / P2）；
5. `netdiskd.service`、访问控制与备份（P3）。

## 常驻部署（2026-11-13 迁移到数据盘）

**服务端所有落盘数据都在数据盘 `/mnt/datadisk`（sdb，916G），系统盘只保留 unit 与 env 两个小配置文件。**

| 项 | 实际值 |
| --- | --- |
| unit | `/etc/systemd/system/netdiskd.service`，`enabled` + `active` |
| env | `/etc/netdisk/netdiskd.env`（`0600`，属主 `yuan`，不含明文 token） |
| 根目录 | `/mnt/datadisk/netdisk/` |
| 用户文件 | `/mnt/datadisk/netdisk/data`（`0700`，属主 `yuan`） |
| 设备身份 | `/mnt/datadisk/netdisk/secret/secret.key`（`0600`） |
| 源码 | `/mnt/datadisk/netdisk/code` |
| 编译产物 | `/mnt/datadisk/netdisk/build/target`（约 4.6G） |
| 应用日志 | `/mnt/datadisk/netdisk/logs/netdiskd.log`（logrotate 每日轮转，保留 7 份） |
| 可执行文件 | `/mnt/datadisk/netdisk/bin/netdiskd` → 软链到 `build/target/debug/netdiskd` |
| 固定 EndpointId | 由 `secret.key` 决定，服务启动时打印（重启不变）；不要写进公开仓库 |

unit 关键设计：

- `RequiresMountsFor=/mnt/datadisk/netdisk` —— **等数据盘挂载完成再启动**。少了这一条，盘没挂上时 systemd 会在系统盘创建同名空目录并往里写，看起来一切正常，实际数据全落在系统盘。
- `StandardOutput=append:` / `StandardError=append:` 直接写数据盘日志文件，**不经过 journald**（journal 里只剩 Started/Stopped 这类生命周期记录）。
- `UnsetEnvironment=` 清掉 `.bashrc` 的代理变量并设 `NO_PROXY=*`（R15）。
- `Restart=always`（链路波动时自动拉起）。
- `ProtectSystem=strict` + `ProtectHome=true`，只放行 data / secret / logs 三个可写目录。

**在数据盘上编译**（系统盘已无源码与产物）：

```bash
cd /mnt/datadisk/netdisk/code
CARGO_TARGET_DIR=/mnt/datadisk/netdisk/build/target cargo build -p netdiskd
sudo systemctl restart netdiskd
```

**同步源码到服务器**时目标目录也变了：

```bash
tar -czf - netdisk-core netdiskd netdisk-cli netdisk-ffi \
  | ssh yuan@<host> 'tar -xzf - -C /mnt/datadisk/netdisk/code'
```

运维：

```bash
systemctl status netdiskd
sudo systemctl restart netdiskd
journalctl -u netdiskd -f          # 启动时会打印 NETDISK_SERVER_ADDR
```

> **身份文件等同于设备本身**：删掉 `secret.key` 会生成新的 `EndpointId`，所有客户端必须重新配对。备份时要把它和数据一起备份，且保持 `0600`。

### 安全修复：内部状态文件不得暴露给网盘协议

首版把 `secret.key` 放在数据目录里，实测 `list` 会把它列出来、客户端甚至能 `get` 下载设备私钥。已做两层修复：

1. 密钥移到独立目录（当前 `/mnt/datadisk/netdisk/secret/`），与用户文件物理隔离；
2. `netdisk-core` 的 `safe_path` / `list_entries` 拒绝任何隐藏文件、`secret.key`、上传中的 `.netdisk-tmp` 文件——即使将来误放内部结构文件也不会被同步出去。

实测：`list` 只返回用户文件；`get secret.key` 返回 `internal or hidden file not accessible`；put/get 不受影响。

## 实测结果（2026-11-12，全部 PASS）

| 场景 | 结果 |
| --- | --- |
| 本机 Windows 编译 workspace | `netdisk-core` / `netdiskd` / `netdisk-cli` 全过，iroh 1.4.1，3m07s |
| 家用服务器编译 workspace | 1m31s（复用既有 target 缓存 + rsproxy 镜像） |
| 本机双端闭环 | `ping → pong`；`list` 空 → `put` 1 MB → `list` → `get`；BLAKE3 / sha256 / `cmp` 全一致 |
| **跨机**（服务端在家用服务器、客户端在本机） | 同上，1 MB 往返 hash 一致 |
| **强制仅经 VPS relay** | 把 `EndpointAddr` 精简为只含 `Relay` 项后重跑，仍全部 PASS |
| **systemd 常驻服务** | `enabled` + `active`；重启后 EndpointId 不变；relay-only 闭环 PASS；日志出现 `connect attempt 1/3 failed → connected on attempt 2`，实证 R14 重试的必要性 |
| **密钥不暴露** | `list` 不再出现 `secret.key`，`get secret.key` 被拒，put/get 仍正常 |

佐证：VPS `journalctl -u iroh-relay` 出现 `connection_id 60–69` 的连接记录；家用服务器 `netdiskd` 打印两轮 `stored` / `sent`，BLAKE3 均为 `7ace1033583e464e3e844fe2d3e27a2ff76ebfff541dd08162b586b463bf3b96`。relay 日志里一条 `Failed to send packet: deadline has elapsed` 是 R14 丢包的体现，重试后成功。

顺带实证两个已登记风险：

- **R15**：家用服务器的 `ep.addr()` 一次列出 **13 个候选地址**（Tailscale、ZeroTier、optun、5 个 Docker 网桥、2 个公网 IPv6…），本机 Windows 也带 4 个虚拟网卡 IP。P3 需要评估地址候选过滤，避免打洞路径误选。
- **R14**：`netdisk-cli` 的 3 次 connect 重试在这条链路上确实有必要，但本次跨机验证未触发重试即连通。

---

Flutter 客户端（项目骨架、`dart:ffi` 绑定、最小 UI、冒烟测试与平台落地清单）见 `docs/FLUTTER_CLIENT.md`。

相关背景见 `docs/ARCHITECTURE.md`、`docs/DEVELOPMENT_PLAN.md`，relay 部署见 `infra/README.md`。
