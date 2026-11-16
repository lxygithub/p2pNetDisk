//! 服务端管理后台（HTTP）。
//!
//! 设计取舍：
//! - **默认只听 127.0.0.1**：管理面不该暴露公网。远程用 SSH 隧道
//!   （`ssh -L 8088:127.0.0.1:8088 user@host`）或反代加 TLS。
//! - **单 token 登录 + cookie session**（HttpOnly、SameSite=Strict），不做多用户：
//!   个人网盘没有角色模型，多用户只会增加攻击面。
//! - 页面是内联的单文件 HTML（无构建步骤），改样式只动 `admin.html`。
//! - 只做「看与修」：概览、回收站、只读文件浏览与下载；上传/删除仍走客户端协议。
//! - 所有文件系统操作都放进 `spawn_blocking`：`list_entries` 是同步递归，
//!   大目录直接跑在 async worker 上会把管理面自己卡死。

use std::{
    collections::{BTreeSet, HashMap},
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use netdisk_core::{
    delete_trash_entry, list_entries, list_trash, purge_trash, restore_from_trash, safe_path,
    TrashEntry, TRASH_DIR,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;

const SESSION_COOKIE: &str = "nd_admin";
const SESSION_TTL: Duration = Duration::from_secs(12 * 3600);
const VERSION: &str = env!("CARGO_PKG_VERSION");

pub struct AdminConfig {
    pub root: PathBuf,
    pub token: String,
    /// 打码前不处理的 EndpointId；管理面只在本机/隧道内可见，仍由前端默认打码展示。
    pub endpoint_id: Option<String>,
    pub relay: String,
    pub started_at: Instant,
    /// `serve` 里会更新为真实监听地址（传端口 0 时也能拿到实际值）。
    pub bind_addr: SocketAddr,
}

#[derive(Clone)]
struct AppState {
    cfg: Arc<AdminConfig>,
    sessions: Arc<tokio::sync::RwLock<HashMap<String, Instant>>>,
}

/// 读取或生成管理 token。
///
/// 优先 `NETDISK_ADMIN_TOKEN`，否则用数据目录下的 `.admin-token`（0600；
/// 以 `.` 开头，因此不会出现在网盘列表里，也无法通过 `safe_path` 访问）。
/// 自动生成时只打印路径，不打印明文。
pub fn load_or_create_token(data_dir: &Path) -> Result<String> {
    if let Ok(t) = std::env::var("NETDISK_ADMIN_TOKEN") {
        let t = t.trim().to_string();
        if t.len() >= 8 {
            return Ok(t);
        }
    }
    let path = data_dir.join(".admin-token");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let t = text.trim().to_string();
        if t.len() >= 8 {
            return Ok(t);
        }
    }
    let token = random_hex(24);
    std::fs::write(&path, &token).with_context(|| format!("write {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(token)
}

/// 绑定并后台运行管理服务，返回实际监听地址。
pub async fn run(addr: &str, mut cfg: AdminConfig) -> Result<SocketAddr> {
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("bind admin on {addr}"))?;
    let local = listener.local_addr()?;
    cfg.bind_addr = local;
    tokio::spawn(async move {
        if let Err(e) = serve(listener, cfg).await {
            eprintln!("[netdisk-admin] 服务异常退出: {e:#}");
        }
    });
    Ok(local)
}

async fn serve(listener: TcpListener, cfg: AdminConfig) -> Result<()> {
    let state = AppState {
        cfg: Arc::new(cfg),
        sessions: Arc::new(tokio::sync::RwLock::new(HashMap::new())),
    };
    let app = Router::new()
        .route("/", get(index))
        .route("/favicon.ico", get(|| async { StatusCode::NO_CONTENT }))
        .route("/api/login", post(login))
        .route("/api/logout", post(logout))
        .route("/api/overview", get(overview))
        .route("/api/trash", get(trash_list))
        .route("/api/trash/restore", post(trash_restore))
        .route("/api/trash/delete", post(trash_delete))
        .route("/api/trash/purge", post(trash_purge))
        .route("/api/files", get(files))
        .route("/api/download", get(download))
        .with_state(state);
    axum::serve(listener, app).await.context("admin server")
}

async fn index() -> Html<&'static str> {
    Html(include_str!("admin.html"))
}

// ---------------------------------------------------------------------------
// 鉴权
// ---------------------------------------------------------------------------

async fn is_authed(st: &AppState, headers: &HeaderMap) -> bool {
    let Some(raw) = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()) else {
        return false;
    };
    for part in raw.split(';') {
        let Some((k, v)) = part.trim().split_once('=') else {
            continue;
        };
        if k == SESSION_COOKIE {
            let sessions = st.sessions.read().await;
            return sessions.get(v).is_some_and(|exp| *exp > Instant::now());
        }
    }
    false
}

fn session_id(headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(header::COOKIE)?.to_str().ok()?;
    for part in raw.split(';') {
        let Some((k, v)) = part.trim().split_once('=') else {
            continue;
        };
        if k == SESSION_COOKIE {
            return Some(v.to_string());
        }
    }
    None
}

fn unauthorized() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(serde_json::json!({ "error": "未登录或会话已过期" })),
    )
        .into_response()
}

fn fail(status: StatusCode, message: impl std::fmt::Display) -> Response {
    (
        status,
        Json(serde_json::json!({ "error": message.to_string() })),
    )
        .into_response()
}

#[derive(Deserialize)]
struct LoginReq {
    token: String,
}

async fn login(State(st): State<AppState>, Json(req): Json<LoginReq>) -> Response {
    if !constant_eq(req.token.trim(), &st.cfg.token) {
        return fail(StatusCode::UNAUTHORIZED, "token 不正确");
    }
    let sid = random_hex(32);
    let now = Instant::now();
    {
        let mut sessions = st.sessions.write().await;
        sessions.retain(|_, exp| *exp > now);
        sessions.insert(sid.clone(), now + SESSION_TTL);
    }
    let cookie = format!(
        "{SESSION_COOKIE}={sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age={}",
        SESSION_TTL.as_secs()
    );
    (
        [(header::SET_COOKIE, cookie)],
        Json(serde_json::json!({ "ok": true })),
    )
        .into_response()
}

async fn logout(State(st): State<AppState>, headers: HeaderMap) -> Response {
    if let Some(sid) = session_id(&headers) {
        st.sessions.write().await.remove(&sid);
    }
    let cookie = format!("{SESSION_COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0");
    (
        [(header::SET_COOKIE, cookie)],
        Json(serde_json::json!({ "ok": true })),
    )
        .into_response()
}

// ---------------------------------------------------------------------------
// 概览
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct Overview {
    version: &'static str,
    endpoint_id: Option<String>,
    relay: String,
    data_dir: String,
    bind_addr: String,
    /// 服务启动时间与已运行秒数，前端自己转本地时间。
    started_at: u64,
    uptime_secs: u64,
    disk_total: Option<u64>,
    disk_free: Option<u64>,
    file_count: usize,
    file_bytes: u64,
    trash_count: usize,
    trash_bytes: u64,
}

async fn overview(State(st): State<AppState>, headers: HeaderMap) -> Response {
    if !is_authed(&st, &headers).await {
        return unauthorized();
    }
    let root = st.cfg.root.clone();
    let stats = blocking(
        move || -> Result<(usize, u64, usize, u64, Option<(u64, u64)>)> {
            let entries = list_entries(&root)?;
            let mut file_count = 0usize;
            let mut file_bytes = 0u64;
            for e in &entries {
                if !e.is_dir {
                    file_count += 1;
                    file_bytes += e.size;
                }
            }
            let trash = list_trash(&root)?;
            let trash_count = trash.len();
            let trash_bytes: u64 = trash.iter().map(|t| t.size).sum();
            Ok((
                file_count,
                file_bytes,
                trash_count,
                trash_bytes,
                disk_space(&root),
            ))
        },
    )
    .await;

    let (file_count, file_bytes, trash_count, trash_bytes, disk) = match stats {
        Ok(v) => v,
        Err(e) => return fail(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")),
    };

    let uptime = st.cfg.started_at.elapsed();
    let started_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs().saturating_sub(uptime.as_secs()))
        .unwrap_or(0);

    Json(Overview {
        version: VERSION,
        endpoint_id: st.cfg.endpoint_id.clone(),
        relay: st.cfg.relay.clone(),
        data_dir: st.cfg.root.display().to_string(),
        bind_addr: st.cfg.bind_addr.to_string(),
        started_at,
        uptime_secs: uptime.as_secs(),
        disk_total: disk.map(|d| d.0),
        disk_free: disk.map(|d| d.1),
        file_count,
        file_bytes,
        trash_count,
        trash_bytes,
    })
    .into_response()
}

// ---------------------------------------------------------------------------
// 回收站
// ---------------------------------------------------------------------------

async fn trash_list(State(st): State<AppState>, headers: HeaderMap) -> Response {
    if !is_authed(&st, &headers).await {
        return unauthorized();
    }
    let root = st.cfg.root.clone();
    match blocking(move || list_trash(&root)).await {
        Ok(items) => Json::<Vec<TrashEntry>>(items).into_response(),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")),
    }
}

#[derive(Deserialize)]
struct RestoreReq {
    name: String,
    #[serde(default)]
    target: String,
}

async fn trash_restore(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<RestoreReq>,
) -> Response {
    if !is_authed(&st, &headers).await {
        return unauthorized();
    }
    let root = st.cfg.root.clone();
    match blocking(move || restore_from_trash(&root, &req.name, &req.target)).await {
        Ok(()) => Json(serde_json::json!({ "ok": true })).into_response(),
        Err(e) => fail(StatusCode::BAD_REQUEST, format!("{e:#}")),
    }
}

#[derive(Deserialize)]
struct NameReq {
    name: String,
}

async fn trash_delete(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<NameReq>,
) -> Response {
    if !is_authed(&st, &headers).await {
        return unauthorized();
    }
    let root = st.cfg.root.clone();
    match blocking(move || delete_trash_entry(&root, &req.name)).await {
        Ok(()) => Json(serde_json::json!({ "ok": true })).into_response(),
        Err(e) => fail(StatusCode::BAD_REQUEST, format!("{e:#}")),
    }
}

#[derive(Deserialize)]
struct PurgeReq {
    /// `null` = 全部清空；数字 = 只清该天数之前的。
    #[serde(default)]
    older_than_days: Option<u64>,
}

async fn trash_purge(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<PurgeReq>,
) -> Response {
    if !is_authed(&st, &headers).await {
        return unauthorized();
    }
    let root = st.cfg.root.clone();
    let age = req
        .older_than_days
        .map(|d| Duration::from_secs(d.saturating_mul(24 * 3600)));
    match blocking(move || purge_trash(&root, age)).await {
        Ok(removed) => Json(serde_json::json!({ "removed": removed })).into_response(),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")),
    }
}

// ---------------------------------------------------------------------------
// 文件浏览 / 下载
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct FilesQuery {
    #[serde(default)]
    dir: String,
}

#[derive(Serialize)]
struct FileItem {
    name: String,
    path: String,
    is_dir: bool,
    size: u64,
}

#[derive(Serialize)]
struct FilesResp {
    dir: String,
    items: Vec<FileItem>,
}

async fn files(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<FilesQuery>,
) -> Response {
    if !is_authed(&st, &headers).await {
        return unauthorized();
    }
    let root = st.cfg.root.clone();
    let dir = q.dir.clone();
    match blocking(move || list_dir(&root, &dir)).await {
        Ok(resp) => Json(resp).into_response(),
        Err(e) => fail(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")),
    }
}

/// 与客户端的目录视图保持同一套规则：目录在前、文件在后，各自按名字排序。
fn list_dir(root: &Path, dir: &str) -> Result<FilesResp> {
    let all = list_entries(root)?;
    let mut cwd = dir.trim().replace('\\', "/");
    cwd = cwd.trim_start_matches('/').to_string();
    if !cwd.is_empty() && !cwd.ends_with('/') {
        cwd.push('/');
    }

    let mut dir_names = BTreeSet::new();
    let mut items = Vec::new();
    for f in &all {
        let Some(rest) = f.path.strip_prefix(cwd.as_str()) else {
            continue;
        };
        if rest.is_empty() {
            continue;
        }
        if let Some(slash) = rest.find('/') {
            dir_names.insert(rest[..slash].to_string());
        } else if f.is_dir {
            dir_names.insert(rest.to_string());
        } else {
            items.push(FileItem {
                name: rest.to_string(),
                path: f.path.clone(),
                is_dir: false,
                size: f.size,
            });
        }
    }
    items.sort_by(|a, b| a.name.cmp(&b.name));

    let mut out: Vec<FileItem> = dir_names
        .into_iter()
        .map(|name| FileItem {
            path: format!("{cwd}{name}/"),
            name,
            is_dir: true,
            size: 0,
        })
        .collect();
    out.extend(items);
    Ok(FilesResp {
        dir: cwd,
        items: out,
    })
}

#[derive(Deserialize)]
struct DownloadQuery {
    path: String,
    /// `trash` 时 `path` 是回收站内的单层文件名。
    #[serde(default)]
    kind: String,
}

async fn download(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<DownloadQuery>,
) -> Response {
    if !is_authed(&st, &headers).await {
        return unauthorized();
    }
    let root = st.cfg.root.clone();
    let full = if q.kind == "trash" {
        let name = q.path.as_str();
        if name.is_empty() || name.contains('/') || name.contains('\\') || name.starts_with('.') {
            return fail(StatusCode::BAD_REQUEST, "非法的回收站条目");
        }
        root.join(TRASH_DIR).join(name)
    } else {
        match safe_path(&root, &q.path) {
            Ok(p) => p,
            Err(e) => return fail(StatusCode::BAD_REQUEST, format!("{e:#}")),
        }
    };

    let meta = match tokio::fs::metadata(&full).await {
        Ok(m) if m.is_file() => m,
        _ => return fail(StatusCode::NOT_FOUND, "文件不存在"),
    };
    let file = match tokio::fs::File::open(&full).await {
        Ok(f) => f,
        Err(e) => return fail(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")),
    };
    let name = full
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "download".to_string());

    let stream = tokio_util::io::ReaderStream::new(file);
    let mut resp = Body::from_stream(stream).into_response();
    let h = resp.headers_mut();
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    if let Ok(v) = HeaderValue::from_str(&meta.len().to_string()) {
        h.insert(header::CONTENT_LENGTH, v);
    }
    // RFC 5987：中文文件名必须走 filename*，否则会被截断或乱码。
    if let Ok(v) = HeaderValue::from_str(&format!(
        "attachment; filename*=UTF-8''{}",
        percent_encode(&name)
    )) {
        h.insert(header::CONTENT_DISPOSITION, v);
    }
    resp
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

async fn blocking<T, F>(f: F) -> Result<T>
where
    F: FnOnce() -> Result<T> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .context("文件操作线程异常")?
}

/// 定长比较，避免 token 校验被逐字节计时侧信道。
fn constant_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    diff == 0
}

fn random_hex(len: usize) -> String {
    let mut buf = vec![0u8; len];
    rand::thread_rng().fill_bytes(&mut buf);
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(unix)]
fn disk_space(path: &Path) -> Option<(u64, u64)> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let block = st.f_frsize as u64;
    Some((st.f_blocks as u64 * block, st.f_bavail as u64 * block))
}

#[cfg(not(unix))]
fn disk_space(_path: &Path) -> Option<(u64, u64)> {
    // Windows 上只用于本地开发，容量信息留空即可。
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn spawn_admin(root: PathBuf) -> (SocketAddr, String) {
        let token = "test-token-123456".to_string();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let cfg = AdminConfig {
            root,
            token: token.clone(),
            endpoint_id: Some("test-endpoint".into()),
            relay: "n0".into(),
            started_at: Instant::now(),
            bind_addr: addr,
        };
        tokio::spawn(async move {
            let _ = serve(listener, cfg).await;
        });
        (addr, token)
    }

    /// 返回 (状态码, 响应体, Set-Cookie 的第一段)。
    async fn http_call(
        addr: SocketAddr,
        method: &str,
        path: &str,
        body: Option<&str>,
        cookie: Option<&str>,
    ) -> (u16, String, String) {
        let payload = body.unwrap_or("");
        let mut req =
            format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n");
        if let Some(c) = cookie {
            req.push_str(&format!("Cookie: {c}\r\n"));
        }
        if body.is_some() {
            req.push_str("Content-Type: application/json\r\n");
            req.push_str(&format!("Content-Length: {}\r\n", payload.len()));
        }
        req.push_str("\r\n");
        req.push_str(payload);

        let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
        stream.write_all(req.as_bytes()).await.unwrap();
        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).await.unwrap();
        let text = String::from_utf8_lossy(&buf).to_string();
        let status = text
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let (head, body) = text.split_once("\r\n\r\n").unwrap_or((text.as_str(), ""));
        let cookie_hdr = head
            .lines()
            .find(|l| l.to_ascii_lowercase().starts_with("set-cookie:"))
            .map(|l| {
                l[11..]
                    .trim()
                    .split(';')
                    .next()
                    .unwrap_or_default()
                    .to_string()
            })
            .unwrap_or_default();
        (status, body.to_string(), cookie_hdr)
    }

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "netdisk-admin-test-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[tokio::test]
    async fn api_requires_login_then_accepts_valid_token() {
        let root = temp_root("auth");
        std::fs::write(root.join("a.txt"), b"hello").unwrap();
        let (addr, token) = spawn_admin(root.clone()).await;

        let (status, _, _) = http_call(addr, "GET", "/api/overview", None, None).await;
        assert_eq!(status, 401);

        let (status, _, _) = http_call(
            addr,
            "POST",
            "/api/login",
            Some(r#"{"token":"wrong-token-xxxx"}"#),
            None,
        )
        .await;
        assert_eq!(status, 401);

        let payload = format!(r#"{{"token":"{token}"}}"#);
        let (status, _, cookie) = http_call(addr, "POST", "/api/login", Some(&payload), None).await;
        assert_eq!(status, 200);
        assert!(cookie.starts_with("nd_admin="), "{cookie}");

        let (status, body, _) = http_call(addr, "GET", "/api/overview", None, Some(&cookie)).await;
        assert_eq!(status, 200);
        assert!(body.contains("data_dir"), "{body}");

        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn trash_can_be_listed_and_restored() {
        let root = temp_root("trash");
        std::fs::write(root.join("gone.txt"), b"bye").unwrap();
        netdisk_core::move_to_trash(&root, "gone.txt").unwrap();
        let (addr, token) = spawn_admin(root.clone()).await;

        let payload = format!(r#"{{"token":"{token}"}}"#);
        let (_, _, cookie) = http_call(addr, "POST", "/api/login", Some(&payload), None).await;

        let (status, body, _) = http_call(addr, "GET", "/api/trash", None, Some(&cookie)).await;
        assert_eq!(status, 200);
        assert!(body.contains("gone.txt"), "{body}");

        let name = netdisk_core::list_trash(&root).unwrap()[0].name.clone();
        let payload = format!(r#"{{"name":"{name}","target":"restored.txt"}}"#);
        let (status, body, _) = http_call(
            addr,
            "POST",
            "/api/trash/restore",
            Some(&payload),
            Some(&cookie),
        )
        .await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(std::fs::read(root.join("restored.txt")).unwrap(), b"bye");

        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn index_serves_admin_page() {
        let root = temp_root("index");
        let (addr, _) = spawn_admin(root.clone()).await;
        let (status, body, _) = http_call(addr, "GET", "/", None, None).await;
        assert_eq!(status, 200);
        let head: String = body.chars().take(300).collect();
        assert!(body.contains("p2pNetDisk 管理后台"), "{head}");
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn download_rejects_path_traversal() {
        let root = temp_root("download");
        let (addr, token) = spawn_admin(root.clone()).await;
        let payload = format!(r#"{{"token":"{token}"}}"#);
        let (_, _, cookie) = http_call(addr, "POST", "/api/login", Some(&payload), None).await;

        let (status, _, _) = http_call(
            addr,
            "GET",
            "/api/download?path=../secret.key",
            None,
            Some(&cookie),
        )
        .await;
        assert_eq!(status, 400);

        std::fs::remove_dir_all(&root).ok();
    }
}
