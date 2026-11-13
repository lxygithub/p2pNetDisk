//! C ABI 层：把 `netdisk-core` 的能力导出给 Dart `dart:ffi`。
//!
//! 设计取舍：
//! - 所有导出函数都是**同步**的，内部用单个全局 tokio runtime 驱动 iroh 的异步 API；
//! - 返回值统一是 `Response` 的 JSON 字符串（`{"Pong":null}` / `{"Entries":{...}}` /
//!   `{"Error":"..."}` …），Dart 侧 `jsonDecode` 后按顶层 key 分派；
//! - 字符串由 Rust 分配，必须由 Dart 调 `netdisk_string_free` 释放；
//! - `netdisk_init` 失败返回 null，详情用 `netdisk_last_error` 取。
//!
//! 这一层刻意不含 UI 逻辑，也不做平台特定处理；Android 的 JNI Context 初始化与
//! .so 打包属于 P0-2 的验证范围。

use std::{
    ffi::{c_char, CStr, CString},
    sync::{LazyLock, Mutex},
};

use anyhow::{anyhow, Context, Result};
use iroh::{endpoint::Connection, Endpoint, EndpointAddr};
use netdisk_core::{
    build_endpoint, copy_exact_with_hash_progress, describe_paths, has_direct_path, hash_file,
    parse_addr, read_frame, read_put_ready, write_frame, Request, Response, ALPN,
};
use tokio::runtime::Runtime;

static RT: LazyLock<Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("failed to build tokio runtime")
});

static LAST_ERROR: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new(String::new()));

fn set_error(msg: &str) {
    if let Ok(mut guard) = LAST_ERROR.lock() {
        *guard = msg.to_string();
    }
}

pub struct Handle {
    ep: Endpoint,
    addr: EndpointAddr,
    /// 复用的长连接。
    ///
    /// 之前的实现每条命令都 `ep.connect()` 一次，代价有两个：
    /// 1. 每次都要重新握手（跨网 1–2 秒），列表刷新体感很慢；
    /// 2. 连接活不过 1 秒，NAT 打洞根本来不及完成，`paths()` 永远只看到 relay。
    /// 现在改成复用一条连接（按需重连），打洞能在几秒内完成，后续命令走直连。
    conn: Mutex<Option<Connection>>,
    /// 串行化「首次建连」。
    ///
    /// 客户端最多 5 个传输并发，若都看到空缓存就会各建一条连接（多余且浪费握手）。
    /// 这里用双检锁：快路径只碰 std Mutex，慢路径才排队建连。
    connect_lock: tokio::sync::Mutex<()>,
}

impl Handle {
    /// 取一条可用连接：优先复用，失效则重建。
    async fn connection(&self) -> Result<Connection> {
        if let Some(c) = self.cached_conn() {
            return Ok(c);
        }
        // 双重检查：拿到建连锁后可能已被别的任务建好。
        let _guard = self.connect_lock.lock().await;
        if let Some(c) = self.cached_conn() {
            return Ok(c);
        }
        let conn = self.ep.connect(self.addr.clone(), ALPN).await?;
        if let Ok(mut guard) = self.conn.lock() {
            *guard = Some(conn.clone());
        }
        Ok(conn)
    }

    /// 快速路径：只短暂持有 std Mutex，不参与异步等待。
    fn cached_conn(&self) -> Option<Connection> {
        let guard = self.conn.lock().ok()?;
        match guard.as_ref() {
            Some(c) if c.close_reason().is_none() => Some(c.clone()),
            _ => None,
        }
    }

    fn drop_conn(&self) {
        if let Ok(mut guard) = self.conn.lock() {
            *guard = None;
        }
    }
}

unsafe fn take_str(p: *const c_char, name: &str) -> Result<String> {
    if p.is_null() {
        return Err(anyhow!("{name} is null"));
    }
    Ok(CStr::from_ptr(p).to_string_lossy().into_owned())
}

fn to_cstring(text: String) -> *mut c_char {
    CString::new(text)
        .unwrap_or_else(|_| CString::new("{\"Error\":\"invalid string\"}").unwrap())
        .into_raw()
}

fn result_to_ptr(r: Result<String>) -> *mut c_char {
    match r {
        Ok(s) => to_cstring(s),
        Err(e) => {
            let msg = format!("{e:#}");
            set_error(&msg);
            to_cstring(format!("{{\"Error\":{}}}", serde_json::to_string(&msg).unwrap()))
        }
    }
}

fn handle_ref(h: *mut Handle) -> Result<&'static Handle> {
    // 生命周期由调用方保证：netdisk_close 之前 handle 必须有效。
    unsafe { h.as_ref() }.context("null or invalid handle")
}

/// 建立 endpoint。返回 null 表示失败（用 netdisk_last_error 取原因）。
#[no_mangle]
pub extern "C" fn netdisk_init(
    relay_url: *const c_char,
    token: *const c_char,
    server_addr: *const c_char,
) -> *mut Handle {
    let r: Result<Handle> = (|| {
        let relay = unsafe { take_str(relay_url, "relay_url")? };
        let token = unsafe { take_str(token, "token")? };
        let addr_json = unsafe { take_str(server_addr, "server_addr")? };
        let addr = parse_addr(&addr_json)?;
        let ep = RT.block_on(build_endpoint(&relay, &token))?;
        Ok(Handle {
            ep,
            addr,
            conn: Mutex::new(None),
            connect_lock: tokio::sync::Mutex::new(()),
        })
    })();
    match r {
        Ok(h) => Box::into_raw(Box::new(h)),
        Err(e) => {
            set_error(&format!("{e:#}"));
            std::ptr::null_mut()
        }
    }
}

fn ping_inner(h: *mut Handle) -> Result<String> {
    let h = handle_ref(h)?;
    RT.block_on(async {
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, &Request::Ping).await?;
        let r: Response = read_frame(&mut recv).await?;
        Ok(serde_json::to_string(&r)?)
    })
}

fn list_inner(h: *mut Handle) -> Result<String> {
    let h = handle_ref(h)?;
    RT.block_on(async {
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, &Request::List).await?;
        let r: Response = read_frame(&mut recv).await?;
        Ok(serde_json::to_string(&r)?)
    })
}

fn delete_inner(h: *mut Handle, path: *const c_char) -> Result<String> {
    let h = handle_ref(h)?;
    let path = unsafe { take_str(path, "path")? };
    RT.block_on(async {
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, &Request::Delete { path }).await?;
        let r: Response = read_frame(&mut recv).await?;
        Ok(serde_json::to_string(&r)?)
    })
}

fn copy_inner(h: *mut Handle, from: *const c_char, to: *const c_char) -> Result<String> {
    let h = handle_ref(h)?;
    let from = unsafe { take_str(from, "from")? };
    let to = unsafe { take_str(to, "to")? };
    RT.block_on(async {
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, &Request::Copy { from, to }).await?;
        let r: Response = read_frame(&mut recv).await?;
        Ok(serde_json::to_string(&r)?)
    })
}

fn mkdir_inner(h: *mut Handle, path: *const c_char) -> Result<String> {
    let h = handle_ref(h)?;
    let path = unsafe { take_str(path, "path")? };
    RT.block_on(async {
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, &Request::Mkdir { path }).await?;
        let r: Response = read_frame(&mut recv).await?;
        Ok(serde_json::to_string(&r)?)
    })
}

fn rename_inner(h: *mut Handle, from: *const c_char, to: *const c_char) -> Result<String> {
    let h = handle_ref(h)?;
    let from = unsafe { take_str(from, "from")? };
    let to = unsafe { take_str(to, "to")? };
    RT.block_on(async {
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, &Request::Rename { from, to }).await?;
        let r: Response = read_frame(&mut recv).await?;
        Ok(serde_json::to_string(&r)?)
    })
}

fn put_inner(
    h: *mut Handle,
    remote: *const c_char,
    local: *const c_char,
    progress: *mut u64,
) -> Result<String> {
    let h = handle_ref(h)?;
    let remote = unsafe { take_str(remote, "remote")? };
    let local = unsafe { take_str(local, "local")? };
    RT.block_on(async {
        let size = std::fs::metadata(&local)
            .with_context(|| format!("cannot stat {local}"))?
            .len();
        // 不在这里做大小预检：决策点只放服务端一份，否则客户端常量和服务端
        // 一旦不同步又会变成「莫名其妙传不了」。服务端会在一个小的 Put 帧后
        // 立刻回 Error，代价只是一次往返。
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        // offset 只是「建议值」，真正的起点由服务端在 Ready 里给出。
        write_frame(
            &mut send,
            &Request::Put {
                path: remote.clone(),
                size,
                offset: Some(0),
            },
        )
        .await?;

        // 兼容旧服务端：它回的是裸字符串 "Ready"，read_put_ready 两种都认。
        let start = read_put_ready(&mut recv).await?;
        if start > size {
            return Err(anyhow!("server offset {start} exceeds file size {size}"));
        }

        let mut file = tokio::fs::File::open(&local).await?;
        if start > 0 {
            use tokio::io::AsyncSeekExt;
            file.seek(std::io::SeekFrom::Start(start)).await?;
        }
        let remaining = size - start;
        // 边传边算的 hash：start=0 时就是完整文件 hash，省掉一次全文件读盘。
        // 只有续传（只发了片段）才需要事后把整个文件重读一遍重算。
        let stream_hash = copy_exact_with_hash_progress(
            &mut file,
            &mut send,
            remaining,
            start,
            progress_ref(progress),
        )
        .await?;

        let r: Response = read_frame(&mut recv).await?;
        match &r {
            Response::Stored { hash: server_hash, .. } => {
                let expected = if start == 0 {
                    stream_hash
                } else {
                    let local_for_hash = local.clone();
                    tokio::task::spawn_blocking(move || {
                        hash_file(std::path::Path::new(&local_for_hash))
                    })
                    .await??
                };
                if *server_hash != expected {
                    return Err(anyhow!(
                        "hash mismatch: local={expected} server={server_hash}"
                    ));
                }
            }
            _ => {}
        }
        Ok(serde_json::to_string(&r)?)
    })
}

fn get_inner(
    h: *mut Handle,
    remote: *const c_char,
    local: *const c_char,
    progress: *mut u64,
) -> Result<String> {
    let h = handle_ref(h)?;
    let remote = unsafe { take_str(remote, "remote")? };
    let local = unsafe { take_str(local, "local")? };
    RT.block_on(async {
        if let Some(parent) = std::path::Path::new(&local).parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = h.connection().await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        write_frame(&mut send, &Request::Get { path: remote.clone() }).await?;
        let r: Response = read_frame(&mut recv).await?;
        let size = match r {
            Response::File { size } => size,
            Response::Error(e) => return Err(anyhow!("server: {e}")),
            _ => return Err(anyhow!("unexpected response to Get")),
        };
        let mut file = tokio::fs::File::create(&local).await?;
        let hash =
            copy_exact_with_hash_progress(&mut recv, &mut file, size, 0, progress_ref(progress))
                .await?;
        Ok(format!(
            "{{\"Downloaded\":{{\"size\":{size},\"hash\":\"{hash}\"}}}}"
        ))
    })
}

/// 把 C 传入的 `u64*` 当作原子计数器，用于跨语言读取传输进度。
///
/// `AtomicU64` 与 `u64` 的内存布局一致（8 字节、8 字节对齐）：调用方用
/// `malloc(sizeof(uint64_t))` 分配，Rust 写入已传输字节数，Dart 侧轮询读取。
fn progress_ref<'a>(p: *mut u64) -> Option<&'a std::sync::atomic::AtomicU64> {
    if p.is_null() {
        None
    } else {
        Some(unsafe { &*(p as *const std::sync::atomic::AtomicU64) })
    }
}

/// 统一的收尾：失败时清掉缓存的连接，让下一次调用重新握手。
///
/// 否则一条半死的连接会被反复复用，表现为「一直超时但重连就能好」。
fn finish(h: *mut Handle, r: Result<String>) -> *mut c_char {
    if r.is_err() && !h.is_null() {
        unsafe { &*h }.drop_conn();
    }
    result_to_ptr(r)
}

#[no_mangle]
pub extern "C" fn netdisk_ping(h: *mut Handle) -> *mut c_char {
    finish(h, ping_inner(h))
}

#[no_mangle]
pub extern "C" fn netdisk_list(h: *mut Handle) -> *mut c_char {
    finish(h, list_inner(h))
}

/// 带进度的上传。`progress` 指向一个由调用方分配的 `u64`，
/// Rust 在传输过程中持续写入「已发送字节数」，结束时等于文件大小。
#[no_mangle]
pub extern "C" fn netdisk_put_progress(
    h: *mut Handle,
    remote: *const c_char,
    local: *const c_char,
    progress: *mut u64,
) -> *mut c_char {
    finish(h, put_inner(h, remote, local, progress))
}

/// 带进度的下载。语义同 [`netdisk_put_progress`]。
#[no_mangle]
pub extern "C" fn netdisk_get_progress(
    h: *mut Handle,
    remote: *const c_char,
    local: *const c_char,
    progress: *mut u64,
) -> *mut c_char {
    finish(h, get_inner(h, remote, local, progress))
}

/// 复制文件（服务端内部复制，不走网络）。
#[no_mangle]
pub extern "C" fn netdisk_copy(
    h: *mut Handle,
    from: *const c_char,
    to: *const c_char,
) -> *mut c_char {
    finish(h, copy_inner(h, from, to))
}

/// 新建目录（支持多级）。
#[no_mangle]
pub extern "C" fn netdisk_mkdir(h: *mut Handle, path: *const c_char) -> *mut c_char {
    finish(h, mkdir_inner(h, path))
}

/// 删除文件（移入服务端回收站，不是硬删）。
#[no_mangle]
pub extern "C" fn netdisk_delete(h: *mut Handle, path: *const c_char) -> *mut c_char {
    finish(h, delete_inner(h, path))
}

/// 重命名 / 移动文件；目标已存在时服务端会报错。
#[no_mangle]
pub extern "C" fn netdisk_rename(
    h: *mut Handle,
    from: *const c_char,
    to: *const c_char,
) -> *mut c_char {
    finish(h, rename_inner(h, from, to))
}

#[no_mangle]
pub extern "C" fn netdisk_put(
    h: *mut Handle,
    remote: *const c_char,
    local: *const c_char,
) -> *mut c_char {
    finish(h, put_inner(h, remote, local, std::ptr::null_mut()))
}

#[no_mangle]
pub extern "C" fn netdisk_get(
    h: *mut Handle,
    remote: *const c_char,
    local: *const c_char,
) -> *mut c_char {
    finish(h, get_inner(h, remote, local, std::ptr::null_mut()))
}

#[no_mangle]
pub extern "C" fn netdisk_last_error() -> *mut c_char {
    let s = LAST_ERROR
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    to_cstring(s)
}

/// 当前连接的传输路径描述。
///
/// 返回 `{"Paths":{"desc":"...","direct":true}}`；尚未建立连接时 `desc` 为
/// `no active connection`、`direct` 为 false。
///
/// UI 用它显示「直连 xx ms / 中继 xx ms」——用户有权知道数据有没有经过服务器。
#[no_mangle]
pub extern "C" fn netdisk_paths(h: *mut Handle) -> *mut c_char {
    let r: Result<String> = (|| {
        let h = handle_ref(h)?;
        let guard = h.conn.lock().map_err(|_| anyhow!("conn mutex poisoned"))?;
        match guard.as_ref() {
            Some(conn) => {
                let desc = describe_paths(conn);
                Ok(format!(
                    "{{\"Paths\":{{\"desc\":{},\"direct\":{}}}}}",
                    serde_json::to_string(&desc)?,
                    has_direct_path(conn)
                ))
            }
            None => Ok(
                "{\"Paths\":{\"desc\":\"no active connection\",\"direct\":false}}".to_string(),
            ),
        }
    })();
    result_to_ptr(r)
}

/// 释放 Rust 返回的字符串。
#[no_mangle]
pub unsafe extern "C" fn netdisk_string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

/// 动态库能力标记，用于排查「Flutter UI 已更新、但 .so 还是旧版」的错配。
///
/// 踩过的坑：UI 支持 `NETDISK_RELAY_URL=n0`，但 Android 打进 APK 的 `.so` 仍是旧版，
/// 于是 `n0` 被当成 URL 解析，报 `invalid relay URL n0`。
/// 客户端连接前调这个函数，若返回值里没有 `n0` 就应提示重新交叉编译。
#[no_mangle]
pub extern "C" fn netdisk_ffi_version() -> *mut c_char {
    to_cstring(format!(
        "netdisk-ffi {} (relay-modes: n0,custom; proto: {})",
        env!("CARGO_PKG_VERSION"),
        String::from_utf8_lossy(netdisk_core::ALPN)
    ))
}

/// 释放 handle（会 drop endpoint）。
#[no_mangle]
pub unsafe extern "C" fn netdisk_close(h: *mut Handle) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}
