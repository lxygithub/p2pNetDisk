//! P0-1: 用真实 iroh endpoint 验证自建 relay。
//!
//! 验证三件事：
//!   1. 带非标准端口的 RelayUrl（https://host:8443）能被真实 endpoint 接受；
//!   2. 正确 token 能连、错误 token 被拒；
//!   3. 两端强制只走 relay（clear_ip_transports）时 echo 能往返，证明 relay 转发可用。
//!
//! 用法见同目录 README.md。

use std::{env, sync::Arc, time::Duration};

use anyhow::{anyhow, Result};
use iroh::{
    endpoint::{presets, Connection},
    protocol::{AcceptError, ProtocolHandler, Router},
    Endpoint, RelayConfig, RelayMap, RelayMode, RelayUrl,
};
use tokio::time::timeout;

const ALPN: &[u8] = b"netdisk/p0-1/echo/0";
const DEFAULT_RELAY: &str = "https://relay.example.com:8443";

fn relay_map(relay_url: &str, token: &str) -> Result<RelayMap> {
    let url: RelayUrl = relay_url
        .parse()
        .map_err(|e| anyhow!("invalid relay URL {relay_url}: {e}"))?;
    let mut cfg = RelayConfig::from(url);
    if !token.is_empty() {
        // token 只绑这一条 relay；绝不能用 RelayMap::with_auth_token 全局套用
        cfg = cfg.with_auth_token(token.to_string());
    }
    Ok(RelayMap::from_iter([cfg]))
}

async fn build(relay_url: &str, token: &str) -> Result<Endpoint> {
    // rustls 0.23 需要进程级默认 provider；同时显式传给 Builder，避免
    // "Missing or incompatible rustls crypto provider configured"。
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let _ = rustls::crypto::ring::default_provider().install_default();

    let map = relay_map(relay_url, token)?;
    let ep = Endpoint::builder(presets::Empty)
        .crypto_provider(provider)
        .relay_mode(RelayMode::Custom(map))
        // 两端都在本机时会优先直连，绕过 VPS；这里强制只保留 relay 传输，
        // 确保 echo 一定经过 relay.example.com:8443。
        .clear_ip_transports()
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await?;
    Ok(ep)
}

#[derive(Debug, Clone)]
struct Echo;

impl ProtocolHandler for Echo {
    async fn accept(&self, connection: Connection) -> std::result::Result<(), AcceptError> {
        println!("[accept] connection from {}", connection.remote_id());
        let (mut send, mut recv) = connection.accept_bi().await?;
        let n = tokio::io::copy(&mut recv, &mut send).await?;
        println!("[accept] echoed {n} bytes");
        send.finish()?;
        connection.closed().await;
        Ok(())
    }
}

/// 返回 true 表示 echo 成功往返。
async fn run_pair(relay_url: &str, token: &str) -> Result<bool> {
    let accept_ep = build(relay_url, token).await?;
    let router = Router::builder(accept_ep).accept(ALPN, Echo).spawn();
    // presets::Empty 清空了地址发现，addr() 只有 EndpointId。
    // 必须显式补上 home relay，否则 connect 报 "No addressing information"。
    // 这正是架构 §6.1「配对 ticket 要带含 relay URL 的 EndpointAddr」要验证的点。
    let relay: RelayUrl = relay_url
        .parse()
        .map_err(|e| anyhow!("invalid relay URL {relay_url}: {e}"))?;
    let addr = router.endpoint().addr().with_relay_url(relay);
    println!("[accept] addressing: 1 relay url, 0 ip addrs");

    let dial_ep = build(relay_url, token).await?;

    let result = timeout(Duration::from_secs(40), async {
        let conn = dial_ep.connect(addr, ALPN).await?;
        let (mut send, mut recv) = conn.open_bi().await?;
        send.write_all(b"p0-1 hello").await?;
        send.finish()?;
        let echoed = recv.read_to_end(64).await?;
        Ok::<Vec<u8>, anyhow::Error>(echoed)
    })
    .await;

    let ok = match result {
        Ok(Ok(echoed)) => {
            println!("[dial] received: {:?}", String::from_utf8_lossy(&echoed));
            echoed == b"p0-1 hello"
        }
        Ok(Err(e)) => {
            println!("[dial] failed: {e:#}");
            false
        }
        Err(_) => {
            println!("[dial] TIMEOUT after 40s");
            false
        }
    };

    dial_ep.close().await;
    let _ = router.shutdown().await;
    Ok(ok)
}

async fn run_online(relay_url: &str, token: &str) -> Result<bool> {
    let ep = build(relay_url, token).await?;
    let r = timeout(Duration::from_secs(20), ep.online()).await;
    ep.close().await;
    println!("[online] {}", if r.is_ok() { "OK" } else { "TIMEOUT" });
    Ok(r.is_ok())
}

#[tokio::main]
async fn main() -> Result<()> {
    // 可选诊断：只有显式设置 RUST_LOG 才装 subscriber，默认行为完全不变。
    // 例如 RUST_LOG=iroh=debug,iroh_relay=debug 可看到 home relay 与 net_report 的进展。
    if env::var_os("RUST_LOG").is_some() {
        tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
            .with_writer(std::io::stderr)
            .init();
    }

    let relay_url = env::var("RELAY_URL").unwrap_or_else(|_| DEFAULT_RELAY.to_string());
    let mode = env::var("MODE").unwrap_or_else(|_| "pair".to_string());
    let env_token = env::var("RELAY_TOKEN").unwrap_or_default();
    let token = if mode == "wrong" {
        "definitely-wrong-token".to_string()
    } else {
        env_token
    };

    println!("relay : {relay_url}");
    println!("mode  : {mode}");
    println!("token : {}", if token.is_empty() { "(none)" } else { "(set)" });
    println!("path  : relay-only (IP transports cleared)");
    if token.is_empty() && mode != "wrong" {
        println!("WARN  : RELAY_TOKEN 未设置，relay 可能拒绝连接");
    }

    let ok = match mode.as_str() {
        "pair" | "wrong" => run_pair(&relay_url, &token).await?,
        "online" => run_online(&relay_url, &token).await?,
        _ => return Err(anyhow!("MODE 只能是 pair | wrong | online")),
    };

    if mode == "wrong" {
        if ok {
            return Err(anyhow!("FAIL: 错误 token 竟然建立了连接"));
        }
        println!("PASS: 错误 token 被拒绝（符合预期）");
    } else if ok {
        if mode == "online" {
            println!("PASS: endpoint 经带端口 RelayUrl 成功上线");
        } else {
            println!("PASS: 带端口 RelayUrl + token + relay 转发全部可用");
        }
    } else {
        return Err(anyhow!("FAIL: echo 未成功往返"));
    }
    Ok(())
}
