//! `netdisk-core` —— 个人网盘的连接层与最小文件协议。
//!
//! 这一层只做三件事，刻意保持很薄：
//!   1. 用 iroh 建 endpoint（`presets::Empty` + 自建 relay，不依赖 n0 的 DNS 发现）；
//!   2. 定义一条基于 ALPN 的长度前缀 JSON 帧协议（list / put / get / ping）；
//!   3. 提供带 BLAKE3 增量校验的流式文件传输与路径安全校验。
//!
//! 元数据存储、冲突仲裁、断点续传、blobs 内容寻址都不在这一层；它们是后续阶段的事。
//! 服务端（`netdiskd`）、CLI 客户端、以及将来的 Flutter FFI 都复用这个 crate。

use std::{
    path::{Component, Path, PathBuf},
    sync::Arc,
};

use anyhow::{anyhow, bail, Context, Result};
use iroh::{
    endpoint::{presets, Connection},
    Endpoint, EndpointAddr, RelayConfig, RelayMap, RelayMode, RelayUrl, TransportAddr,
};
use iroh_base::SecretKey;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// 一条连接只服务于本应用；ALPN 同时承担协议协商与隔离。
pub const ALPN: &[u8] = b"netdisk/0";
/// 默认使用 n0 官方公共 relay（见 [`RELAY_N0`]）。
///
/// 自建 relay 时把它设为 `NETDISK_RELAY_URL=https://<host>:8443` 并配 `NETDISK_RELAY_TOKEN`。
/// 2026-11-13 实测：家宽 → 自建港服 8443 的 TLS 握手仅 2/8，而 n0 的 `aps1-1` 为 8/8。
pub const DEFAULT_RELAY_URL: &str = RELAY_N0;
pub const MAX_FRAME: usize = 64 * 1024;
/// 单文件大小的「异常值防线」，**不是业务限制**。
///
/// 早期定 512MB 是怕误传超大文件打满家用服务器磁盘，但手机拍的 4K 视频、
/// 备份镜像经常超过它，实测 572G 可用空间下这个数字毫无意义。
/// 真正防止打满磁盘的检查在 `netdiskd`：按文件系统可用空间判断（留 1GiB 余量）。
/// 这里只挡住 size 解析错误之类的离谱值，16 GiB 足以覆盖个人使用场景。
pub const MAX_FILE_SIZE: u64 = 16 * 1024 * 1024 * 1024;

// ---------------------------------------------------------------------------
// 协议
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Request {
    Ping,
    List,
    /// `offset` 是客户端**建议**的起点（通常为 `Some(0)`，它并不知道服务端状态）；
    /// 服务端会以 `Ready { offset }` 告知实际能从哪开始。
    ///
    /// `None` = 旧版客户端（请求里没有这个字段）。旧客户端不支持续传，
    /// 服务端会按旧协议回 `Ready` 并从头接收完整文件 —— 这样升级服务端
    /// 不会把还没更新的手机一次性打死。以后加字段一律要 `#[serde(default)]`。
    Put {
        path: String,
        size: u64,
        #[serde(default)]
        offset: Option<u64>,
    },
    Get { path: String },
    /// 删除：移入回收站，**不是硬删**（架构 §5.3 约定，30 天后才真正清理）。
    Delete { path: String },
    /// 重命名 / 移动。`to` 是目标相对路径，可与 `from` 不同目录。
    Rename { from: String, to: String },
    /// 复制文件（服务端内部 copy，不经过网络）。
    Copy { from: String, to: String },
    /// 新建目录（含多级，父目录自动创建）。
    Mkdir { path: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Response {
    Pong,
    Entries { entries: Vec<FileEntry> },
    /// 服务端已准备好接收 `Put` 的裸数据流，并从 `offset` 开始。
    ///
    /// 断点续传的关键：服务端发现 `.part` 已有 N 字节时返回 `offset = N`，
    /// 客户端只需补发剩余部分，不必重传。
    Ready { offset: u64 },
    /// `Get` 的响应头，随后紧跟 `size` 字节裸数据。
    File { size: u64 },
    Stored { path: String, size: u64, hash: String },
    /// 删除成功。`trash` 是回收站内的相对路径，保留以便将来实现恢复。
    Deleted { path: String, trash: String },
    Renamed { from: String, to: String },
    Copied { from: String, to: String },
    DirCreated { path: String },
    Error(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    /// 目录项（`size` 恒为 0）。
    ///
    /// 以前只返回文件，导致**空目录在客户端完全不可见**，建了也白建。
    /// 这里显式带上类型，客户端不必再靠路径里有没有 `/` 去猜。
    #[serde(default)]
    pub is_dir: bool,
}

/// 写一个「u32 大端长度 + JSON」帧。
pub async fn write_frame<W, T>(w: &mut W, value: &T) -> Result<()>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let bytes = serde_json::to_vec(value)?;
    let len = u32::try_from(bytes.len()).context("frame too large")?;
    w.write_u32(len).await?;
    w.write_all(&bytes).await?;
    w.flush().await?;
    Ok(())
}

/// 读一个帧。流被对端正常关闭时返回 `UnexpectedEof`，由调用方决定是否退出循环。
pub async fn read_frame<R, T>(r: &mut R) -> Result<T>
where
    R: AsyncRead + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let len = r.read_u32().await? as usize;
    if len > MAX_FRAME {
        bail!("frame too large: {len} bytes");
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).await?;
    Ok(serde_json::from_slice(&buf)?)
}

/// 解析「上传就绪」帧，兼容新旧两种服务端形态。
///
/// - 旧：`"Ready"`（unit variant，不支持续传 → offset 0）
/// - 新：`{"Ready":{"offset":N}}`
/// - 拒绝：`{"Error":"..."}`
///
/// 抽成纯函数是为了能直接单测，不必搭 QUIC 流。
pub fn parse_ready_value(v: &serde_json::Value) -> Result<u64> {
    if let Some(msg) = v.get("Error").and_then(|x| x.as_str()) {
        bail!("server refused upload: {msg}");
    }
    if v.as_str() == Some("Ready") {
        return Ok(0);
    }
    if let Some(off) = v
        .get("Ready")
        .and_then(|x| x.get("offset"))
        .and_then(|x| x.as_u64())
    {
        return Ok(off);
    }
    bail!("unexpected response before upload: {v}")
}

/// 读一次 `Put` 的就绪响应。用 `serde_json::Value` 而非 [`Response`] 反序列化，
/// 这样新客户端连到旧服务端时也能工作（旧服务端回的是裸字符串 `"Ready"`）。
pub async fn read_put_ready<R>(r: &mut R) -> Result<u64>
where
    R: AsyncRead + Unpin,
{
    let v: serde_json::Value = read_frame(r).await.context(
        "服务端未响应 Put（协议版本不匹配？请确认 netdiskd 与客户端已同步升级）",
    )?;
    parse_ready_value(&v)
}

/// 精确搬运 `size` 字节并计算 BLAKE3。
///
/// 刻意不依赖 EOF：同一条 QUIC 双向流上，数据之后还要继续读响应帧，
/// 所以必须按声明的长度读，而不是 `read_to_end`。
pub async fn copy_exact_with_hash<R, W>(r: &mut R, w: &mut W, size: u64) -> Result<String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    copy_exact_with_hash_progress(r, w, size, 0, None).await
}

/// 与 [`copy_exact_with_hash`] 相同，但把「已传输字节数」实时写进 `progress`。
///
/// 这里用共享的原子计数器而不是回调函数，原因是调用方的实际约束：
/// Rust 的传输跑在 Flutter 的 **worker isolate 里同步阻塞**，这期间该 isolate
/// 无法处理事件循环，`NativeCallable` 投递过来的回调只能等传输结束后才被处理——
/// 等于没有进度。改成「Rust 写内存 + Dart 侧另一个 isolate 轮询」，
/// 两条路径互不阻塞，才能真正看到实时进度。
pub async fn copy_exact_with_hash_progress<R, W>(
    r: &mut R,
    w: &mut W,
    size: u64,
    base: u64,
    progress: Option<&std::sync::atomic::AtomicU64>,
) -> Result<String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    if size > MAX_FILE_SIZE {
        bail!("file too large: {size} bytes (limit {MAX_FILE_SIZE})");
    }
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut remaining = size;
    while remaining > 0 {
        let want = remaining.min(buf.len() as u64) as usize;
        let n = r.read(&mut buf[..want]).await?;
        if n == 0 {
            bail!("unexpected EOF after {} of {size} bytes", size - remaining);
        }
        hasher.update(&buf[..n]);
        w.write_all(&buf[..n]).await?;
        remaining -= n as u64;
        if let Some(p) = progress {
            // 续传时进度要从已有字节数起算，否则进度条会从 0 重新跳到一半。
            p.store(base + (size - remaining), std::sync::atomic::Ordering::Relaxed);
        }
    }
    w.flush().await?;
    if let Some(p) = progress {
        p.store(base + size, std::sync::atomic::Ordering::Relaxed);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

// ---------------------------------------------------------------------------
// iroh 连接层
// ---------------------------------------------------------------------------

/// 只配一条自建 relay。token 必须只绑定到这个 `RelayConfig`，
/// 不能用 `RelayMap::with_auth_token` 全局套用（会给兜底的公共 relay 也带上 token）。
pub fn relay_map(relay_url: &str, token: &str) -> Result<RelayMap> {
    let url: RelayUrl = relay_url
        .parse()
        .map_err(|e| anyhow!("invalid relay URL {relay_url}: {e}"))?;
    let mut cfg = RelayConfig::from(url);
    if !token.is_empty() {
        cfg = cfg.with_auth_token(token.to_string());
    }
    Ok(RelayMap::from_iter([cfg]))
}

/// `NETDISK_RELAY_URL` 取这些值时改用 n0 官方公共基础设施。
///
/// 触发后等价于 iroh 的 `presets::N0`：
/// - relay 用 n0 官方的 4 个公共节点（亚太 / 欧洲 / 美东 / 美西），由 `net_report` 自动择优；
/// - 启用 `dns.iroh.link` 地址发现（Pkarr 发布 + DNS 解析），
///   因此客户端只需 `EndpointId` 就能找到服务端，不必手填 relay URL；
/// - 不需要 token（公共 relay 免费但有速率限制，见架构文档）。
pub const RELAY_N0: &str = "n0";

/// 是否走 n0 官方公共 relay。空值同样视为 n0（默认更省事的路径）。
pub fn is_n0_relay(relay_url: &str) -> bool {
    let v = relay_url.trim();
    v.is_empty() || v.eq_ignore_ascii_case(RELAY_N0) || v.eq_ignore_ascii_case("default")
}

/// 建 endpoint（临时密钥，每次启动换身份）。客户端与临时验证用这个。
pub async fn build_endpoint(relay_url: &str, token: &str) -> Result<Endpoint> {
    build_endpoint_with_secret(relay_url, token, None).await
}

/// 与 `build_endpoint` 相同，但可注入持久化的 `SecretKey`。
/// 服务端常驻必须用这个，否则每次重启 `EndpointId` 变化、所有客户端都要重新配对。
pub async fn build_endpoint_with_secret(
    relay_url: &str,
    token: &str,
    secret: Option<SecretKey>,
) -> Result<Endpoint> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut builder = if is_n0_relay(relay_url) {
        // presets::N0 自带 crypto provider、官方 relay 与 dns.iroh.link 地址发现，
        // 这里只需追加 ALPN 与（可选的）持久化密钥。
        Endpoint::builder(presets::N0)
    } else {
        let map = relay_map(relay_url, token)?;
        Endpoint::builder(presets::Empty)
            .crypto_provider(provider)
            .relay_mode(RelayMode::Custom(map))
    };
    builder = builder.alpns(vec![ALPN.to_vec()]);
    if let Some(key) = secret {
        builder = builder.secret_key(key);
    }
    let ep = builder.bind().await?;
    Ok(ep)
}

/// 读取持久化密钥；文件不存在时生成 32 字节 Ed25519 种子并以 0600 写入。
///
/// 这个文件等同于设备身份：丢了它，`EndpointId` 就变了，且旧数据仍属于旧身份。
/// 不做静态加密（D3 已确认），靠文件权限 + 目录权限保护。
pub fn load_or_create_secret(path: &Path) -> Result<SecretKey> {
    if path.exists() {
        let bytes = std::fs::read(path)?;
        if bytes.len() != 32 {
            bail!("secret file must be exactly 32 bytes, got {}", bytes.len());
        }
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&bytes);
        return Ok(SecretKey::from_bytes(&arr));
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let key = SecretKey::generate();
    let bytes = key.to_bytes();

    #[cfg(unix)]
    {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
    }
    #[cfg(not(unix))]
    std::fs::write(path, bytes)?;

    Ok(key)
}

/// 生成可交给客户端配对的 `EndpointAddr`（含 relay URL，不只是 EndpointId）。
/// iroh 1.4.1 的 `EndpointAddr` 实现了 serde，可直接序列化成 JSON 字符串分发。
///
/// n0 模式下不强行指定 relay：`presets::N0` 会把 `net_report` 选出的 home relay
/// 写进 `ep.addr()`，客户端也可只凭 EndpointId 经 `dns.iroh.link` 解析。
pub fn public_addr(ep: &Endpoint, relay_url: &str) -> Result<EndpointAddr> {
    let addr = ep.addr();
    if is_n0_relay(relay_url) {
        return Ok(addr);
    }
    let relay: RelayUrl = relay_url.parse()?;
    Ok(addr.with_relay_url(relay))
}

pub fn addr_to_json(addr: &EndpointAddr) -> Result<String> {
    Ok(serde_json::to_string(addr)?)
}

pub fn parse_addr(s: &str) -> Result<EndpointAddr> {
    serde_json::from_str(s).context("invalid EndpointAddr JSON")
}

/// 描述一条连接当前的传输路径，用来判断「是否已打洞直连」。
///
/// iroh 的典型行为是：先经 relay 建连，打洞成功后**新增**一条直连路径并切换过去，
/// relay 退回兜底。所以一个连接可能同时存在两条路径，`*` 标出当前实际承载数据的那个。
///
/// 输出示例：
///
/// ```text
/// relay* https://aps1-1.relay.n0.iroh.link./ rtt=48ms | direct  198.51.100.20:53135 rtt=51ms
/// ```
pub fn describe_paths(conn: &Connection) -> String {
    let paths = conn.paths();
    if paths.is_empty() {
        return "no open paths".to_string();
    }
    let mut parts = Vec::new();
    for p in paths.iter() {
        let kind = if p.is_relay() {
            "relay "
        } else if p.is_ip() {
            "direct"
        } else {
            "other "
        };
        let addr = match p.remote_addr() {
            TransportAddr::Ip(a) => a.to_string(),
            TransportAddr::Relay(url) => url.to_string(),
            other => format!("{other:?}"),
        };
        let mark = if p.is_selected() { "*" } else { " " };
        parts.push(format!(
            "{kind}{mark} {addr} rtt={}ms",
            p.rtt().as_millis()
        ));
    }
    parts.join(" | ")
}

/// 当前连接是否已有直连（IP）路径 —— 有的话说明打洞成功，数据不走 relay。
pub fn has_direct_path(conn: &Connection) -> bool {
    conn.paths().iter().any(|p| p.is_ip())
}

// ---------------------------------------------------------------------------
// 服务端本地存储（最小实现：目录扫描 + 路径防护）
// ---------------------------------------------------------------------------

/// 把客户端给的相对路径安全地映射到存储根目录下。
/// 拒绝绝对路径、`..`、`.` 以及任何非 Normal 组件。
pub fn safe_path(root: &Path, raw: &str) -> Result<PathBuf> {
    let rel = Path::new(raw);
    if rel.as_os_str().is_empty() {
        bail!("empty path");
    }
    if rel.is_absolute() {
        bail!("absolute path not allowed: {raw}");
    }
    let mut out = PathBuf::new();
    for c in rel.components() {
        match c {
            Component::Normal(s) => {
                let name = s.to_string_lossy();
                // 内部状态文件绝不能通过网盘协议被读取（身份私钥、临时文件等）。
                if name.starts_with('.')
                    || name == "secret.key"
                    || name.ends_with(".netdisk-tmp")
                {
                    bail!("internal or hidden file not accessible: {raw}");
                }
                out.push(s);
            }
            _ => bail!("path traversal not allowed: {raw}"),
        }
    }
    Ok(root.join(out))
}

/// 递归列出文件（同步实现；MVP 文件量小，后续换成 SQLite 索引）。
/// 回收站目录名。以 `.` 开头，因此 `safe_path` 与 `list_entries` 都会把它排除，
/// 用户既看不到、也无法通过协议直接访问。
pub const TRASH_DIR: &str = ".trash";

/// 把 `root/<rel>` 移入回收站，返回回收站内的相对路径。
///
/// **不是硬删**：文件仍在数据盘上，只是移出用户可见的树，符合架构 §5.3
/// 「用户主动删除走回收站」的约定。超过保留期后的真正清理留给后续阶段。
///
/// 同一秒内删除同名文件时会追加序号，避免覆盖之前删的同类文件。
pub fn move_to_trash(root: &Path, rel: &str) -> Result<String> {
    let src = safe_path(root, rel)?;
    let meta = std::fs::symlink_metadata(&src).with_context(|| format!("not found: {rel}"))?;
    if meta.is_dir() {
        bail!("refusing to delete a directory (delete its files one by one): {rel}");
    }

    let trash_dir = root.join(TRASH_DIR);
    std::fs::create_dir_all(&trash_dir)?;

    let base = src
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_string());
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let mut candidate = format!("{stamp}-{base}");
    let mut n = 1;
    while trash_dir.join(&candidate).exists() {
        candidate = format!("{stamp}-{n}-{base}");
        n += 1;
    }

    std::fs::rename(&src, trash_dir.join(&candidate))?;
    Ok(format!("{TRASH_DIR}/{candidate}"))
}

/// 回收站条目的元信息。
///
/// `name` 是 `.trash` 里的真实文件名（带 `<unix秒>-` 前缀），`original` 是
/// 解析回去的原文件名。管理后台恢复时默认用 `original`，用户仍可改目标路径。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrashEntry {
    pub name: String,
    pub original: String,
    pub size: u64,
    /// 删除时间（unix 秒）。文件名前缀解析失败时为 0。
    pub deleted_at: u64,
}

/// 解析 `.trash/<stamp>-<n>-<base>` 里的时间戳与原文件名。
///
/// 已知歧义：原文件名本身以「数字-」开头时（如 `123-a.txt`），会被当成同秒序号，
/// 恢复出来的名字少一段。概率很低，而且恢复时可以手动改目标路径。
pub fn parse_trash_name(name: &str) -> (u64, String) {
    let Some((head, rest)) = name.split_once('-') else {
        return (0, name.to_string());
    };
    if head.len() != 10 || !head.bytes().all(|b| b.is_ascii_digit()) {
        return (0, name.to_string());
    }
    let Ok(stamp) = head.parse::<u64>() else {
        return (0, name.to_string());
    };
    if let Some((maybe_seq, tail)) = rest.split_once('-') {
        if !maybe_seq.is_empty()
            && maybe_seq.bytes().all(|b| b.is_ascii_digit())
            && !tail.is_empty()
        {
            return (stamp, tail.to_string());
        }
    }
    (stamp, rest.to_string())
}

/// 列出回收站里的文件（不递归；`move_to_trash` 只放单层文件）。
pub fn list_trash(root: &Path) -> Result<Vec<TrashEntry>> {
    let dir = root.join(TRASH_DIR);
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let (deleted_at, original) = parse_trash_name(&name);
        out.push(TrashEntry {
            name,
            original,
            size: meta.len(),
            deleted_at,
        });
    }
    out.sort_by(|a, b| {
        b.deleted_at
            .cmp(&a.deleted_at)
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(out)
}

/// 校验并解析回收站条目路径。
///
/// 只接受单层文件名：拒绝分隔符与隐藏名，避免管理后台被用来读写 `.trash` 之外
/// 的任意路径（例如 `../secret.key`）。
fn trash_entry_path(root: &Path, name: &str) -> Result<std::path::PathBuf> {
    if name.is_empty() || name.contains('/') || name.contains('\\') || name.starts_with('.') {
        bail!("invalid trash entry: {name}");
    }
    let src = root.join(TRASH_DIR).join(name);
    if !src.is_file() {
        bail!("not found in trash: {name}");
    }
    Ok(src)
}

/// 从回收站恢复文件到 `target_rel`（相对数据根）。
///
/// `target_rel` 为空时用解析出的原名放到根目录。目标已存在时拒绝覆盖 ——
/// 后台点错一次不该毁掉现有文件；要覆盖就先手动改名或删掉目标。
pub fn restore_from_trash(root: &Path, trash_name: &str, target_rel: &str) -> Result<()> {
    let src = trash_entry_path(root, trash_name)?;
    let target = target_rel.trim();
    let target = if target.is_empty() {
        parse_trash_name(trash_name).1
    } else {
        target.to_string()
    };
    // safe_path 会拒绝绝对路径、`.` / `..` 与隐藏文件，避免写出数据根。
    let dst = safe_path(root, &target)?;
    if dst.exists() {
        bail!("target already exists: {target}");
    }
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::rename(&src, &dst)?;
    Ok(())
}

/// 彻底删除回收站里的单个文件（不可恢复）。
pub fn delete_trash_entry(root: &Path, name: &str) -> Result<()> {
    let src = trash_entry_path(root, name)?;
    std::fs::remove_file(src)?;
    Ok(())
}

/// 清理回收站。`older_than` 为 `None` 时清空全部，否则只删 mtime 早于该时长的
/// 文件（保留期策略用）。返回删除条数。
pub fn purge_trash(root: &Path, older_than: Option<std::time::Duration>) -> Result<u64> {
    let dir = root.join(TRASH_DIR);
    if !dir.exists() {
        return Ok(0);
    }
    let now = std::time::SystemTime::now();
    let mut removed = 0u64;
    for entry in std::fs::read_dir(&dir)? {
        let entry = entry?;
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        if let Some(age) = older_than {
            let modified = meta.modified().unwrap_or(now);
            let elapsed = now.duration_since(modified).unwrap_or_default();
            if elapsed < age {
                continue;
            }
        }
        std::fs::remove_file(entry.path())?;
        removed += 1;
    }
    Ok(removed)
}

/// 重命名 / 移动文件。
///
/// 目标已存在时报错而不是覆盖 —— 覆盖属于 `Put` 的语义（架构 D4 的 LWW），
/// 重命名不该成为「静默覆盖别人文件」的途径。
pub fn rename_entry(root: &Path, from: &str, to: &str) -> Result<()> {
    let src = safe_path(root, from)?;
    let dst = safe_path(root, to)?;
    if !src.exists() {
        bail!("not found: {from}");
    }
    if dst.exists() {
        bail!("target already exists: {to}");
    }
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::rename(&src, &dst)?;
    Ok(())
}

/// 复制文件。
///
/// 在服务端本地完成 `copy`，数据不经过网络 —— 相比「下载再上传」省掉两次全量传输。
/// 目标已存在时报错，与 [`rename_entry`] 保持一致的「不静默覆盖」语义。
pub fn copy_entry(root: &Path, from: &str, to: &str) -> Result<()> {
    let src = safe_path(root, from)?;
    let dst = safe_path(root, to)?;
    if !src.is_file() {
        bail!("not a file: {from}");
    }
    if dst.exists() {
        bail!("target already exists: {to}");
    }
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::copy(&src, &dst)?;
    Ok(())
}

/// 新建目录，支持多级（父目录自动创建）。目录已存在时不报错。
pub fn make_dir(root: &Path, rel: &str) -> Result<()> {
    let dir = safe_path(root, rel)?;
    std::fs::create_dir_all(&dir)?;
    Ok(())
}

/// 计算整个文件的 BLAKE3。
///
/// 续传场景专用：服务端只收到剩余部分，`copy_exact_with_hash` 返回的只是片段 hash，
/// 无法用于完整性校验，所以落盘前要把整个文件读一遍重算。
/// 代价是一次顺序读盘，换取「拼接错误能被发现」。
pub fn hash_file(path: &Path) -> Result<String> {
    use std::io::Read as _;
    let mut file = std::fs::File::open(path)
        .with_context(|| format!("cannot open {}", path.display()))?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

pub fn list_entries(root: &Path) -> Result<Vec<FileEntry>> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<FileEntry>) -> Result<()> {
        if !dir.exists() {
            return Ok(());
        }
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            // 隐藏文件、身份密钥、上传中的临时文件不对外暴露。
            if name.starts_with('.') || name == "secret.key" || name.ends_with(".netdisk-tmp") {
                continue;
            }
            let ft = entry.file_type()?;
            let rel = path
                .strip_prefix(base)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if ft.is_dir() {
                // 目录本身也要返回，否则空目录在列表里不存在。
                out.push(FileEntry {
                    path: rel,
                    size: 0,
                    is_dir: true,
                });
                walk(base, &path, out)?;
            } else if ft.is_file() {
                out.push(FileEntry {
                    path: rel,
                    size: entry.metadata()?.len(),
                    is_dir: false,
                });
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    walk(root, root, &mut out)?;
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}

#[cfg(test)]
mod trash_tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "netdisk-trash-test-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn parse_stamp_and_sequence() {
        assert_eq!(
            parse_trash_name("1763000000-a.txt"),
            (1763000000, "a.txt".to_string())
        );
        // 同秒冲突的序号要剥掉
        assert_eq!(
            parse_trash_name("1763000000-2-b.txt"),
            (1763000000, "b.txt".to_string())
        );
        // 原名里的连字符要保留
        assert_eq!(
            parse_trash_name("1763000000-a-b.txt"),
            (1763000000, "a-b.txt".to_string())
        );
        // 没有合法时间戳前缀时整体当成原名
        assert_eq!(parse_trash_name("a.txt"), (0, "a.txt".to_string()));
    }

    #[test]
    fn move_list_restore_roundtrip() {
        let root = temp_root("roundtrip");
        std::fs::create_dir_all(root.join("docs")).unwrap();
        std::fs::write(root.join("docs/report.txt"), b"hello").unwrap();

        let trash = move_to_trash(&root, "docs/report.txt").unwrap();
        assert!(trash.starts_with(".trash/"));
        assert!(!root.join("docs/report.txt").exists());

        let items = list_trash(&root).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].original, "report.txt");
        assert_eq!(items[0].size, 5);

        restore_from_trash(&root, &items[0].name, "docs/report.txt").unwrap();
        assert_eq!(
            std::fs::read(root.join("docs/report.txt")).unwrap(),
            b"hello"
        );
        assert!(list_trash(&root).unwrap().is_empty());

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn restore_refuses_overwrite() {
        let root = temp_root("overwrite");
        std::fs::write(root.join("a.txt"), b"new").unwrap();
        let trash = move_to_trash(&root, "a.txt").unwrap();
        let name = std::path::Path::new(&trash)
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        std::fs::write(root.join("a.txt"), b"existing").unwrap();

        let err = restore_from_trash(&root, &name, "a.txt")
            .unwrap_err()
            .to_string();
        assert!(err.contains("already exists"), "{err}");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn purge_can_be_limited_by_age() {
        let root = temp_root("purge");
        std::fs::write(root.join("old.txt"), b"x").unwrap();
        std::fs::write(root.join("new.txt"), b"y").unwrap();
        move_to_trash(&root, "old.txt").unwrap();
        move_to_trash(&root, "new.txt").unwrap();

        // 只清「1 小时前」的：刚放进去的不该被删
        let removed = purge_trash(&root, Some(std::time::Duration::from_secs(3600))).unwrap();
        assert_eq!(removed, 0);
        assert_eq!(list_trash(&root).unwrap().len(), 2);

        // 清空全部
        let removed = purge_trash(&root, None).unwrap();
        assert_eq!(removed, 2);
        assert!(list_trash(&root).unwrap().is_empty());

        std::fs::remove_dir_all(&root).ok();
    }
}

#[cfg(test)]
mod protocol_compat_tests {
    use super::*;

    #[test]
    fn old_put_without_offset_is_accepted() {
        let r: Request =
            serde_json::from_str(r#"{"Put":{"path":"a.bin","size":10}}"#).unwrap();
        assert!(matches!(
            r,
            Request::Put { offset: None, size: 10, .. }
        ));
    }

    #[test]
    fn new_put_with_offset_is_accepted() {
        let r: Request =
            serde_json::from_str(r#"{"Put":{"path":"a.bin","size":10,"offset":5}}"#).unwrap();
        assert!(matches!(r, Request::Put { offset: Some(5), .. }));
    }

    #[test]
    fn ready_parser_accepts_old_and_new_shapes() {
        let legacy = serde_json::json!("Ready");
        assert_eq!(parse_ready_value(&legacy).unwrap(), 0);

        let current = serde_json::json!({"Ready": {"offset": 524288}});
        assert_eq!(parse_ready_value(&current).unwrap(), 524288);
    }

    #[test]
    fn legacy_ready_string_is_a_unit_variant() {
        // 服务端给旧客户端回的就是这个形状：unit variant 序列化成裸字符串。
        #[derive(Debug, PartialEq, Deserialize)]
        enum OldResponse {
            Ready,
        }
        let frame = serde_json::to_vec(&"Ready").unwrap();
        let parsed: OldResponse = serde_json::from_slice(&frame).unwrap();
        assert_eq!(parsed, OldResponse::Ready);
    }

    #[test]
    fn new_put_serializes_offset_field() {
        // 事故复盘：旧 .so 发的 Put 没有 offset，新服务端直接拒绝。
        // 这条断言保证客户端确实把字段写进 JSON。
        let v = serde_json::to_value(Request::Put {
            path: "a.bin".into(),
            size: 10,
            offset: Some(0),
        })
        .unwrap();
        assert_eq!(v["Put"]["offset"], 0, "Put 必须带上 offset 字段");
    }

    #[test]
    fn ready_parser_reports_server_refusal() {
        let v = serde_json::json!({"Error": "file too large"});
        let e = parse_ready_value(&v).unwrap_err();
        assert!(e.to_string().contains("file too large"));
    }
}
