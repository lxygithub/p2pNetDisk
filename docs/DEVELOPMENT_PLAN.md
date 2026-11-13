# 个人网盘（基于 iroh）开发计划

> 版本：v0.5 · 日期：2026-11-12 · 状态：**D1、D3、D4 已确认（含 D4 仲裁细则）**，其余决策待评审
> 变更：v0.6 补齐 P0-pre 最后一项实机判据（家用服务器出站连通），并登记链路质量风险 R14 / 本机环境风险 R15；v0.5 锁定仲裁细则（到达顺序 / 直接丢弃不进回收站 / 组合场景默认）；v0.4 新增多端多写与冲突用例；v0.3 确认不做静态加密；v0.2 新增 P0-pre
> 配套文档：[`ARCHITECTURE.md`](./ARCHITECTURE.md)
> 本文中的阶段编号为依赖顺序，不是日程承诺；工作量按「一人投入」粗估。

## 0. 协作方式与总原则

按既有的协作习惯：**代码、脚本与配置由 AI 产出；编译、真机、真实网络验证由你执行并下结论**。每个阶段我都会附一份可复现的验证命令清单，不会用「应该能跑」代替实测结果。

六条总原则：

1. **PoC 先行**：P0 的三项验证全部通过才进入正式开发。任何一项不过，先改架构，不带着假设往前堆代码。
2. **锁版本、锁 Cargo.lock**：上游 `iroh-blobs` / `iroh-docs` 仍在 0.x，禁止随手 `cargo update`；客户端 / 服务端 / relay 三者版本一起验证。
3. **业务逻辑只写一份**：`netdisk-core` 是唯一真源，服务端与移动端都链接它；Dart 层不实现同步逻辑与冲突仲裁。
4. **D1 已确认**：公网组件为 VPS 自建 relay，部署规格见架构 §2.3。P0-pre 先把它立起来，之后所有网络验证都基于真实部署，不再用「假设有个 relay」。
5. **D3 已确认：不做静态加密**。blob、SQLite 索引、备份均为明文，防护改由专用户 / 目录权限 / systemd 沙箱 / 备份离线受控承担（架构 §5.4）。P3 必须落地并验证，P5 不再安排 LUKS 相关任务。
6. **D4 已确认：多端多写，仲裁细则已锁定**（架构 §5.5）：所有已配对设备默认可写；同内容幂等覆盖 / 同名不同内容自动重命名 / 并发修改同一条目按**服务端到达顺序（revision）**做 LWW；旧版**直接丢弃、不进回收站、不提供找回路径**；组合场景按 §5.5.5 默认表。客户端要有离线待提交队列与 `base_revision`，服务端是唯一仲裁者，**不用客户端时钟判新旧**。

---

## 1. 仓库结构（P1 建立）

```
netdisk/
├── Cargo.toml                  # workspace，统一 rust-version / lints
├── Cargo.lock                  # 入库，禁止漂移
├── crates/
│   ├── netdisk-core/           # 共享业务逻辑：lib + cdylib（含冲突仲裁）
│   ├── netdisk-ffi/            # 薄 C ABI、cbindgen 头文件、buffer 生命周期
│   └── netdiskd/               # 服务端 daemon（CLI + systemd）
├── flutter/                    # Flutter app
│   ├── lib/                    # UI / 域层 / dart:ffi 绑定（ffigen 生成）/ 离线写队列
│   ├── android/                # cargokit + cargo-ndk、JNI Context 初始化
│   └── ios/ macos/ ...         # P6 复用同一 cdylib
├── infra/                      # D1 已确认：VPS 侧基础设施
│   ├── relay.toml.example      # relay 配置模板（不含真实 token）
│   ├── docker-compose.yml      # 可选：relay 容器化
│   ├── systemd/iroh-relay.service   # VPS 侧 relay 服务
│   └── systemd/netdiskd.service     # 家用服务器侧 daemon（含权限与沙箱配置）
├── tools/
│   └── poc/                    # P0 三个独立可运行的最小示例
└── docs/
    ├── ARCHITECTURE.md
    ├── DEVELOPMENT_PLAN.md
    └── COMPAT_MATRIX.md        # 依赖版本兼容矩阵（P0 建立）
```

**约定**：relay token、域名、密钥一律不进仓库；`relay.toml.example` 只放占位符。按 D3 不做静态加密，因此仓库里不引入密钥包裹 / 磁盘加密相关模块；按 D4 不引入 CRDT / 向量时钟库，也不实现被覆盖版本的找回功能。

---

## 2. 阶段总览

| 阶段 | 主题 | 核心交付 | 出口判据（Go/No-Go） |
| --- | --- | --- | --- |
| **P0-pre** | VPS relay 就绪（D1 已确认） | 部署好的 relay + 域名 + TLS + 防火墙 + token 轮换流程 | 蜂窝网络能连上；错误 token 被拒；日志确认 TLS / QUIC 地址发现已生效 |
| **P0** | 可行性 PoC | 3 个独立最小示例 + 实测报告 | 三项全过，且 `cargo tree -d` 无重复 blobs |
| **P1** | Rust Core 骨架 | `netdisk-core` / `netdisk-ffi` 骨架、CI | FFI 契约测试全绿，Dart 能调用并收到事件 |
| **P2** | 数据层 + 冲突仲裁 | blobs 集成、SQLite schema、oplog、续传、GC、LWW / 自动重命名 | 断电/中断续传通过；并发写、同名撞名、时钟篡改用例全过 |
| **P3** | 服务端 | `netdiskd`、systemd、配对、鉴权、备份、metrics、**访问控制** | 无人值守跑 7 天，重启后状态自洽；非授权用户读不到 blob |
| **P4** | Android MVP | Flutter UI + 真机可用 | 真机完成「上传 / 下载 / 进度 / 断网续传 / 离线写提交」闭环 |
| **P5** | 加固与真实网络 | 双 relay、直连率监控、后台保活、备份演练、冲突组合场景 | 4G/Wi-Fi 切换、relay 宕机、飞行模式、删除 vs 修改用例通过 |
| **P6** | 多端扩展 | iOS / 桌面复用 cdylib | 同一 core 在第二个平台编译并跑通同步 |

粗估节奏（一人投入、非承诺）：P0-pre 约 1–3 天；P0 约 1–2 周；P1–P2 各约 2–3 周（P2 因冲突仲裁略增）；P3 约 2 周；P4 约 3–4 周；P5 约 2 周；P6 视平台而定。

---

## 3. P0-pre — VPS relay 就绪（P0-1 的前置，不写产品代码）

把公网组件先立起来，后续所有网络实测都基于真实部署。规格见架构 §2.3。

**检查项**

1. VPS 开通（1 vCPU / 1 GB 起，**优先看流量包与带宽**）+ 域名 A / AAAA 解析；
2. 编译服务端二进制：`cargo build --profile optimized-release --package iroh-relay --features server`；
3. 写 `/etc/iroh/relay.toml`：`cert_mode = "LetsEncrypt"` + `hostname` + `contact`、`enable_quic_addr_discovery = true`、`access.shared_token`、`[limits.client.rx]`、`metrics_bind_addr = "127.0.0.1:9090"`；
4. 防火墙只放行 TCP 80 / TCP 443 / UDP 7842；**9090 不对公网开放**；确认 TCP 443 允许 WebSocket Upgrade；
5. systemd 托管 + 证书自动续期；配置文件 `0600`；
6. 记录 token 轮换流程（改配置 → 重启 → 更新所有客户端），token 不进仓库。

**验收（你执行）**

```bash
# VPS：核对启动日志，确认绑定 [::]:443、TLS 生效、access 不是 everyone、QUIC 地址发现已开
iroh-relay --config-path /etc/iroh/relay.toml
ss -lntup | grep -E ':(80|443|7842|9090)'
# 公网侧：确认 9090 不可达；证书链由可信 CA 签发
# 客户端侧：正确 token 能连、错误 token 被拒
# 家用服务器侧：不做任何端口映射，出站仍能连到 relay
```

**出口判据**：蜂窝网络能连上 relay；错误 token 被明确拒绝；启动日志确认 TLS 与 QUIC 地址发现已启用；配置文件确实被加载。

> **特别注意**：`iroh-relay` 的 `Config::load()` 在配置路径不存在时会**静默回退默认配置**（plain HTTP :80、无 TLS、`everyone`）。所以「能连上」不等于「配置生效」，必须看日志。另外上游 `docker/README.md` 的 `--config` 与 CLI 的 `--config-path` 不一致，Dockerfile 暴露 `3478/udp` 而源码默认 QUIC 端口是 **7842**，以源码为准。

> **实机部署补充（2026-11-12）**：目标 VPS 的 80/443 被 nginx 占用（含现网业务 `luoke.oceo.top`），因此采用 `infra/README.md` §2.1 的共存方案：新增 nginx server 块提供 certbot webroot、certbot HTTP-01 签证书、relay 用 `cert_mode = Manual` 监听 `[::]:8443`，RelayUrl 带端口 `:8443`，QUIC 仍为 7842。根因是内置 ACME 走 TLS-ALPN-01 必须独占 443。验收命令与实测结果见 `infra/README.md` §8。

> **家用服务器侧补测（2026-11-12，最后一项判据已过）**：在 `yuan@100.64.0.10`（Ubuntu 24.04、零入站映射、Tailscale 免密登录）上编译并运行 P0-1 的真实 endpoint：`MODE=pair` 3 次中第 3 次 echo 往返 PASS、`MODE=online` 5 次中 2 次 OK。`infra/README.md` §8 六项出口判据现全部打勾。**但链路为「可用但需重试」**：该家宽到港服 VPS 的新 TLS 连接约 60–90% 随机丢包，VPS 本机 / 5G 侧均 6/6 已排除服务端故障。对应架构 **R14**（P3 前需选换线路 / 换出口 / 接受低成功率）与 **R15**（代理环境变量、14 个 UP 接口）。细节与复现步骤见 `tools/poc/p0-1/README.md`。
>
> **17:43 定性更正**：后续跨目标对照（境内与其他境外目标均 5/5、ICMP 0% 丢包）证明这不是家宽国际出口或香港地域问题，而是到该 VPS IP 的特定路径间歇性丢包（1/10 ~ 8/10 波动）。因此「换大陆 VPS」不是唯一解且代价更高（备案覆盖 8443、固定小带宽与 relay 流量放大冲突），优先项改为**换回程优化的港服**。P3 前另需补「晚高峰长时采样」与「手机 5G 出口对照」两项实测。

**产出**：`infra/relay.toml.example`、`infra/systemd/iroh-relay.service`、一份部署记录（VPS 规格、流量套餐、域名、证书、防火墙规则、token 轮换方式）。

---

## 4. P0 — 可行性 PoC（最高优先级，不做 UI）

目的不是写产品代码，而是用最小代价证伪三个最危险的假设。三个示例彼此独立，放在 `tools/poc/`，可单独运行。

### P0-1 真实网络连通性（基于已部署的 VPS relay）

- **假设**：家里 CGNAT 服务器 + 手机蜂窝网络，经自建 relay 能建立连接，且直连率达到可接受水平。
- **做法**：直接连 P0-pre 部署好的 relay；两端用 `iroh/examples/echo.rs` 改造，打印所选路径（direct / relay）与 RTT。客户端 `RelayMode::Custom` 只配自建 relay，便于单独观测。
- **实测项**：直连 / 中继各占比、首连耗时、稳态吞吐、网络切换（Wi-Fi ↔ 4G）后连接是否存续；错误 token 被拒；`[limits.client.rx]` 限速生效；`direct_ratio` 与 VPS 流量账单的对应关系。
- **判据**：至少在「家 Wi-Fi ↔ 蜂窝」组合下能连上；记录直连率作为流量包规格的定档依据。直连率过低不否掉方案，但必须触发流量预算上调与「是否需要第二台 VPS」的复评。
- **参考命令**：`iroh-doctor report`（确认防火墙 / WebSocket Upgrade / UDP 可达性）。
- **实机结论（2026-11-12）**：带 `:8443` 的 RelayUrl、`shared_token`、relay 转发 echo 已在本机 Windows（家宽 / 5G）与家用 Linux 服务器上分别验证，`infra/README.md` §8 六项判据全过。但家用服务器侧是「可用但需重试」，**不等于稳定可用**，见架构 R14。
- **交给 P3 的硬约束**：`netdiskd.service` 要显式 unset `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` 并设 `NO_PROXY=*`；不要用 `Endpoint::online()` 当启动门槛，改依赖 home relay watcher 与 iroh 自身重连；评估 14 个 UP 接口对直连地址枚举的影响；服务器侧 Rust 构建需配 crates / rustup 镜像（官方源仅 40–60 KB/s）。

### P0-2 Android FFI 打通

- **假设**：自建 Rust `cdylib` 能在 Android 真机上成功 `Endpoint::bind()` 并收发一条消息。
- **做法**：最小 `cdylib` 暴露 `nd_echo()`；用 cargokit + cargo-ndk 编进 `jniLibs`；Flutter 侧 `dart:ffi` 调用。**必须复现 JNI JavaVM + Context 注入与 `rustls-platform-verifier` 初始化**——`iroh_flutter` 1.0.2 的 changelog 正是修「release build 未初始化 context 导致首次 bind 崩溃」。
- **判据**：**release 包**（不是 debug）在 arm64 真机上跑通；minSdk 24；NDK r28+ 16 KB 页对齐不报错；能连到 P0-pre 的 relay。
- **降级路径**：若自建构建管线卡住，先用 `iroh_flutter ^1.3.0` 跑通连通性，确认 iroh 在 Android 上没问题，再回头攻构建脚本，把「FFI 工程问题」与「iroh 平台问题」分开。

### P0-3 blobs 传输与版本锁定

- **假设**：`iroh-blobs` 能完成 100 MB 级文件的上传、中断续传与哈希校验，且与所选 `iroh` 版本无冲突。
- **做法**：两个本地 endpoint（或本地 + 服务端），跑 `fs-store` 上传 / 下载 / 中途 kill 后续传。
- **判据**：续传后 BLAKE3 校验一致；`cargo tree -d` 无 `iroh-blobs` 双版本；`Cargo.lock` 固定。
- **同步产出**：`docs/COMPAT_MATRIX.md`，写明 `iroh` / `iroh-blobs` / `iroh-base` / `noq` 的锁定版本与升级规则，以及客户端 / 服务端 / relay 的版本对应关系。

### P0 交付物

`tools/poc/` 三个可重复运行的示例 + 一份实测报告（数值、机型、网络环境、VPS 流量读数、失败用例）+ `COMPAT_MATRIX.md` + relay 部署记录 + Go/No-Go 结论。

> **No-Go 处理**：P0-1 失败 → 排查 NAT / 防火墙 / 证书 / WebSocket Upgrade，或按实测直连率上调流量预算（D1 已确认，不再重新选型）；P0-2 失败 → 走降级路径或改用官方 uniffi → Kotlin → Flutter Plugin；P0-3 失败 → 自研分块传输（工作量显著上升，需重新排期）。

---

## 5. P1 — Rust Core 骨架

**目标**：把 FFI 契约定死，让服务端和移动端共用一套逻辑。

| 交付物 | 说明 |
| --- | --- |
| `netdisk-core` | `NetdiskApi` 门面、内部 tokio runtime、错误模型、配置结构（relay URL / token 由配置传入） |
| `netdisk-ffi` | C ABI（init / pair / start / list / upload / download / cancel / poll_event / free）、cbindgen 头文件、`nd_free()` 所有权约定 |
| 事件模型 | 进度、完成、失败、连接状态变更、**覆盖/重命名提示**（不提供撤销入口）；同步函数只返回 `op_id`，不跨 FFI 传 Future |
| RelayMap 构建 | 自建 relay 带 token、n0 兜底条目不带 token（架构 §2.3 的坑） |
| **写权限与冲突入口（D4）** | 所有已配对端默认可写（`devices.can_write` 预留只读端）；写请求携带 `base_revision` 与请求 id，服务端按到达顺序定序、做 LWW 与幂等去重 |
| 离线写队列 | 客户端本地持久化待提交写操作，联网后按序提交；不参与仲裁，只保证不丢请求 |
| 契约测试 | Rust 侧测 C ABI；Dart 侧最小调用回显 |
| CI | `cargo fmt/clippy/test`、`cargo tree -d` 检查、Flutter analyze |

**关键约束**：大文件传 `content://` URI / 路径，不传字节 buffer；所有跨边界 payload 用长度前缀 + 显式释放。按 D3 不引入加密模块，按 D4 不引入 CRDT / 向量时钟，也不实现旧版找回。

**验收（你执行）**：

```bash
cargo test --workspace
cargo clippy --workspace -- -D warnings
cargo tree -d | grep iroh-blobs      # 期望：无输出
cd flutter && flutter analyze && flutter build apk --release
```

**风险回退**：若 Dart↔Rust 事件流复杂度超预期，先退化成「Dart 轮询 `nd_poll_event`」，P4 再换 Stream。

---

## 6. P2 — 数据层 + 冲突仲裁

**目标**：内容寻址 + 元数据 + 增量同步 + 冲突仲裁，全部在 `netdisk-core` 内完成，不依赖 UI。仲裁细则已锁定（架构 §5.5），本节按定稿实现，不再留可选项。

| 交付物 | 说明 |
| --- | --- |
| blobs 集成 | `fs-store`、BLAKE3 校验、范围请求、断点续传 |
| SQLite schema | `entries`（含 `id` / `base_revision`）/ `oplog`（含 `discarded`）/ `devices`（含 `can_write`），见架构 §5.2 |
| 增量同步协议 | 自定义 ALPN `netdisk/sync/1`；`since_revision` 拉增量 + 待提交写操作批量上报 |
| **冲突仲裁（D4，细则已确认）** | 判定顺序见 §5.5.1；LWW 用**服务端到达顺序**；同内容幂等覆盖；同名不同内容自动重命名 `原名 (2).ext`；写 `conflict_rename` / `discarded` oplog |
| **直接丢弃** | 被覆盖的旧版不生成冲突副本、**不进回收站**、不保留内容、不提供找回路径；blob 由 GC 回收，oplog 只留元数据审计记录 |
| 回收站与 GC | 仅用于「用户主动删除」路径：墓碑 + 30 天保留 + 基于元数据引用集合的 GC |
| 去重 | 按 blob_hash 复用，验证同内容不重复落盘（D3 不做加密，去重完整保留） |

**验收用例**（建议做成 Rust 集成测试，可重复跑；两个 endpoint 模拟两端并发）：

1. 100 MB 文件传至 50% 时 kill 进程，重启后续传，哈希一致；
2. 同内容不同路径上传，磁盘只增一份 blob；
3. 用户主动删除 → 回收站内可恢复 → 过期后 GC 回收；
4. 服务端 revision 单调递增，客户端从任意 `since_revision` 重放结果一致；
5. 未配对设备发起写被拒绝；两个已配对设备可同时写；
6. **两端并发修改同一条目** → 后到服务端者生效，旧版直接丢弃：回收站查不到、无冲突副本、无找回入口；oplog 可查 `discarded` 记录（`device_id`、旧 hash），客户端收到覆盖提示；
7. **两端新建同名同内容** → 幂等，只一个条目、一份 blob；
8. **两端新建同名不同内容** → 后来者自动重命名为 `原名 (2).ext`，两份都在；重放同一请求不产生第三份；
9. **客户端时钟被故意调快 / 调慢** → 仲裁结果仍由服务端到达顺序决定，不受影响；
10. **离线较晚同步**：A 离线先改、B 在线后改并同步、A 最后上线 → A 的旧修改覆盖 B（LWW 固有语义，用例只验证行为符合预期，不做回滚）；
11. 删除 vs 并发修改、重命名 vs 修改、目录移动、同名目录等组合场景，结果与已确认的架构 §5.5.5 默认表一致；
12. 磁盘写满 / 目录权限错误时返回明确错误而非 panic。

**风险回退**：若 `iroh-blobs` 的 GC / 持久化行为不符预期，元数据层自己接管引用管理（架构已按此设计，不依赖上游 GC）。

---

## 7. P3 — 服务端 netdiskd

**目标**：家用 Linux 上无人值守运行，不需要任何入站端口；**按 D3 用访问控制替代静态加密**。

| 交付物 | 说明 |
| --- | --- |
| `netdiskd` | 链接 `netdisk-core`；CLI：`init` / `pair` / `serve` / `gc` / `backup` |
| 配置 | `/etc/netdisk/config.toml`：relay 列表、token、存储路径、限速、保留期；文件 `0600` |
| systemd unit | 崩溃重启、日志、专用户、`ProtectSystem`、`ReadWritePaths`、`NoNewPrivileges` |
| **访问控制（D3 的主要防护）** | 专用系统用户、数据目录 `0700` / 文件 `0600`、备份目录权限受控、离线保存 |
| 配对 | 生成二维码 / ticket（EndpointId + relay URL + 一次性配对码），短 TTL |
| 应用层鉴权 | challenge-response + `devices` 白名单 + 撤销；**所有已配对端默认可写（D4）** |
| 仲裁与观测 | 服务端统一按到达顺序分配 revision；暴露冲突计数、丢弃计数、`oplog_revision` |
| relay 部署产物 | P0-pre 已落地，此处收进 `infra/` 并补齐文档与轮换脚本 |
| 备份 | **明文备份**脚本 + 恢复演练文档 |

**验收（你执行）**：

```bash
# 服务端
sudo systemctl start netdiskd && journalctl -u netdiskd -f
# 访问控制（D3）：确认普通用户读不到数据目录
sudo -u nobody ls /var/lib/netdisk/        # 期望：Permission denied
stat -c '%a %U %G %n' /var/lib/netdisk /var/lib/netdisk/blobs /etc/netdisk/config.toml
systemd-analyze security netdiskd
# 确认无入站依赖：路由器不做任何端口映射，仍可从蜂窝网络连通
# relay 侧：核对启动日志中的绑定地址与 TLS（配置路径写错会静默回退默认！）
iroh-relay --config-path /etc/iroh/relay.toml
# 无人值守：连续运行 7 天 + 一次强制断电重启 + 一次 relay 重启
```

**特别注意**：

- `iroh-relay` 的 `Config::load()` 在配置文件不存在时会**静默回退默认配置**（plain HTTP、无 TLS、`access = "everyone"`）。部署后务必核对日志，别只看「进程起来了」。
- 按 D3 数据是明文落盘的，所以「权限检查」不是可选项，是这一阶段的主要安全交付物；备份介质也要按同样标准检查。

---

## 8. P4 — Flutter Android MVP

**目标**：真机上跑通「看得见的文件管理」闭环。

| 交付物 | 说明 |
| --- | --- |
| Dart FFI 绑定 | ffigen 生成 + 类型安全封装 + 事件 Stream |
| UI | 文件列表 / 目录导航、上传、下载、进度、搜索、传输队列、设置 |
| 本地缓存 | 轻量 SQLite / Isar 存目录视图、`since_revision` 与**离线待提交写队列** |
| 冲突呈现 | 自动重命名文件的展示、被覆盖提示（仅提示，**不提供撤销 / 找回入口**）、冲突副本批量清理入口 |
| 后台 | 前台服务承载长连接与同步；WorkManager 补偿同步 |
| 首次配对 | 扫码 / 输入 ticket，持久化 EndpointAddr 与 relay token |
| 权限与兼容 | SAF / `content://`、通知权限（13+）、minSdk 24、arm64 |

**验收（你执行，真机）**：

1. 从蜂窝网络上传 100 MB 文件，进度连续、完成后服务端列表可见；
2. 上传中途切飞行模式 30 秒再恢复，自动续传且哈希一致；
3. 应用退到后台 30 分钟，仍能完成排队任务（或明确记录被杀后的补偿行为）；
4. Wi-Fi ↔ 4G 切换，连接不中断（QUIC 连接迁移）；
5. 在家同一 Wi-Fi 下确认走 mDNS 直连、不消耗 relay 流量；
6. **离线写提交**：飞行模式下改文件 → 恢复联网后提交，覆盖/重命名结果符合 §5.5；
7. **release 包**验证（JNI Context 初始化问题只在 release 暴露过）。

```bash
cd flutter && flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb logcat | grep -i netdisk
```

---

## 9. P5 — 加固与真实网络

| 主题 | 内容 |
| --- | --- |
| 双 relay | `RelayMap` = 自建（带 token）+ n0 公共（不带 token）；验证 token 隔离，以及自建 relay 宕机时新连接仍可建立 |
| 流量与直连率 | 上报 `direct_ratio`，对照 VPS 流量账单调整套餐与大文件策略；复评是否需要第二台 VPS |
| 后台保活 | Doze / 厂商省电白名单引导；任务幂等与重复提交防护 |
| **冲突组合场景（D4）** | 按已确认的架构 §5.5.5 验证删除 vs 修改、重命名 vs 修改、目录移动、同名目录；复核覆盖提示与 `discarded` 审计记录；确认**回收站里不会出现被覆盖的旧版**；观察冲突/丢弃计数是否异常 |
| **备份与访问控制** | **恢复演练（不做静态加密，D3 已确认）**；复核目录权限、systemd 沙箱、备份介质权限；若将来改主意要加 LUKS，作为独立变更重新排期 |
| 容量 | 磁盘水位告警、GC 压力测试、10 万文件下的目录查询性能、重命名副本泛滥告警 |
| 故障注入 | relay 断电、服务端断电、磁盘满、DNS 异常、飞行模式、证书过期、时钟被篡改 |

**出口**：上述用例形成一份可重复执行的检查表，且连续 7 天无人值守无数据不一致。

---

## 10. P6 — 多端扩展

- iOS / macOS：复用同一 `cdylib`，处理 App Sandbox 网络 entitlements 与 `NSLocalNetworkUsageDescription`；参照 `iroh_flutter` 的 xcframework 做法。
- Linux / Windows 桌面：cargokit 编 cdylib 随应用分发。
- **D4 已允许多写，新端默认即可读写，无需额外冲突层**；若要配置只读端，用 `devices.can_write = false`。
- 统一 Dart API，平台差异收敛在构建层。
- 重新评估 `iroh-docs`：若届时已到 1.0 且与 blobs 版本对齐，再判断是否替换自建元数据层；**不为了用而用**。当前 LWW 仲裁已满足需求，替换动机不强。

---

## 11. 测试策略分层

| 层 | 工具 / 方式 | 覆盖 |
| --- | --- | --- |
| 单元 | `cargo test`（core）、`flutter test`（Dart 域层） | 元数据、oplog、GC 引用计算、状态机 |
| FFI 契约 | Rust 侧 C ABI 测试 + Dart 侧回显 | buffer 所有权、错误码、事件顺序、`base_revision` 透传 |
| **冲突仲裁** | P2 双 endpoint 并发用例（含故障注入） | 到达顺序 LWW、直接丢弃不进回收站、同内容幂等、同名自动重命名、命名幂等、时钟篡改、离线较晚同步、删除 vs 修改 |
| 集成 | 本地起 relay（`test-utils` / `--dev`）+ 双 endpoint | 同步协议、续传、去重 |
| 基础设施 | P0-pre 验收脚本 | token 鉴权、TLS、端口暴露面、限速、metrics 隔离 |
| 访问控制 | P3 / P5 检查脚本 | 目录 / 文件权限、非授权用户读不到 blob、systemd 沙箱、备份落地权限 |
| 真实网络 | P0-1 的脚本，CGNAT / 蜂窝 / 外部 Wi-Fi | 直连率、吞吐、连接迁移、流量账单 |
| 真机 | arm64 Android，debug + release | 后台、权限、JNI 初始化、离线写提交、包体 |
| 故障注入 | P5 检查表 | 宕机、断网、断电、磁盘满 |
| 恢复演练 | 备份 → 全新环境还原 | 「备份可用」而非「备份存在」 |

---

## 12. 里程碑依赖与关键路径

```
P0-pre(VPS relay 就绪) ──→ P0(连通性 / FFI / blobs)
                              ├─→ P1(core + FFI 骨架) ─→ P2(数据层 + 冲突仲裁) ─┬─→ P3(服务端 + 访问控制) ─→ P4(Android MVP) ─→ P5(加固) ─→ P6(多端)
                              └─→ infra 配置收编 ──────────────────────────────┘
```

关键路径在 **P0-2（Android FFI）** 与 **P2（数据层 + 冲突仲裁）**：前者决定移动端方案是否成立，后者决定后续所有功能的数据契约。D4 让 P2 的工作量与风险上升（并发正确性、幂等、命名规则），因此 P2 的并发用例必须先于 P3 落地，不能后补。P0-pre 是所有网络验证的前置，但不阻塞 P0-2 / P0-3 的本地开发。

---

## 13. 每个阶段结束时的检查点

按分阶段推进的习惯，每个阶段结束时提交：

1. 本阶段改动清单与文件列表；
2. 可复现的验证命令清单（由你执行，结果由你判定）；
3. 实测数据与失败用例，不隐去；
4. `COMPAT_MATRIX.md` 的版本状态；
5. VPS 流量读数与 `direct_ratio`（P0-pre 起）、访问控制检查结果（P3 起）、冲突/丢弃计数（P2 起）；
6. 下一阶段的 Go/No-Go 建议与遗留风险。

未经检查点确认，不进入下一阶段，也不顺手做「顺便改一下」的跨阶段变更。
