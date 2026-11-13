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
    load_or_create_secret, public_addr, read_frame, safe_path, write_frame, FileEntry, Request,
    Response, ALPN, DEFAULT_RELAY_URL, MAX_FILE_SIZE,
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
        loop {
            let (send, recv) = match connection.accept_bi().await {
                Ok(pair) => pair,
                Err(_) => break, // 对端关闭连接
            };
            if let Err(e) = handle_stream(send, recv, self.root.clone()).await {
                eprintln!("[netdiskd] stream error: {e:#}");
            }
        }
        Ok(())
    }
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
            return Err(e);
        }
    };

    let result: Result<()> = match req {
        Request::Ping => write_frame(&mut send, &Response::Pong).await,

        Request::List => {
            let entries: Vec<FileEntry> = list_entries(&root)?;
            write_frame(&mut send, &Response::Entries { entries }).await
        }

        Request::Put { path, size } => {
            if size > MAX_FILE_SIZE {
                write_frame(
                    &mut send,
                    &Response::Error(format!("file too large: {size} bytes")),
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
            let tmp = target.with_extension("netdisk-tmp");
            let mut file = tokio::fs::File::create(&tmp).await?;
            write_frame(&mut send, &Response::Ready).await?;
            let hash = copy_exact_with_hash(&mut recv, &mut file, size).await?;
            file.sync_all().await?;
            drop(file);
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
