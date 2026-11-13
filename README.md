# netdisk

基于 [iroh](https://github.com/n0-computer/iroh) 的个人网盘：服务端跑在家用 Linux（**无公网 IP**），客户端用 Flutter，数据面靠 NAT 打洞 / IPv6 直连，relay 只承担引荐。

## 它解决什么

家里没有公网 IP，手机和电脑仍要能互传文件。iroh 用公钥（`EndpointId`）而非 IP 寻址，自己负责找到对方、打洞、打不通时用 relay 兜底，最后给一条加密的 QUIC 连接。

实测结论（详见 `docs/ARCHITECTURE.md`）：

| 客户端环境 | 实际路径 | RTT |
| --- | --- | --- |
| Android（IPv6 可用） | 公网 IPv6 直连 | 32 ms |
| 桌面（无 VPN） | 公网 IPv4 打洞 | 7 ms |
| 打洞失败时 | relay 兜底 | 800–1300 ms |

relay 默认用 n0 官方公共节点（握手 8/8），自建 relay 保留为可选。

## 目录

| 路径 | 说明 |
| --- | --- |
| `netdisk-core/` | 协议与连接层：iroh endpoint、ALPN `netdisk/0` 帧协议、BLAKE3 校验、路径防护 |
| `netdiskd/` | 服务端 daemon：`ping / list / put / get / delete / rename / copy / mkdir`，原子落盘 |
| `netdisk-cli/` | 命令行客户端，用于端到端验证与路径诊断 |
| `netdisk-ffi/` | C ABI 动态库（供 Flutter 调用），复用长连接 |
| `app/` | Flutter 客户端：`dart:ffi` + 常驻 worker isolate |
| `infra/` | relay 部署脚本、systemd unit、环境变量模板 |
| `docs/` | 架构、开发计划、运行手册、客户端说明 |
| `tools/` | 交叉编译脚本与 P0 可行性验证程序 |

## 快速开始

**服务端**（家用 Linux）：

```bash
cd netdiskd && cargo build --release
NETDISK_RELAY_URL=n0 NETDISK_DATA_DIR=./data ./target/release/netdiskd
```

启动后会打印 `NETDISK_SERVER_ADDR=...`，n0 模式下客户端只需要其中的 `EndpointId`。

**客户端**：

```bash
cd app
flutter pub get
flutter run \
  --dart-define=NETDISK_DEFAULT_ADDR='{"id":"<你的 EndpointId>","addrs":[]}'
```

Relay 填 `n0`、Token 留空；也可以不注入，直接在设置页手填地址（当前版本参数不持久化，重启需重填）。点「连接」→「刷新列表」。

更完整的部署（systemd 常驻、数据盘、日志轮转）见 `docs/RUNNING.md`；Android 交叉编译与打包见 `docs/FLUTTER_CLIENT.md`。

## 当前状态

已完成：连接 / 启动自动连接 / 下拉刷新、目录浏览（含新建、重命名、移动）、上传下载（多选、实时进度与速度、5 并发）、断点续传、复制 / 删除（回收站）、图片与文本预览、多选批量操作、传输通知、前台服务保活与厂商后台适配、大文件（按磁盘可用空间判断，实测 600 MB 通过）。

未验证 / 未完成：release 包与 JNI Context、Windows 桌面构建（缺 VS2022）、华为真机锁屏后的后台保活实测、配置持久化。

各次事故复盘与设计取舍见 `docs/FLUTTER_CLIENT.md`（§4.1 起）。

## 文档

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — 架构设计、数据模型、威胁模型、风险登记
- [`docs/DEVELOPMENT_PLAN.md`](docs/DEVELOPMENT_PLAN.md) — 分阶段计划与验收判据
- [`docs/RUNNING.md`](docs/RUNNING.md) — 运行与部署手册
- [`docs/FLUTTER_CLIENT.md`](docs/FLUTTER_CLIENT.md) — Flutter 侧、FFI 契约、问题复盘
- [`infra/README.md`](infra/README.md) — relay 部署清单

## 注意

文档与示例中的域名、IP、端口、`EndpointId` **均为占位符**（`relay.example.com`、`203.0.113.0/24`、`YOUR_ENDPOINT_ID` 等），部署时请替换为你自己的值。真实 token、密钥、`local.properties`、编译产物（含 `jniLibs/*.so`）均已在 `.gitignore` 中排除，Android 端克隆后需自行 `cargo ndk` 重编动态库，见 `docs/FLUTTER_CLIENT.md` §4.15。

> ⚠️ **安全提示**：默认使用 n0 公共 relay 时，服务端**没有应用层鉴权** —— 任何知道 `EndpointId` 的人都能连接并读写文件。因此不要把真实 `EndpointId` 写进公开仓库、日志或截图；生产部署应自行增加认证与访问控制。若曾公开过，请删除服务端 `secret.key` 并重启以轮换设备身份，然后重新配对所有客户端。
