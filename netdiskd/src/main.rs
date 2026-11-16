//! `netdiskd` —— 跑在家用 Linux 服务器上的最小网盘服务端。
//!
//! 启动后打印一行 `NETDISK_SERVER_ADDR=<JSON>`，把它交给客户端即可配对。
//! 当前密钥是每次启动随机生成的，重启后地址会变、需要重新配对（见 docs/RUNNING.md）。

use std::{env, path::PathBuf, sync::Arc};

use anyhow::{bail, Result};
use iroh::{
    endpoint::Connection,
    protocol::{AcceptError, ProtocolHandler, Router},
};
use netdisk_core::{
    addr_to_json, build_endpoint_with_secret, copy_exact_with_hash, describe_paths, list_entries,
    copy_entry, hash_file, load_or_create_secret, make_dir, move_dir_to_trash, move_to_trash,
    public_addr, read_frame, rename_entry, safe_path, write_frame, FileEntry, Request, Response,
    ALPN, DEFAULT_RELAY_URL, MAX_FILE_SIZE,
};
use tokio::io::{AsyncRead, AsyncWrite};

#[derive(Debug, Clone)]
struct Handler {
    root: Arc<PathBuf>,
}

impl ProtocolHandler for Handler {
    async fn accept(&self, connection: Connection) -> std::result::Result<(), AcceptError> {
        // 打印服务端视角的传输路径。
        //
        // 注意时机：accept 发生在连接刚建立时，那一刻通常只有 relay 路径 ——
        // 打洞是并发异步尝试的，要 1–4 秒才会新增 direct 路径并切换过去。
        // 所以这里除了初始快照，还在 4 秒后再打一次，否则会误判成「只走 relay」。
        println!(
            "[netdiskd] inbound connection, paths: {}",
            describe_paths(&connection)
        );
        {
            let conn = connection.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(4)).await;
                println!(
                    "[netdiskd] paths +4s: {} | direct={}",
                    describe_paths(&conn),
                    if netdisk_core::has_direct_path(&conn) {
                        "YES"
                    } else {
                        "NO"
                    }
                );
            });
        }
        // 一条 QUIC 连接上可以开多条流；每条流处理一个命令。
        //
        // 每条流 spawn 出去并发处理：批量上传小文件时不会互相排队。
        // 连接本身由这个 future 持有（iroh 会为每条连接单独 spawn 一个 task），
        // 所以这里**不能**提前返回 Ok(()) —— 那样连接会被 drop，客户端立刻 EOF。
        loop {
            let (send, recv) = match connection.accept_bi().await {
                Ok(pair) => pair,
                Err(_) => break, // 对端关闭连接
            };
            let root = self.root.clone();
            tokio::spawn(async move {
                if let Err(e) = handle_stream(send, recv, root).await {
                    eprintln!("[netdiskd] stream error: {e:#}");
                }
            });
        }
        Ok(())
    }
}

/// 返回 path 所在文件系统的可用字节数（普通用户实际能写的量）。
///
/// 固定 512MB 上限并不能真正防止打满磁盘 —— 盘剩 2G 时传 10 个 500MB
/// 一样会写满。改成按 `statvfs` 的 `f_bavail * f_frsize` 判断才对。
/// 查不到（非 Unix / 系统调用失败）时返回 None，表示「不拦」，不阻断正常上传。
#[cfg(unix)]
fn available_bytes(path: &std::path::Path) -> Option<u64> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let c = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    if rc != 0 {
        return None;
    }
    Some((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
}

#[cfg(not(unix))]
fn available_bytes(_path: &std::path::Path) -> Option<u64> {
    None
}

/// 用泛型承接 iroh 的 SendStream / RecvStream，避免绑定具体类型名。
async fn handle_stream<S, R>(mut send: S, mut recv: R, root: Arc<PathBuf>) -> Result<()>
where
    S: AsyncWrite + Unpin,
    R: AsyncRead + Unpin,
{
    let req: Request = match read_frame(&mut recv).await {
        Ok(r) => r,
        Err(e) => {
            // 客户端开流后立刻关闭属正常情况，不必刷错误日志。
            if e.downcast_ref::<std::io::Error>().is_some() {
                return Ok(());
            }
            // 格式/版本错误必须回一帧 Error：否则客户端只是读到 EOF，
            // 界面上会显示莫名其妙的「unexpected end of file」。
            let msg = format!("bad request: {e:#}");
            let _ = write_frame(&mut send, &Response::Error(msg)).await;
            return Err(e);
        }
    };

    let result: Result<()> = match req {
        Request::Ping => write_frame(&mut send, &Response::Pong).await,

        Request::List => {
            let entries: Vec<FileEntry> = list_entries(&root)?;
            write_frame(&mut send, &Response::Entries { entries }).await
        }

        Request::Put { path, size, offset } => {
            // 旧客户端没有 offset 字段：它不支持续传，会从头发完整文件。
            // 按旧协议回 Ready，让没升级的手机仍能正常上传。
            let legacy = offset.is_none();
            if size > MAX_FILE_SIZE {
                write_frame(
                    &mut send,
                    &Response::Error(format!(
                        "file too large: {size} bytes (limit {MAX_FILE_SIZE})"
                    )),
                )
                .await?;
                return Ok(());
            }
            let target = match safe_path(&root, &path) {
                Ok(p) => p,
                Err(e) => {
                    write_frame(&mut send, &Response::Error(e.to_string())).await?;
                    return Ok(());
                }
            };
            std::fs::create_dir_all(
                target
                    .parent()
                    .ok_or_else(|| anyhow::anyhow!("no parent dir"))?,
            )?;

            // 先写临时文件，完整接收并校验后才改名，避免半截文件被当成正式文件。
            // 这个临时文件同时充当断点续传的载体：连接断了它还在，下次接着写。
            // 注意用「追加后缀」而不是 with_extension：后者会替换原有扩展名，
            // 让 a.bin 与 a.txt 共用同一个临时文件（互相踩踏）。
            let tmp = {
                let mut os = target.clone().into_os_string();
                os.push(".netdisk-tmp");
                std::path::PathBuf::from(os)
            };
            let existing = std::fs::metadata(&tmp).map(|m| m.len()).unwrap_or(0);
            // 超过 24 小时的半截文件视为陈旧：可能是上次中断遗留，
            // 而客户端早已换成同名但内容不同的文件，接着写会拼出错文件。
            let stale = std::fs::metadata(&tmp)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .map(|d| d.as_secs() > 24 * 3600)
                .unwrap_or(false);

            if stale {
                let _ = std::fs::remove_file(&tmp);
                println!("[netdiskd] drop stale part {path} (older than 24h)");
            }

            // legacy 强制 start=0；下面的 File::create 会截断残留的 .part，
            // 所以旧客户端重传完整文件不会和半截内容拼在一起。
            let start = if !legacy && !stale && existing > 0 && existing <= size {
                existing
            } else {
                if existing > size {
                    // 残留的是另一个更大的文件，留着也没用。
                    let _ = std::fs::remove_file(&tmp);
                    println!("[netdiskd] discard stale part {path} ({existing} > {size})");
                }
                0
            };

            let remaining = size - start;

            // 固定上限只挡异常值，真正防止打满磁盘看可用空间。
            // 留 1GiB 给系统日志、回收站，别把盘写满导致服务自己挂掉。
            // 检查要在回 Ready 之前做：客户端会直接收到 Error，而不是传一半才断。
            const DISK_RESERVE: u64 = 1024 * 1024 * 1024;
            if let Some(free) = available_bytes(root.as_path()) {
                let usable = free.saturating_sub(DISK_RESERVE);
                if remaining > usable {
                    let msg = format!(
                        "not enough disk space: need {remaining} bytes, available {usable}"
                    );
                    println!("[netdiskd] reject {path}: {msg}");
                    write_frame(&mut send, &Response::Error(msg)).await?;
                    return Ok(());
                }
            }

            let mut file = if start > 0 {
                tokio::fs::OpenOptions::new()
                    .append(true)
                    .open(&tmp)
                    .await?
            } else {
                tokio::fs::File::create(&tmp).await?
            };

            // 告诉客户端实际从哪开始，它据此跳过已传部分。
            if legacy {
                // 旧客户端的 Response::Ready 是 unit variant，JSON 形态是裸字符串。
                write_frame(&mut send, &"Ready").await?;
                println!("[netdiskd] legacy client {path} (no resume)");
            } else {
                write_frame(&mut send, &Response::Ready { offset: start }).await?;
            }

            if start > 0 {
                println!("[netdiskd] resume {path} at {start} bytes ({remaining} left)");
            }
            let stream_hash = copy_exact_with_hash(&mut recv, &mut file, remaining).await?;
            file.sync_all().await?;
            drop(file);

            // start=0 时边收边算的就是完整文件 hash，直接用，省一次全文件读盘。
            // 只有续传（只收到片段）才需要事后重读整文件重算。
            let hash = if start == 0 {
                stream_hash
            } else {
                let tmp_for_hash = tmp.clone();
                tokio::task::spawn_blocking(move || hash_file(&tmp_for_hash)).await??
            };
            std::fs::rename(&tmp, &target)?;

            write_frame(
                &mut send,
                &Response::Stored {
                    path,
                    size,
                    hash: hash.clone(),
                },
            )
            .await?;
            println!("[netdiskd] stored {size} bytes, blake3={hash}");
            Ok(())
        }

        Request::Get { path } => {
            let target = match safe_path(&root, &path) {
                Ok(p) => p,
                Err(e) => {
                    write_frame(&mut send, &Response::Error(e.to_string())).await?;
                    return Ok(());
                }
            };
            let meta = match std::fs::metadata(&target) {
                Ok(m) => m,
                Err(_) => {
                    write_frame(
                        &mut send,
                        &Response::Error(format!("not found: {path}")),
                    )
                    .await?;
                    return Ok(());
                }
            };
            if !meta.is_file() {
                write_frame(
                    &mut send,
                    &Response::Error(format!("not a file: {path}")),
                )
                .await?;
                return Ok(());
            }
            let size = meta.len();
            write_frame(&mut send, &Response::File { size }).await?;
            let mut file = tokio::fs::File::open(&target).await?;
            let hash = copy_exact_with_hash(&mut file, &mut send, size).await?;
            println!("[netdiskd] sent {size} bytes, blake3={hash}");
            Ok(())
        }

        Request::Delete { path } => match move_to_trash(&root, &path) {
            Ok(trash) => {
                println!("[netdiskd] deleted {path} -> {trash}");
                write_frame(&mut send, &Response::Deleted { path, trash }).await
            }
            Err(e) => write_frame(&mut send, &Response::Error(e.to_string())).await,
        },

        Request::Rename { from, to } => match rename_entry(&root, &from, &to) {
            Ok(()) => {
                println!("[netdiskd] renamed {from} -> {to}");
                write_frame(&mut send, &Response::Renamed { from, to }).await
            }
            Err(e) => write_frame(&mut send, &Response::Error(e.to_string())).await,
        },

        Request::Copy { from, to } => match copy_entry(&root, &from, &to) {
            Ok(()) => {
                println!("[netdiskd] copied {from} -> {to}");
                write_frame(&mut send, &Response::Copied { from, to }).await
            }
            Err(e) => write_frame(&mut send, &Response::Error(e.to_string())).await,
        },

        Request::Mkdir { path } => match make_dir(&root, &path) {
            Ok(()) => {
                println!("[netdiskd] mkdir {path}");
                write_frame(&mut send, &Response::DirCreated { path }).await
            }
            Err(e) => write_frame(&mut send, &Response::Error(e.to_string())).await,
        },

        Request::RemoveDir { path } => match move_dir_to_trash(&root, &path) {
            Ok(trash) => {
                println!("[netdiskd] rmdir {path} -> {trash}");
                write_frame(&mut send, &Response::DirRemoved { path }).await
            }
            Err(e) => write_frame(&mut send, &Response::Error(e.to_string())).await,
        },
    };

    if let Err(e) = result {
        eprintln!("[netdiskd] command failed: {e:#}");
        // 尽力把错误回给客户端；若流已断就忽略。
        let _ = write_frame(&mut send, &Response::Error(e.to_string())).await;
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let relay_url = env::var("NETDISK_RELAY_URL").unwrap_or_else(|_| DEFAULT_RELAY_URL.to_string());
    let token = env::var("NETDISK_RELAY_TOKEN").unwrap_or_default();
    let data_dir = PathBuf::from(
        env::var("NETDISK_DATA_DIR").unwrap_or_else(|_| "./data".to_string()),
    );

    if !netdisk_core::is_n0_relay(&relay_url) && token.is_empty() {
        bail!(
            "NETDISK_RELAY_TOKEN is required when using a self-hosted relay \
             (set NETDISK_RELAY_URL=n0 to use the n0 public relays instead)"
        );
    }
    std::fs::create_dir_all(&data_dir)?;

    // 常驻服务必须固定身份：密钥落盘（0600），重启后 EndpointAddr 不变。
    let secret_path = env::var("NETDISK_SECRET_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| data_dir.join("secret.key"));
    let secret = load_or_create_secret(&secret_path)?;

    let ep = build_endpoint_with_secret(&relay_url, &token, Some(secret)).await?;
    let addr = public_addr(&ep, &relay_url)?;
    println!("NETDISK_SERVER_ADDR={}", addr_to_json(&addr)?);
    let n0 = netdisk_core::is_n0_relay(&relay_url);
    if n0 {
        println!("relay   : n0 public (aps1-1 / euc1-1 / use1-1 / usw1-1, auto-selected)");
        println!("lookup  : dns.iroh.link (publish + resolve)");
    } else {
        println!("relay   : {relay_url}");
    }
    println!("data_dir: {}", data_dir.display());
    println!("secret  : {}", secret_path.display());
    println!("ALPN    : {}", String::from_utf8_lossy(ALPN));
    println!("ready. copy NETDISK_SERVER_ADDR to the client, then Ctrl-C to stop.");
    println!("note    : identity persists across restarts; keep the secret file safe (0600).");

    // ---- 管理后台（默认只监听本机；远程走 SSH 隧道）----
    // `NETDISK_ADMIN_ADDR=off` 可关闭；改成 0.0.0.0:8088 会暴露到局域网，
    // 请自行加反代与 TLS，不要直接挂公网。
    let admin_addr =
        env::var("NETDISK_ADMIN_ADDR").unwrap_or_else(|_| "127.0.0.1:8088".to_string());
    let admin_addr = admin_addr.trim().to_string();
    if !matches!(admin_addr.as_str(), "" | "off" | "none" | "0") {
        // token 放在 secret 同目录（0700），与用户文件物理隔离。
        let token_dir = secret_path
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| data_dir.clone());
        match netdisk_admin::load_or_create_token(&token_dir) {
            Ok(token) => {
                let cfg = netdisk_admin::AdminConfig {
                    root: data_dir.clone(),
                    token,
                    endpoint_id: Some(addr.id.to_string()),
                    relay: relay_url.clone(),
                    started_at: std::time::Instant::now(),
                    bind_addr: "127.0.0.1:0".parse().expect("placeholder addr"),
                };
                match netdisk_admin::run(&admin_addr, cfg).await {
                    Ok(bound) => {
                        println!("admin   : http://{bound}/");
                        println!(
                            "admin   : token = NETDISK_ADMIN_TOKEN 或 {}",
                            token_dir.join(".admin-token").display()
                        );
                        println!(
                            "admin   : 远程访问 ssh -L {p}:127.0.0.1:{p} <user>@<host>",
                            p = bound.port()
                        );
                    }
                    Err(e) => eprintln!("[netdiskd] 管理后台未启动: {e:#}"),
                }
            }
            Err(e) => eprintln!("[netdiskd] 管理 token 初始化失败: {e:#}"),
        }
    }

    // n0 模式下 home relay 由 net_report 异步选出，刚 bind 时 addr 里可能还没有 relay。
    // 稍后再打印一次，便于客户端拿到带 relay 的完整地址。
    if n0 {
        let ep_late = ep.clone();
        let relay_for_log = relay_url.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(8)).await;
            if let Ok(late) = public_addr(&ep_late, &relay_for_log) {
                if let Ok(json) = addr_to_json(&late) {
                    println!("NETDISK_SERVER_ADDR_LATE={json}");
                }
            }
        });
    }

    let router = Router::builder(ep)
        .accept(ALPN, Handler {
            root: Arc::new(data_dir),
        })
        .spawn();

    tokio::signal::ctrl_c().await?;
    let _ = router.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod disk_tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn available_bytes_reports_real_free_space() {
        let free = available_bytes(std::path::Path::new("/tmp"))
            .expect("statvfs should work on the server");
        assert!(free > 0, "free space must be positive");
        // 只是 sanity check：/tmp 所在盘不应少于 1MB，避免单位换算写错
        // （f_bavail 是块数，必须乘 f_frsize）。
        assert!(free > 1024 * 1024, "unexpectedly small free space: {free}");
    }
}
