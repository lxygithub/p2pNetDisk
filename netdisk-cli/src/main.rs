//! `netdisk-cli` —— 用来验证端到端闭环的最小客户端。
//!
//! 它不是产品 UI，但和将来的 Flutter 客户端共用 `netdisk-core`，
//! 因此「连上服务端 / 列目录 / 上传 / 下载」这条链路一旦跑通，
//! Flutter 侧只需要把这层能力通过 FFI 暴露出去。

use std::{env, path::PathBuf, time::Duration};

use anyhow::{bail, Context, Result};
use iroh::{endpoint::Connection, EndpointAddr};
use netdisk_core::{
    build_endpoint, copy_exact_with_hash, describe_paths, has_direct_path, parse_addr, read_frame,
    write_frame, Request, Response, ALPN, DEFAULT_RELAY_URL,
};

fn usage() -> String {
    "usage: netdisk-cli <ping|list|put <local> <remote>|get <remote> <local>|delete <remote>|rename <from> <to>>"
        .to_string()
}

async fn run_command(conn: Connection, cmd: &[String]) -> Result<()> {
    let (mut send, mut recv) = conn.open_bi().await?;

    match cmd[0].as_str() {
        "ping" => {
            write_frame(&mut send, &Request::Ping).await?;
            let r: Response = read_frame(&mut recv).await?;
            match r {
                Response::Pong => {
                    println!("pong");
                    println!("path    : {}", describe_paths(&conn));
                    // 打洞是连接建立后异步并发尝试的，刚连上时通常只有 relay 路径。
                    // 给一个观察窗口，看是否新增直连路径并切换过去。
                    tokio::time::sleep(Duration::from_secs(4)).await;
                    println!("path+4s : {}", describe_paths(&conn));
                    println!(
                        "direct  : {}",
                        if has_direct_path(&conn) {
                            "YES（已打洞，应用数据走直连，不经 relay）"
                        } else {
                            "NO（仍在走 relay，NAT 打洞未成功）"
                        }
                    );
                }
                Response::Error(e) => bail!("server: {e}"),
                other => bail!("unexpected response: {other:?}"),
            }
        }

        "list" => {
            write_frame(&mut send, &Request::List).await?;
            let r: Response = read_frame(&mut recv).await?;
            match r {
                Response::Entries { entries } => {
                    if entries.is_empty() {
                        println!("(empty)");
                    }
                    for e in entries {
                        println!("{:>12}  {}", e.size, e.path);
                    }
                }
                Response::Error(e) => bail!("server: {e}"),
                other => bail!("unexpected response: {other:?}"),
            }
        }

        "put" => {
            if cmd.len() != 3 {
                bail!("{}", usage());
            }
            let local = PathBuf::from(&cmd[1]);
            let remote = cmd[2].clone();
            let size = std::fs::metadata(&local)
                .with_context(|| format!("cannot stat {}", local.display()))?
                .len();

            write_frame(&mut send, &Request::Put { path: remote.clone(), size }).await?;
            let r: Response = read_frame(&mut recv).await?;
            match r {
                Response::Ready => {}
                Response::Error(e) => bail!("server refused upload: {e}"),
                other => bail!("unexpected response: {other:?}"),
            }

            let mut file = tokio::fs::File::open(&local).await?;
            let local_hash = copy_exact_with_hash(&mut file, &mut send, size).await?;
            let r: Response = read_frame(&mut recv).await?;
            match r {
                Response::Stored { hash, size: n, path } => {
                    if hash != local_hash {
                        bail!("hash mismatch: local={local_hash} server={hash}");
                    }
                    println!("uploaded {path} ({n} bytes) blake3={hash}");
                }
                Response::Error(e) => bail!("server: {e}"),
                other => bail!("unexpected response: {other:?}"),
            }
        }

        "get" => {
            if cmd.len() != 3 {
                bail!("{}", usage());
            }
            let remote = cmd[1].clone();
            let local = PathBuf::from(&cmd[2]);
            if let Some(parent) = local.parent() {
                std::fs::create_dir_all(parent)?;
            }

            write_frame(&mut send, &Request::Get { path: remote.clone() }).await?;
            let r: Response = read_frame(&mut recv).await?;
            match r {
                Response::File { size } => {
                    let mut file = tokio::fs::File::create(&local).await?;
                    let hash = copy_exact_with_hash(&mut recv, &mut file, size).await?;
                    println!("downloaded {remote} -> {} ({size} bytes) blake3={hash}", local.display());
                }
                Response::Error(e) => bail!("server: {e}"),
                other => bail!("unexpected response: {other:?}"),
            }
        }

        "delete" => {
            if cmd.len() != 2 {
                bail!("{}", usage());
            }
            let remote = cmd[1].clone();
            write_frame(&mut send, &Request::Delete { path: remote.clone() }).await?;
            let r: Response = read_frame(&mut recv).await?;
            match r {
                Response::Deleted { trash, .. } => println!("deleted {remote} -> {trash}"),
                Response::Error(e) => bail!("server: {e}"),
                other => bail!("unexpected response: {other:?}"),
            }
        }

        "rename" => {
            if cmd.len() != 3 {
                bail!("{}", usage());
            }
            let from = cmd[1].clone();
            let to = cmd[2].clone();
            write_frame(
                &mut send,
                &Request::Rename {
                    from: from.clone(),
                    to: to.clone(),
                },
            )
            .await?;
            let r: Response = read_frame(&mut recv).await?;
            match r {
                Response::Renamed { .. } => println!("renamed {from} -> {to}"),
                Response::Error(e) => bail!("server: {e}"),
                other => bail!("unexpected response: {other:?}"),
            }
        }


        other => bail!("unknown command '{other}'. {}", usage()),
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let cmd: Vec<String> = env::args().skip(1).collect();
    if cmd.is_empty() {
        bail!("{}", usage());
    }

    let relay_url = env::var("NETDISK_RELAY_URL").unwrap_or_else(|_| DEFAULT_RELAY_URL.to_string());
    let token = env::var("NETDISK_RELAY_TOKEN").unwrap_or_default();
    let addr_raw = env::var("NETDISK_SERVER_ADDR").context("NETDISK_SERVER_ADDR not set")?;
    let addr: EndpointAddr = parse_addr(&addr_raw)?;

    if !netdisk_core::is_n0_relay(&relay_url) && token.is_empty() {
        bail!(
            "NETDISK_RELAY_TOKEN is required for a self-hosted relay \
             (set NETDISK_RELAY_URL=n0 to use the n0 public relays)"
        );
    }

    let ep = build_endpoint(&relay_url, &token).await?;

    // R14：家宽 -> 港服这条路径会间歇丢包，iroh 每次拨号有 10s 预算，
    // 这里在 endpoint 层再给几次机会，避免偶发握手失败直接判死。
    let mut last_error = None;
    let outcome = loop {
        let mut ok = None;
        for attempt in 1..=3 {
            match ep.connect(addr.clone(), ALPN).await {
                Ok(conn) => {
                    if attempt > 1 {
                        eprintln!("connected on attempt {attempt}");
                    }
                    ok = Some(run_command(conn, &cmd).await);
                    break;
                }
                Err(e) => {
                    eprintln!("connect attempt {attempt}/3 failed: {e:#}");
                    last_error = Some(e.to_string());
                    tokio::time::sleep(Duration::from_secs(2)).await;
                }
            }
        }
        match ok {
            Some(r) => break r,
            None => break Err(anyhow::anyhow!(
                "all connect attempts failed; last error: {}",
                last_error.unwrap_or_default()
            )),
        }
    };

    ep.close().await;
    outcome
}
