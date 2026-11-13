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
/// MVP 单文件大小上限，防止误传超大文件把家用服务器磁盘打满。
pub const MAX_FILE_SIZE: u64 = 512 * 1024 * 1024;

// ---------------------------------------------------------------------------
// 协议
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Request {
    Ping,
    List,
    Put { path: String, size: u64 },
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
    /// 服务端已准备好接收 `Put` 的裸数据流。
    Ready,
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

/// 精确搬运 `size` 字节并计算 BLAKE3。
///
/// 刻意不依赖 EOF：同一条 QUIC 双向流上，数据之后还要继续读响应帧，
/// 所以必须按声明的长度读，而不是 `read_to_end`。
pub async fn copy_exact_with_hash<R, W>(r: &mut R, w: &mut W, size: u64) -> Result<String>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    copy_exact_with_hash_progress(r, w, size, None).await
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
            p.store(size - remaining, std::sync::atomic::Ordering::Relaxed);
        }
    }
    w.flush().await?;
    if let Some(p) = progress {
        p.store(size, std::sync::atomic::Ordering::Relaxed);
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
