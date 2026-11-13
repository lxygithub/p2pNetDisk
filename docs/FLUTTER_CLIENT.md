# Flutter 客户端（v0.1）

> 目标：Android 优先、后续扩展其它端；Rust 侧能力统一由 `netdisk-core` 提供，Flutter 只通过 `dart:ffi` 调用 `netdisk-ffi` 导出的 C ABI。

## 1. 当前状态（2026-11-13）

| 项 | 状态 |
| --- | --- |
| Flutter 项目骨架（`app/`，android + windows） | ✅ 已创建，50 个文件 |
| Rust `cdylib`（`netdisk_ffi.dll`） | ✅ 已编译 |
| Dart FFI 绑定（`app/lib/src/netdisk_ffi.dart`） | ✅ 完成 |
| 最小 UI：配置 / 连接 / 文件列表 / 上传 / 下载（`app/lib/main.dart`） | ✅ 完成 |
| `flutter analyze` | ✅ **No issues found** |
| 纯 Dart 冒烟测试 `ping / list / put / get` | ✅ **全 PASS**，跨 VPS relay 连家用服务器常驻服务 |
| Gradle 依赖下载 | ✅ 已修：wrapper 换腾讯云镜像 + `systemProp.*` 走 Clash（§3.1） |
| Android `.so`（arm64-v8a） | ✅ `cargo-ndk` 交叉编译，已打进 APK |
| Android 真机 / 模拟器 | ✅ UI 启动、`netdisk_init` 成功（界面显示「已连接」） |
| FFI 执行位置 | ✅ 已改为常驻后台 isolate（`netdisk_worker.dart`）；此前在 UI isolate 同步调用导致 **ANR**，见 §4.1 |
| **Android `list`（真机）** | ✅ **已拿到文件列表**：n0 官方 relay（自动选中 `aps1-1`）+ 后台 isolate，一次成功 |
| **上传 / 下载（UI）** | ✅ 已实现：`file_picker` 多选上传、列表项下载到 App 文档目录；**上传已真机验证**（1.1MB 落到数据盘，BLAKE3 一致） |
| 手机直连稳定性 | ⚠️ 时好时坏：11:41 走 IPv6 直连 RTT 32ms，13:01 上传时 `direct=NO`（全程 relay，RTT 0.9–1.8s）。见 §4.4 |
| **传输路径显示** | ✅ 标题栏 Chip 显示「直连 · 5 ms」/「中继 · 1.2 s」，数据来自 `netdisk_paths()` |
| **删除 / 重命名** | ✅ 列表项右侧 ⋮ 菜单；删除是**移入服务端回收站**（`.trash/`），不是硬删。已用 CLI 端到端验证（§4.5） |
| **传输进度** | ✅ 上传/下载均显示 `LinearProgressIndicator` + 「已传 / 总量」。实现用共享内存计数器而非回调，原因见 §4.6 |
| **目录浏览** | ✅ 面包屑导航 + 目录优先排序；上传落到当前目录。纯客户端过滤，无需改协议（§4.7） |
| **UI 重构** | ✅ 三页底部导航（文件/传输/设置）+ `AppState` 状态层 + Material 3 主题（§4.8） |
| **传输队列 + 速度** | ✅ 任务队列，实时进度 + 2 秒滑窗瞬时速度，失败可重试；**最多 5 个并发**（§4.9） |
| **文件管理** | ✅ 新建目录（多级）、复制、重命名/移动、删除（回收站）；服务端返回目录项，**空目录可见** |
| **文件预览** | ✅ 图片（可缩放）与文本（截断 200KB）；其他类型明确提示不支持 |
| **毛玻璃 UI** | ✅ 渐变背景 + 半透明卡片；列表项不做实时模糊（性能取舍见 §4.9） |
| **自动连接 / 下拉刷新** | ✅ 启动即自动连接并拉列表（失败退避重试 3 次）；列表下拉即刷新，掉线自动切回未连接态（§4.10） |
| **传输通知** | ✅ 一条汇总通知（进行中/排队/已完成/失败），原生 MethodChannel 实现（§4.11） |
| **断点续传** | ✅ `Put` 一次往返协商 offset，只补发剩余字节；已实测「半截 .part → 只传 512KB → 哈希一致」（§4.12） |
| **后台任务** | ✅ `TransferService` 前台服务保活，复用同一通知渠道；设置页提供电池优化与厂商自启动入口（§4.13） |
| **长连接复用** | ✅ FFI 侧改为复用一条 QUIC 连接（原来每条命令重连，打洞来不及完成、`paths()` 只能看到 relay） |
| `.so` 版本防错配 | ✅ `netdisk_ffi_version()` + 连接前校验；旧库会提示「动态库过旧（不支持 n0）」 |
| Windows 桌面实际构建 / 运行 | ⛔ 本机无 Visual Studio 2022 C++ 工具链 |

冒烟测试实测输出：

```
ping: {Pong: null}
put: {Stored: {path: e2e/ffi_smoke.bin, size: 65536, hash: 68d647e6...}}
get: {Downloaded: {size: 65536, hash: 68d647e6...}}
list: [(path: e2e/ffi_smoke.bin, size: 65536), (path: e2e/final.bin, ...), ...]
FFI_SMOKE_OK
```

上传与下载 BLAKE3 一致、字节逐字节比对通过。测试会在服务端留下 `e2e/ffi_smoke.bin`（MVP 协议还没有删除命令）。

## 2. 目录结构

| 路径 | 作用 |
| --- | --- |
| `netdisk-ffi/` | Rust `cdylib`，导出 C ABI；内部用全局 tokio runtime 驱动 iroh |
| `app/lib/src/netdisk_ffi.dart` | `dart:ffi` 绑定、字符串分配/释放、`Entries` 解析 |
| `app/lib/src/netdisk_worker.dart` | **常驻后台 isolate**：所有 FFI 调用在这里串行执行，UI 线程不被阻塞 |
| `app/lib/main.dart` | 入口：Provider 注入 `AppState` + 主题 |
| `app/lib/state/app_state.dart` | 应用状态：连接、文件浏览、**传输队列**（串行消费） |
| `app/lib/models/transfer_task.dart` | 传输任务模型 + `SpeedMeter` 滑动窗口测速 + 人读格式化 |
| `app/lib/pages/` | 页面：`home_shell`（底部导航）、`files_page`、`transfers_page`、`settings_page` |
| `app/lib/widgets/` | 复用组件：`breadcrumb`（路径导航）、`path_chip`（直连/中继徽标） |
| `app/lib/theme.dart` | Material 3 主题（种子色派生、统一圆角与输入框） |
| `app/tool/ffi_smoke.dart` | 不启 UI、在主 isolate 直接调 C ABI 的底层冒烟测试 |
| `app/tool/worker_smoke.dart` | 走 `NetdiskWorker` 的冒烟测试 —— 与 App 实际执行路径一致 |
| `app/windows/CMakeLists.txt` | 构建时把 `netdisk_ffi.dll` 复制到 exe 同目录 |
| `app/android/app/src/main/jniLibs/arm64-v8a/` | Android `.so` 落地目录（已有 `libnetdisk_ffi.so`，被 `.gitignore` 忽略） |
| `tools/build-android-ffi.sh` | 交叉编译并放置 `.so` 的脚本 |

## 3. 每次开终端必须先设代理

Flutter 启动时会跑 `git fetch --tags`。当前 shell 被自动注入了 `127.0.0.1:60721`，它会破坏 git pack 传输，导致 `fatal: fetch-pack: invalid index-pack output` 后卡死。**必须显式覆盖为 Clash 的 7897**：

```bash
export HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 \
  https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 \
  ALL_PROXY=http://127.0.0.1:7897 all_proxy=http://127.0.0.1:7897 \
  NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 \
  FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
  PUB_HOSTED_URL=https://pub.flutter-io.cn \
  FLUTTER_SUPPRESS_ANALYTICS=true
```

验证：`flutter --version` 应在数十秒内返回 `Flutter 3.44.2 / Dart 3.12.2`。不要运行 `flutter doctor -v`，它的设备检查会调用 `wmic.exe` / `reg.exe`，在当前沙箱里被安全策略拦截。

### 3.1 Gradle 的代理是独立配置的

`flutter build` 会启动 Gradle（JVM），**它不读 shell 的 `HTTP_PROXY`**，只设环境变量仍会 `java.net.ConnectException: Connection timed out`。已做两处修改：

- `app/android/gradle/wrapper/gradle-wrapper.properties`：发行版换成 `https://mirrors.cloud.tencent.com/gradle/gradle-9.1.0-bin.zip`。官方源会 `307` 跳到 GitHub releases；`-bin` 也比 `-all` 小一半以上（实测 21 秒下载完）；
- `app/android/gradle.properties`：加 `systemProp.http(s).proxyHost/Port=127.0.0.1/7897` 与 `nonProxyHosts`，让 `google()` / `mavenCentral()` / `gradlePluginPortal()` 走 Clash。端口变了改这四个值即可。

验证：`gradlew --version` 打印 `Gradle 9.1.0`，`flutter build apk --debug` 不再卡在 `ConnectException`。

### 3.2 Android 插件版本坑：`checkDebugAarMetadata` / compileSdk 36

**现象**：

```
Execution failed for task ':file_picker:checkDebugAarMetadata'.
Dependency ':flutter_plugin_android_lifecycle' requires ... compile against version 36 or later.
:file_picker is currently compiled against android-34.
```

**原因**：`file_picker 8.x` 的 Android 模块编译在 `android-34`，而它依赖的 `flutter_plugin_android_lifecycle` 新版要求消费方 compileSdk ≥ 36。这是插件自身的问题，**改 app 的 compileSdk 治不了**。

**修复**：升到 `file_picker: ^13.3.3`。v12 起改为联邦插件架构，**不再依赖 `flutter_plugin_android_lifecycle`**，冲突消失。同时 `app/android/app/build.gradle.kts` 里把 compileSdk 写成 `maxOf(flutter.compileSdkVersion, 36)` 兜底。

**API 也跟着变了**（v12/v13 破坏性变更，必须同步改代码）：

| 旧（≤ v11） | 新（v13） |
| --- | --- |
| `FilePicker.platform.pickFiles(allowMultiple: true)` | `FilePicker.pickFiles()`（`pickFile()` 是单选） |
| 返回 `FilePickerResult?`，取 `.files` | 直接返回 `List<PlatformFile>`，取消时是空列表 |
| `file.size` | `await file.length()` 或 `file.lengthSync()` |
| `withData` / `withReadStream` | `file.readAsBytes()` / `file.readAsByteStream()` |

`file.path` 与 `file.name` 仍在，直接用即可。

### 3.3 Kotlin 增量编译：跨盘路径导致 build 失败

**现象**：

```
java.lang.AssertionError: Could not close incremental caches in
  ...\app\build\android_file_picker\kotlin\compileDebugKotlin\cacheable\caches-jvm\jvm\kotlin
Caused by: java.lang.IllegalArgumentException: this and base files have different roots:
  C:\Users\...\AppData\Local\Pub\Cache\hosted\...\CompressedBitmapWriter.kt and D:\workdbuddy\...\app\android
```

**原因**：pub 缓存在 **C 盘**、项目在 **D 盘**。Kotlin 增量编译器用 `relativeTo()` 记录源文件相对路径，跨盘时抛异常，写缓存失败 → 整个 build 失败。**与代码无关**，是工具链在 Windows 双盘布局下的缺陷。

**修复**（`app/android/gradle.properties`）：

```properties
kotlin.incremental=false
kotlin.incremental.useClasspathSnapshot=false
```

并清掉已损坏的缓存目录：`rm -rf app/build`（约 1.1G，下次构建自动重建）。

Flutter 侧 Kotlin 代码极少，全量编译的代价可以忽略；换来的是稳定性。

**更彻底的做法**（可选）：把 pub 缓存也放到 D 盘，让所有源文件同根。

```powershell
$env:PUB_CACHE = "D:\pub-cache"
```

但这会影响机器上所有 Flutter 项目，需要重新下载依赖，一般不必。

### 3.4 `Running Gradle task 'assembleDebug'...` 长时间不动

**不是编译慢，是依赖下载断了。** 判断方法（三条一起看）：

```powershell
# 1) build 目录还动吗（app/build 是 AGP 的 buildDirectory）
Get-ChildItem D:\workdbuddy\workspace\iroh\app\build -Recurse -File |
  Sort-Object LastWriteTime -Descending | Select-Object -First 3 LastWriteTime,Name

# 2) 有没有正在下载的临时文件
Get-ChildItem "$env:USERPROFILE\.gradle\caches" -Recurse -Include *.part,*.tmp |
  Sort-Object LastWriteTime -Descending | Select-Object -First 5

# 3) daemon 的网络连接状态
$p = (Get-Process java | Sort-Object CPU -Descending)[0].Id
Get-NetTCPConnection -OwningProcess $p | Group-Object State | Select-Object Name,Count
```

判断依据：

| 观察 | 含义 |
| --- | --- |
| build 目录几分钟不更新 | 已经不在编译 |
| 没有 `.part` 文件 | 下载也已停止（不是在慢慢下） |
| 大量 `CloseWait`、极少 `Established` | 连接被对端断开，daemon 卡在等超时 |

这时 build 已经死了，等下去不会成功。

**处理**：

```powershell
cd D:\workdbuddy\workspace\iroh\app\android
.\gradlew.bat --stop      # 杀掉僵死的 daemon
```

然后重跑。为减少对代理的依赖，项目已加阿里云镜像（`settings.gradle.kts` 的 `pluginManagement` 与根 `build.gradle.kts` 的 `allprojects`），并在 `gradle.properties` 里把 `*.aliyun.com` 加入 `nonProxyHosts` 走直连；官方源保留兜底，镜像缺包时 Gradle 会自动回落。

### 3.5 根本原因：Gradle 默认没有 HTTP 超时

只加镜像是治不好的。真正的坑在 `gradle.properties`：

```properties
systemProp.org.gradle.internal.http.connectionTimeout=15000
systemProp.org.gradle.internal.http.socketTimeout=30000
systemProp.org.gradle.internal.repository.max.retries=3
systemProp.org.gradle.internal.repository.initial.backoff=500
```

**Gradle 的 HTTP 客户端默认没有 socket 读超时。** 一条连接如果 TCP 握手成功、但对端后续不返回数据（跨境链路被干扰的典型表现），Gradle 会一直阻塞读，既不失败也不继续 —— build 就永久停在 `assembleDebug`。

判断方法（很可靠）：**间隔 40 秒采样两次 `~/.gradle/caches` 的大小，delta 为 0 就说明是挂起而不是慢**。

```powershell
$p="$env:USERPROFILE\.gradle\caches"
(Get-ChildItem $p -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
Start-Sleep 40
(Get-ChildItem $p -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
```

配合 `jstack` 看线程，会看到主线程停在 `DefaultBuildOperationQueue.waitForWorkToComplete`，worker 停在 `SocketInputStream.read` —— 就是标准的「等一个永远不会来的响应」。

**改完 `systemProp.*` 必须停 daemon**（`gradlew --stop`），因为这些属性只在 daemon 启动时读取一次。

顺带开启的构建效率项：`org.gradle.parallel=true`、`org.gradle.caching=true`、`android.enableJetifier=false`（新项目全是 AndroidX，不需要 Jetifier 全量扫描）。

## 4. 冒烟测试（已可复现）

默认走 **n0 官方公共 relay**，不需要 token，地址只给 EndpointId（由 `dns.iroh.link` 解析）：

```bash
cd app

export NETDISK_FFI_DLL="D:/workdbuddy/workspace/iroh/tools/poc/p0-1/target/debug/netdisk_ffi.dll"
export NETDISK_RELAY_URL=n0
export NETDISK_RELAY_TOKEN=
export NETDISK_SERVER_ADDR='{"id":"YOUR_ENDPOINT_ID","addrs":[]}'
dart run tool/ffi_smoke.dart
```

切回自建 relay 时才需要这几步：

```bash
TOKEN="$(ssh -p 2222 root@203.0.113.10 \
  "awk -F '\"' '/^access.shared_token/ {print \$2}' /etc/iroh/relay.toml")"
TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r\n')"   # Windows SSH 会带 CRLF
export NETDISK_RELAY_URL="https://relay.example.com:8443"
export NETDISK_RELAY_TOKEN="$TOKEN"
export NETDISK_SERVER_ADDR='{"id":"YOUR_ENDPOINT_ID","addrs":[{"Relay":"https://relay.example.com:8443/"}]}'
```

> `addrs` 字段是必填的（`EndpointAddr` 的 serde 没有 `#[serde(default)]`），只给 id 时要写 `"addrs":[]`。

`NETDISK_SERVER_ADDR` 只保留 `Relay` 项，强制流量经 VPS，便于跨网络复现；服务端固定身份见 `docs/RUNNING.md`。

再跑一次**与 App 完全同路径**的测试（后台 isolate + 重试）：

```bash
dart run tool/worker_smoke.dart
```

期望输出（n0 模式实测值）：

```
start    : OK (16 ms)
init     : OK (54 ms) running=true
list     : OK (2154 ms) count=4
WORKER_SMOKE_OK
```

`list` 一次成功、无重试。对比切 n0 之前：自建港服 relay 下单次握手只有 2/8，`list` 3 次重试仍超时。

### 4.1 为什么 FFI 必须跑在后台 isolate（ANR 复盘）

**现象**：真机点「刷新列表」后界面完全无响应，几秒后系统弹出 ANR。

**根因**：`netdisk_list` 等 C ABI 是**同步阻塞**的（Rust 侧 `RT.block_on(...)`），而 Dart 侧原来直接在 UI isolate 上调用：

```dart
// 错误写法：listFiles() 内部要 connect + open_bi + 等 RPC，可能几秒到几十秒
final res = client.listFiles();
```

一次跨网 `connect + RPC` 在 R14 这条链路上常常要数秒，丢包时还要等 iroh 的 10s 拨号超时。期间主线程被占死，Android 5 秒无输入响应即判 ANR —— 连 `CircularProgressIndicator` 都不会转。

**为什么不能简单套 `Isolate.run` / `compute`**：`Pointer`（FFI 句柄）不能跨 isolate 传递，每次新建 isolate 都要重新 `init`（重建 endpoint），代价不可接受。

**采用的方案**：常驻 worker isolate（`netdisk_worker.dart`）。

| 位置 | 职责 |
| --- | --- |
| UI isolate | 只发命令 + 收 JSON 字符串，用 `Completer` 等结果，完全不阻塞 |
| worker isolate | `DynamicLibrary.open` → `netdisk_init` → 持有 `Pointer<Handle>` → 串行执行 ping/list/put/get |

消息协议：主 → worker `[id, op, ...args]`；worker → 主 `['res', id, payload, error]`。全部是可跨 isolate 传的基本类型，句柄始终留在 worker 内。

**同时补上的重试**：原来 UI 走的是裸调用（只有 `netdisk-cli` 有 3 次重试），所以链路上一次抖动就直接报 `timeout`。现在 `list` 默认 3 次（退避 1s / 2s），`put` / `get` 2 次，且**只对链路类错误重试**（`timed out` / `connection` / `reset`），token 被拒、路径不存在这类确定性错误立即抛出。

> 改动只涉及 Dart，`libnetdisk_ffi.so` 不需要重新交叉编译；但必须 `flutter build apk` 重新打包安装才生效。

### 4.2 典型故障：`.so` 与 UI 版本错配

**现象**：界面出现 `连接失败: invalid relay URL n0: Failed to parse relay URL`。

**原因**：`n0` 这个特殊值的判断在 Rust 的 `netdisk-core` 里（`is_n0_relay`），编进 `.so` 才生效。当时 UI（Dart）是新的、`jniLibs/libnetdisk_ffi.so` 还是旧的，于是 `n0` 被直接当 URL 解析。

**判断方法**：比对时间戳。

```powershell
dir app\android\app\src\main\jniLibs\arm64-v8a\libnetdisk_ffi.so   # 应为最近编译时间
dir app\build\app\outputs\flutter-apk\app-debug.apk
```

**规则**：只要改了 `netdisk-core` / `netdisk-ffi` / `netdiskd` 里任意 Rust 代码，就必须重跑一次交叉编译，顺序不能反：

```powershell
cargo ndk -t arm64-v8a -o app\android\app\src\main\jniLibs build -p netdisk-ffi --release
cd app; flutter build apk --debug; flutter install
```

`flutter build apk` 只会把 `jniLibs` 里**现有**的 `.so` 打进包，它不会帮你重编 Rust。

**已加防呆**：`netdisk_ffi_version()` 导出能力标记，UI 在 `init` 之前校验；旧库缺该符号或返回值里没有 `n0` 时，直接提示「动态库过旧（不支持 n0）：请重新交叉编译 .so 后再打 APK」。

### 4.3 上传 / 下载 / 路径显示（2026-11-13）

**上传**：`file_picker` 多选 → 逐个 `put` 到服务端**根目录**，文件名取本地 basename。重名按服务端既有语义覆盖（架构 D4：同路径同 hash 幂等、同条目并发写 LWW）。逐个上传，失败不中断后续文件，最后汇总「完成 N 个，失败 M 个」。

**下载**：点列表项右侧的下载按钮 → 落到 `getApplicationDocumentsDirectory()/downloads/<basename>`，完整路径显示在状态栏。

**为什么下载不直接写「下载」目录**：Android 10+ 分区存储下，写公共目录要走 MediaStore 或 SAF（用户选目录），MVP 先用 App 私有目录把链路跑通。后续接 `share_plus` 让用户「分享 / 另存到文件」，或改用 SAF 选目录。

**路径显示**：标题栏 Chip 显示「直连 · 5 ms」或「中继 · 1.2 s」，数据来自 `netdisk_paths()`。列表刷新后会立刻读一次，并在 4 秒后再读一次——因为打洞要几秒才完成，第一次通常还是中继。

**长连接复用（重要改动）**：原来每条 `ping/list/put/get` 都 `ep.connect()` 新建连接、用完即关，有两个代价：

1. 每次都重新握手，跨网 1–2 秒，列表刷新很慢；
2. 连接活不过 1 秒，**NAT 打洞根本来不及完成**，`paths()` 永远只看到 relay。

现在 `Handle` 里缓存一条 `Connection`（`close_reason().is_none()` 才复用），操作失败时清缓存下次重连。收益：握手只在首次发生；打洞几秒内完成，之后命令走直连。

| 场景 | 改前 | 改后 |
| --- | --- | --- |
| 第二次及以后的命令 | 重新握手 1–2 s | 复用连接，直接开流 |
| 打洞 | 来不及完成，一直走 relay | 几秒后切直连，`paths()` 能读到 |
| 连接失效 | 每条都是新连接，天然规避 | 靠 `close_reason()` + 失败清缓存重连 |

### 4.4 手机直连不稳定：同一台设备两次结果不同

| 时间 | 服务端观察到的路径 | RTT |
| --- | --- | --- |
| 11:41（点刷新列表） | `direct* [2001:db8:1:...]` —— **公网 IPv6 直连** | 32 ms |
| 13:01（上传 1.1MB） | `relay* aps1-1`，`direct=NO` —— **全程中继** | 0.9–1.8 s |

同一台手机、同一台服务器、几小时内两种结果。可能原因：

- 手机在 WiFi 与 5G 之间切换过，两个网络的 IPv6 可达性不同；
- 手机侧 IPv6 前缀/地址变化（隐私地址轮换），服务端拿到的旧候选已失效；
- 运营商的 IPv6 防火墙策略在这个时段收紧。

**结论**：IPv6 直连是「有则几乎必成」，但**不保证一直有**。不能假设手机永远直连。

**应对顺序**（按性价比）：

1. App 里已经显示路径 Chip（「直连 · 32ms」/「中继 · 1.2s」），用户能自己判断当前状态——这是最先该做的，已完成；
2. 小文件走中继可以接受（n0 免费、无 SLA，但 1MB 级别没问题）；
3. 要稳定直连，最省事的是给手机也装 Tailscale，iroh 会自动识别 `100.64/10` 网段做直连（桌面端实测 5–8ms）；
4. 长期方案仍是自建 relay（回到 R14 的线路问题）。

**排查方法**：服务端 `netdiskd` 日志里看 `paths +4s` 那一行的 `direct=YES/NO`，比在客户端猜更准 —— 因为服务端看到的是它自己这一侧的完整路径集合。

### 4.5 删除 / 重命名：语义与验证

**删除不是硬删**。服务端把文件 `rename` 到 `<data>/.trash/<unix秒>-<文件名>`，架构 §5.3 约定的「用户主动删除走回收站」由此落地。`.trash` 以 `.` 开头，`safe_path`（拒绝任何 `.` 开头的组件）和 `list_entries`（跳过 `.` 开头的项）都会把它排除，所以：

- 客户端看不到回收站；
- 也无法通过 `get` 读到 `../.trash/xxx`；
- 同名文件在同一秒内被删时，会追加序号避免互相覆盖。

**重命名不覆盖**。目标已存在时服务端直接返回错误：

```
$ netdisk-cli rename rn-test-renamed.txt e2e/final.bin
Error: server: target already exists: e2e/final.bin
```

这是刻意的：覆盖属于 `Put` 的语义（架构 D4 的 LWW），重命名不该成为「静默盖掉别人文件」的途径。重命名同时充当移动，`to` 可以带子目录（父目录会自动创建）。

**CLI 端到端验证记录**：

```
put     : uploaded rn-test.txt (14 bytes) blake3=2839f650...
rename  : renamed rn-test.txt -> rn-test-renamed.txt
list    : 14  rn-test-renamed.txt
rename→已存在: Error: server: target already exists: e2e/final.bin
delete  : deleted rn-test-renamed.txt -> .trash/1794547119-rn-test-renamed.txt
list    : （已消失）
.trash/ : 1794547119-rn-test-renamed.txt  14 bytes   ← 仍在数据盘
```

服务端日志同步确认：`[netdiskd] deleted rn-test-renamed.txt -> .trash/1794547119-rn-test-renamed.txt`。

**UI 入口**：文件列表每项右侧 `⋮` → 下载 / 重命名 / 删除。删除有确认对话框，并说明「会移入回收站，不会立即物理删除」。

### 4.6 传输进度：为什么用共享内存而不是回调

直觉做法是给 FFI 传一个函数指针，Rust 每传完一块就回调一次。**在 Flutter 里这个方案不成立**：

Rust 的 `put/get` 是在 **worker isolate 里同步阻塞**执行的（`RT.block_on`），这段时间该 isolate 的事件循环完全停摆。`NativeCallable` 投递过来的回调消息只能排队，等传输结束、阻塞解除后才一次性涌入 —— 进度条会在传完之后瞬间从 0 跳到 100%，等于没有。

**采用的方案：共享计数器 + 独立轮询**

```
主 isolate                     worker isolate              Rust
   │  malloc<Uint64>(1) ────────┐                            │
   │  把 address 放进命令 ──────▶│ netdisk_put_progress(addr) │
   │                            │   ├─ block_on(传输)  ──────▶│ 每 64KB
   │  Timer 250ms 轮询 ◀────────┼───┼────────────────────────┼─ store(sent)
   │  （读同一块内存，不被阻塞）  │   └─ 返回                 │
   │  malloc.free(ptr) ◀────────┘                            │
```

关键设计：

- **内存由主 isolate 分配和释放**，只有地址（int）传进 worker。如果反过来让 worker 分配，它会在传输结束时 `free`，而主 isolate 的定时器可能还在读 —— 悬空指针。
- Rust 侧用 `AtomicU64` 写，Dart 侧用 `asTypedList(1)` 读（每次读真正访存，不会被优化成缓存值）。
- 轮询间隔 250 ms，对大文件足够顺滑，对 UI 也没有压力。
- `netdisk_put` / `netdisk_get`（无进度版本）保留，新导出是 `netdisk_put_progress` / `netdisk_get_progress`；旧库缺符号时 Dart 侧自动回落到普通版本。

**代价**：多一块 8 字节的跨语言共享内存和一次 `malloc/free`，换来传输过程可观测。

### 4.7 目录浏览：客户端过滤，不改协议

服务端的 `List` 一直是**递归返回全量**文件列表。之前 UI 直接平铺，文件一多就变成一长串 `e2e/xxx`，既看不出层级也没法导航。

**没有改协议**，而是在客户端按前缀切层：

```
_cwd = 'photos/2026/'            // 当前目录，根目录为 ''
files = ['photos/a.jpg', 'photos/2026/b.jpg', 'notes.txt']

可见项 = 以 _cwd 开头的条目，取剩余部分的第一个 '/' 之前的部分：
  'a.jpg'   → 文件（剩余部分无 '/'）
  '2026'    → 目录（剩余部分含 '/'，取第一段）
```

收益是不动服务端、不动 FFI，纯 Dart 就能上。代价是每次刷新仍拉全量列表——几万条以内没问题，再大就需要服务端支持按目录列举（协议加 `List { prefix }` 或分页）。

**交互**：

- 顶栏面包屑 `/ › photos › 2026`，每段可点回对应层级；非根目录时左侧有「上一级」箭头。
- 列表里目录在前、文件在后，各按名称排序；点目录进入，点文件右侧 `⋮` 出菜单。
- 上传落到**当前目录**（`put` 的 remote 为 `$_cwd$fileName`，父目录由服务端自动创建）。
- 刷新时若 `_cwd` 已被删除或重命名，自动退回根目录，不会停在空视图上。

### 4.8 界面重构：从单页 State 到三页 + 状态层

原来的 `main.dart` 是一个 600 行的 `StatefulWidget`，文件列表、传输、配置全混在一个 `State` 里。加「传输队列」和「通知」时已经无处安放，所以先做了结构拆分：

| 层级 | 职责 |
| --- | --- |
| `state/app_state.dart` | `ChangeNotifier`：连接态、文件列表、当前目录、传输队列、状态文案 |
| `models/transfer_task.dart` | 任务模型 + `SpeedMeter`（2 秒滑动窗口测速） |
| `pages/` | 三页：文件 / 传输 / 设置，`IndexedStack` 保留各自状态 |
| `widgets/` | `Breadcrumb`、`PathChip` 等复用组件 |

**为什么用 `provider`**：三页都要读同一份状态（传输页看队列、文件页看连接态、设置页改配置），逐层传参或 `InheritedWidget` 手写都太啰嗦。

**传输队列为什么是串行的**：FFI 句柄内部只有一条 QUIC 连接 + 一个 `Mutex`，并发发多个 `put/get` 只会在锁上排队，还会把共享内存里的进度计数器搅乱（同一块内存只能表示一个传输）。串行让「进度」和「任务」一一对应，也让速度统计准确。

**速度怎么算**：`SpeedMeter` 保留最近 2 秒内的采样点，用 `(最新 sent − 最早 sent) / 时间差` 得瞬时速度。用平均值会把瞬时波动抹平（大文件前 90% 和最后 10% 的速度差异就看不出来了）。

**任务状态机**：`queued → running → done / failed`，失败可「重试」（重新入队并清零进度）。队列清空后自动静默刷新文件列表，保证上传完立刻能看到新文件。

### 4.9 文件管理、预览、毛玻璃与并发

**目录项必须由服务端返回。** 之前 `list` 只返回文件，`FileEntry` 也没有类型字段，结果是：

- 新建的空目录**在客户端完全不可见**（建了等于没建）；
- 客户端只能靠「路径里有没有 `/`」猜目录，遇到空目录就失效。

现在 `FileEntry` 增加 `is_dir`，`list_entries` 遍历时把目录本身也放进去。客户端优先用这个字段，同时保留路径推断作为旧服务端的兼容路径。

**复制的语义**：服务端本地 `std::fs::copy`，数据不过网络 —— 相比「下载再上传」省掉两次全量传输。目标已存在时报错，与 `rename` 一致，不做静默覆盖。

**移动就是重命名**：`Rename` 的 `to` 可以是任意相对路径，改目录即移动，不必新增协议。

**预览的现实边界**：图片用 `Image.file`（`cacheWidth: 2400` 防止大图 OOM），文本只读前 200 KB 并提示截断。视频/PDF/Office 不做内嵌渲染——没有可靠的跨平台方案，与其给一个打不开的黑框，不如明确说「请下载后用其他应用打开」。

**毛玻璃的性能取舍**：`BackdropFilter` 每次重绘都要采样背后整屏。列表里若有 20 个卡片各自开模糊，滚动会明显掉帧。所以：

| 位置 | 处理 |
| --- | --- |
| 背景 | 渐变 + 径向光斑（纯 CPU 绘制，不用 blur） |
| 列表卡片 | 半透明 + 白色描边，**blur = 0** |
| AppBar / 底部导航 / 对话框 | 真模糊（`GlassCard(blur: 8~20)`） |

**并发为什么能到 5**：iroh 的一条 QUIC 连接天然支持多流，Rust 侧 `connection()` 用双检锁保证首次只建一条连接，之后各任务 `open_bi()` 各自开流。但有两处必须配合：

- 每个任务的进度计数器是**独立 `malloc`** 的，否则 5 个任务的进度会互相覆盖；
- 队列用计数 + 60ms 轮询调度，而不是 `Future.wait`，这样「完成一个补一个」，不会等整批。

上限设 5 是非技术原因：手机网络下并发太多会让每条流都变慢，反而拉长总时间。

### 4.10 自动连接与下拉刷新

之前每次冷启动都要手动点「连接」再点「刷新列表」，对网盘类应用来说这是不可接受的摩擦。

**启动即自动连**：`AppState.bootstrap()` 在 Provider 创建时触发，流程是「连接 → 拉列表」。冷启动时网络、DNS、relay 都可能还没就绪，所以失败后按 **2s / 4s 退避重试**，三次都失败才停在错误态。

**为什么不是无限重试**：无限重试会让用户以为「卡住了」，且掩盖真实错误（比如地址填错）。三次之后停下来，把「重试」按钮交给用户，是更诚实的做法。

**下拉刷新**：列表用 `RefreshIndicator` 包住，未连接时下拉会**先连接再刷新**，一步到位。

**一个容易忽略的细节**：空状态页（未连接 / 目录为空 / 还没有文件）如果用 `Center` 直接返回，`RefreshIndicator` 收不到滚动手势，下拉就失效了。所以三种空态都改成可滚动的 `ListView`（`AlwaysScrollableScrollPhysics`）包住内容。

**掉线检测**：`refresh` 捕获到链路类错误（timeout / connection / reset / broken pipe）时，把 `connected` 置回 false。否则会停在「显示已连接、但什么都刷不出来」的矛盾状态——用户无法判断是网络问题还是服务端问题。

**widget 测试的坑**：`bootstrap` 里的 `Future.delayed` 会在测试结束时留下 pending timer 导致失败。所以 `NetdiskApp` 加了 `autoConnect` 开关，测试传 `false`。

### 4.11 传输通知：为什么自己写原生，而不是用插件

`flutter_local_notifications` 当前是 23.x，代价不小：

| 要求 | 我们的情况 |
| --- | --- |
| `compileSdk = 37` | 当前 36（`maxOf(flutter.compileSdkVersion, 36)`） |
| AGP ≥ 9.1.1 | 项目是 9.0.1 |
| core library desugaring + Java 17 + multidex | 未开启，且 desugaring 有 Android 12L 崩溃的已知问题 |

而需求只是「一条可更新的进度通知」。所以改为在 `MainActivity` 里写一个 `MethodChannel`（`netdisk/notifications`），用 `NotificationCompat` 直接发通知 —— 几十行代码，零额外依赖，也避开了版本地狱。

**只发一条汇总通知**。5 个并发任务如果各发一条，通知栏瞬间被刷满，用户还得挨个清。汇总成：

```
正在传输
进行中 2 · 排队 1（已完成 3/6）      [进度条 50%]
```

结束后变成「传输完成 / 5 个文件已完成」，`ongoing: false` 使其可被划掉。

**节流是必须的**。传输回调 250ms 一次，5 个并发就是 20 次/秒的跨语言调用。通知层限制为 800ms 一次，但状态变化（开始/完成/失败）走 `force: true` 立即更新 —— 否则「完成了」要等最多 0.8 秒才反映。

**渠道重要性设为 `IMPORTANCE_LOW`**，不响铃、不弹横幅、不显示角标。进度通知应该安静。

**权限**：Android 13+ 需要 `POST_NOTIFICATIONS` 运行时授权，已在 `bootstrap()` 里请求。**被拒绝不影响传输本身**，只是没有通知。

**为下一步留的接口**：`ForegroundService` 必须绑定一条通知，届时直接复用这个渠道和 `notificationId`，不用再改协议层。

### 4.12 断点续传

**协议设计：一次往返完成协商。** 客户端并不知道服务端已经收了多少，所以 `Put` 里的 `offset` 只是「建议值」（通常 0），真正的起点由服务端在 `Ready` 里给出：

```rust
Put   { path, size, offset: 0 }   // 客户端：我要传这个文件
Ready { offset: 524288 }          // 服务端：已有半截，从这里接着来
```

这样不需要额外的「查询进度」请求，省一次往返。

**服务端逻辑**（`netdiskd`）：

1. `.part` 存在且 `大小 <= size` → 从末尾接着写；
2. `.part` 比目标还大 → 说明是别的文件，删掉重来；
3. `.part` 超过 **24 小时**未改动 → 视为陈旧，删掉重来（防止隔天用同名不同内容的文件拼出错文件）；
4. 收完剩余字节后 `fsync` + `rename`，`.part` 随之消失。

**哈希处理的坑。** 原来的 `copy_exact_with_hash` 在传输过程中边收边算，但续传只收到**片段**，得到的只是片段 hash，没法与服务端的完整文件 hash 比对。所以改成：

- 客户端**传输前**先算完整文件的 BLAKE3（本地读盘）；
- 服务端**落盘前**把整个文件重读一遍重算（`spawn_blocking`，避免阻塞 runtime）；
- 两边比对一致才算成功。

代价是两端各多读一遍文件，但这是「拼接错误能被发现」的前提。

**顺手修掉的一个旧 bug**：临时文件原本用 `target.with_extension("netdisk-tmp")`，而 `with_extension` 是**替换**扩展名 —— `a.bin` 和 `a.txt` 会共用同一个临时文件，互相踩踏。改成追加后缀 `a.bin.netdisk-tmp`。

**进度衔接**：`copy_exact_with_hash_progress` 增加 `base` 参数，续传时进度从 `offset` 起算，进度条不会从 0 重新跳到一半。

**实测证据**：

```
手工造 512KB 的 .part → CLI 上传 1MB 文件
resuming at 524288 bytes (524288 left)      ← 只补发剩余一半
[netdiskd] resume resume-test.bin at 524288 bytes (524288 left)
最终 1048576 字节，sha256 与本地完全一致，.part 已清理
```

**已知局限**：只比对大小，不校验前缀内容。同一设备同一会话的重试是安全的；跨设备、或改了内容但大小不变的重传，理论上会拼错 —— 24 小时过期是缓解而非根治。要彻底解决需要传「前 N 字节的 hash」做指纹，属于后续优化。

### 4.13 后台任务与厂商适配

**问题**：Android 会在应用退到后台几分钟后回收进程，锁屏时更激进。QUIC 传输一旦被掐断，之前续传攒的进度虽然还在（`.part` 保留），但任务本身已经死了 —— 用户回到前台只会看到「失败」。

**实现**：`TransferService` 前台服务。

- 传输队列第一次有任务时 `startForegroundService`，队列清空时 `stopForeground(REMOVE)` + `stopSelf`；
- 通知**复用同一个渠道和 `notificationId`**（`netdisk_transfer` / `1001`），所以用户从头到尾只看到一条通知，不会因为启动服务多出一条；
- Android 14+ 必须声明类型，用 `FOREGROUND_SERVICE_TYPE_DATA_SYNC`；
- `START_NOT_STICKY`：进程被杀后重启没有意义，Flutter 引擎已经没了，没人再驱动传输。

**一个容易踩的时序坑**：停止服务时 `stopForeground(REMOVE)` 会把当前通知一起抹掉。如果先发「传输完成」再停服务，用户什么都看不到。所以顺序必须是 **先停服务 → 等 200ms → 再发结果通知**。

**厂商适配**。各家 ROM 对后台的管控比原生激进得多，光有前台服务不够：

| 厂商 | 需要用户手动开启 |
| --- | --- |
| 华为 / 荣耀 | 「应用启动管理」里允许后台活动；HarmonyOS 还会单独限制 |
| 小米 / Redmi | 「自启动」+「省电策略 → 无限制」 |
| OPPO / realme / 一加 | 「允许后台运行」 |
| vivo / iQOO | 「后台启动」白名单 |
| 魅族 / 三星 | 各自的后台管理页 |

做法是**列一串候选 Activity 逐个尝试**（`com.huawei.systemmanager.../StartupNormalAppListActivity` 等），全失败时退回应用详情页 —— 至少让用户能找到入口。ROM 随时会改这些类名，所以不能只硬编码一个。

设置页新增「后台运行」区块：显示设备型号（HarmonyOS 会标注）、电池优化是否豁免，以及两个按钮——「关闭电池优化」（系统标准对话框）和「自启动 / 后台管理设置」（厂商专属页）。

**HarmonyOS 识别**：`Build.MANUFACTURER` 仍是 `huawei`，通过反射 `com.huawei.system.BuildEx.getOsBrand()` 区分，用于在设置页给出更准确的提示。

**已知限制**：

- Android 15 对 `dataSync` 型前台服务有每日累计时长限制（约 6 小时），个人使用足够，但连续传超大文件可能撞上；
- 应用**在后台时**不允许启动前台服务（Android 12+），所以必须由用户在前台触发传输；
- 厂商页面类名会随 ROM 更新失效，需要持续维护；
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 在 Google Play 上属于受限权限，自用分发没问题，上架需要说明理由。

## 5. 平台落地（待工具链）
**Windows 桌面**（本机缺 VS 2022）：

1. 安装 Visual Studio 2022，勾选「使用 C++ 的桌面开发」；
2. `cargo build -p netdisk-ffi`（产物在 `tools/poc/p0-1/target/debug/netdisk_ffi.dll`）；
3. `flutter build windows` —— CMake 会自动把 dll 装到 exe 同目录；
4. `flutter run -d windows`，界面里填 Relay Token 后点「连接 / 刷新列表」。

也可跳过 CMake 安装步骤，直接给应用设 `NETDISK_FFI_DLL=<dll 绝对路径>`。

**Android**（工具链已就绪：SDK `D:\Sdk`、NDK `28.2.13676358`、`aarch64-linux-android` target、`cargo-ndk 4.1.2`）：

```powershell
$env:ANDROID_HOME="D:\Sdk"
$env:ANDROID_NDK_HOME="D:\Sdk\ndk\28.2.13676358"
cargo ndk -t arm64-v8a -o app\android\app\src\main\jniLibs build -p netdisk-ffi --release
cd app
flutter build apk --debug
```

产物 `libnetdisk_ffi.so` 会被 Flutter 自动打进 APK 的 `lib/arm64-v8a/`。**首次 release 交叉编译约 10–15 分钟**（新 target 缓存全空，约 300 个 crate），之后增量约 1 分钟；不要把输出 pipe 给 `tail`，否则中途看不到进度会误以为卡死。

> **P0-2 风险**：Android release 包首次 `Endpoint::bind()` 可能因 JNI Context 未初始化而崩溃（社区 `iroh_flutter` 1.0.2 修的正是这个）。若真机复现，需要在 `Application.onCreate` / `MainActivity` 里补 Kotlin 侧的 Context 初始化，再用 MethodChannel 或 JNI 传给 Rust 侧。当前 debug 包已在 Android 上验证 `netdisk_init` 成功；**release 包与长连接稳定性**仍未验证。

## 6. C ABI 契约

| 函数 | 说明 |
| --- | --- |
| `netdisk_init(relay_url, token, server_addr) -> handle` | 建 endpoint；失败返回 null，用 `netdisk_last_error` 取原因 |
| `netdisk_ping(handle)` | 返回 `Response` JSON |
| `netdisk_list(handle)` | 返回 `{"Entries":{"entries":[...]}}` |
| `netdisk_put(handle, remote, local)` | 返回 `{"Stored":{path,size,hash}}`；本地与服务端 hash 不一致会报错 |
| `netdisk_get(handle, remote, local)` | 返回 `{"Downloaded":{size,hash}}` |
| `netdisk_last_error()` | 最近一次错误文本 |
| `netdisk_delete(handle, path)` | 删除文件（移入回收站）：`{"Deleted":{"path":..,"trash":..}}` |
| `netdisk_copy(handle, from, to)` | 服务端本地复制：`{"Copied":{"from":..,"to":..}}`；目标存在则报错 |
| `netdisk_mkdir(handle, path)` | 新建目录（多级）：`{"DirCreated":{"path":..}}` |
| `netdisk_rename(handle, from, to)` | 重命名 / 移动：`{"Renamed":{"from":..,"to":..}}`；目标已存在时返回 `Error` |
| `netdisk_paths(handle)` | 当前连接路径：`{"Paths":{"desc":"relay ... | direct* ...","direct":true}}` |
| `netdisk_ffi_version()` | 能力标记，如 `netdisk-ffi 0.1.0 (relay-modes: n0,custom; proto: netdisk/0)` |
| `netdisk_string_free(ptr)` | 释放 Rust 返回的字符串（Dart 侧已封装） |
| `netdisk_close(handle)` | 释放 endpoint 与缓存的连接 |

约定：所有导出函数同步返回；字符串由 Rust 分配、Dart 释放；无字段枚举（`Pong` / `Ready`）被 serde 序列化成裸字符串，Dart 侧会包成 `{名称: null}`。`netdisk_paths` 与 `netdisk_ffi_version` 是后加的，旧库缺符号时 Dart 侧返回 null 而不是报错。

`handle` 内部缓存一条 QUIC 连接（`ping/list/put/get` 复用），失败时清缓存、下次自动重连。

## 7. 已知限制 / 下一步

- **下载文件在 App 私有目录**：`.../AppDocuments/downloads/`，用户需通过文件管理器或后续接「分享 / 另存」（`share_plus`）才能拿到。
- **进度只有字节计数**：UI 显示「已传 / 总量」，没有瞬时速率与剩余时间估算（要做需要滑动窗口采样）。
- **回收站不会自动清理**：删除只是移到 `<data>/.trash/`，目前没有保留期策略与恢复 UI。`.trash` 以 `.` 开头，`list_entries` 与 `safe_path` 都会排除它，用户既看不到也访问不到。
- **目录不能整棵删除**：`Delete` 只接受文件，删目录需要逐个删除文件（服务端会明确报错，不会误删）。
- **token 与地址未持久化**：退出应用后要重填（n0 模式只需点「连接」，痛点已减轻）。
- **续传只按大小匹配**：不校验 `.part` 与本地文件的前缀内容（跨设备同名不同文件仍有拼错可能，靠 24h 过期缓解）。
- **Windows 桌面仍未验证**（缺 VS 2022 C++ 工具链）；Android 已跑通到「连接」，`list / put / get` 待实测。
- **「已连接」≠ 可用**：`netdisk_init` 只建 endpoint，不校验 token、不发 RPC。真正的验证是点「刷新列表」。

相关：`docs/RUNNING.md`（服务端与常驻部署）、`docs/ARCHITECTURE.md`（R1 FFI 风险、R14 链路、R15 环境）。
