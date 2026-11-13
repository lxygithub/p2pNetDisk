#!/usr/bin/env bash
# P0-pre 一键部署：在 VPS 上以 root 执行，自包含、不含任何凭据。
#
# 两种模式自动切换（关键差异在证书）：
#   standalone —— 80/443 空闲，relay 独占，RelayUrl = https://<hostname>
#                  cert_mode = LetsEncrypt，由内置 tokio-rustls-acme 用 TLS-ALPN-01 签发
#   nginx      —— 80/443 被 nginx 占用（有现网站点），RelayUrl = https://<hostname>:8443
#                  内置 ACME 的 TLS-ALPN-01 必须走 443，被 nginx 占用时必然失败
#                  （实测错误：tls: no application protocol / 429 rateLimited），
#                  因此改用 certbot --webroot (HTTP-01, 走 nginx 80) 签发，
#                  relay 用 cert_mode = Manual 读 /var/lib/iroh-relay/certs/default.{crt,key}。
#
# 源码依据：iroh-relay/client.rs::connect() 用 url.join() 构造拨号地址，保留显式端口；
#           RelayQuicConfig.port 独立于 HTTPS 端口（默认 7842）。
#
# 用法：
#   export RELAY_HOSTNAME=relay.example.com    # 必填，已解析到本机公网 IP
#   export ACME_EMAIL=admin@example.com             # 必填，certbot / ACME 联系邮箱
#   export RELAY_TOKEN=...                       # 可选；不填自动生成或复用已有值
#   export FORCE=1                              # 可选；远程非交互时跳过 DNS 确认
#   bash deploy-relay.sh
#
# 幂等：复用已有 token、覆盖配置与 unit、重启服务，不会换 token 导致客户端失联。
# 安全：不执行 ufw enable（可能切断 SSH）；不动现有 nginx 站点配置，只新增一个 server 块。

set -euo pipefail

VERSION="1.4.1"
ARCH="x86_64-unknown-linux-musl"
PKG="iroh-relay-v${VERSION}-${ARCH}.tar.gz"
URL="https://github.com/n0-computer/iroh/releases/download/v${VERSION}/${PKG}"
CERTDIR=/var/lib/iroh-relay/certs
WEBROOT=/var/www/certbot
HOOK=/etc/letsencrypt/renewal-hooks/deploy/iroh-relay.sh

: "${RELAY_HOSTNAME:?请设置 RELAY_HOSTNAME}"
: "${ACME_EMAIL:?请设置 ACME_EMAIL}"

ACME_HTTP_PORT="${ACME_HTTP_PORT:-8080}"
RELAY_HTTPS_PORT="${RELAY_HTTPS_PORT:-8443}"

echo "==> 0. 前置检查"
[ "$(id -u)" -eq 0 ] || { echo "请用 root 执行"; exit 1; }
for t in curl tar openssl systemctl ss; do command -v "$t" >/dev/null || { echo "缺少 $t"; exit 1; }; done

if [ -z "${RELAY_TOKEN:-}" ] && [ -f /etc/iroh/relay.toml ]; then
  RELAY_TOKEN="$(sed -n 's/^access.shared_token = \["\([^"]*\)".*/\1/p' /etc/iroh/relay.toml | head -1 || true)"
fi
RELAY_TOKEN="${RELAY_TOKEN:-$(openssl rand -hex 32)}"

echo "==> 1. DNS 预检"
LOCAL_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
RESOLVED="$(getent hosts "$RELAY_HOSTNAME" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
echo "    本机公网 IP : ${LOCAL_IP:-未知}"
echo "    域名解析    : ${RESOLVED:-无}"
if [ -n "$LOCAL_IP" ] && [[ "$RESOLVED" != *"$LOCAL_IP"* ]]; then
  echo "    警告：域名未解析到本机公网 IP，证书签发会失败" >&2
  if [ "${FORCE:-0}" != "1" ]; then
    read -r -p "    仍要继续? [y/N] " ans
    [ "$ans" = "y" ] || exit 1
  fi
fi

echo "==> 2. 端口检测与模式选择"
PORT80="$(ss -lntp 2>/dev/null | grep -E ':80[[:space:]]' || true)"
if [ -n "$PORT80" ]; then
  if echo "$PORT80" | grep -q 'nginx'; then
    MODE=nginx
    echo "    nginx 占用 80/443 → 共存模式（certbot HTTP-01 + Manual 证书，relay 走 8443）"
  else
    echo "    80 被非 nginx 进程占用，无法自动共存：" >&2
    echo "$PORT80" >&2
    exit 1
  fi
else
  MODE=standalone
  echo "    80/443 空闲 → 独占模式（内置 TLS-ALPN-01 签证书）"
fi

if [ "$MODE" = nginx ]; then
  HTTP_BIND="127.0.0.1:${ACME_HTTP_PORT}"
  HTTPS_BIND="[::]:${RELAY_HTTPS_PORT}"
  QUIC_BIND="[::]:7842"
  RELAY_URL="https://${RELAY_HOSTNAME}:${RELAY_HTTPS_PORT}"
  CERT_MODE=Manual
else
  HTTP_BIND="[::]:80"
  HTTPS_BIND="[::]:443"
  QUIC_BIND="[::]:7842"
  RELAY_URL="https://${RELAY_HOSTNAME}"
  CERT_MODE=LetsEncrypt
fi
echo "    RelayUrl = $RELAY_URL ; cert_mode = $CERT_MODE"

echo "==> 3. 获取预编译二进制（不在 1C1G 上现场编译 Rust）"
if [ -f "/tmp/$PKG" ]; then
  echo "    使用已存在的 /tmp/$PKG"
else
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "/tmp/$PKG" "$URL"; then
    echo "    GitHub release 下载失败。备用：本机下载 $URL 后上传到 /tmp/$PKG 再重跑。" >&2
    exit 1
  fi
fi
sha256sum "/tmp/$PKG" | tee /tmp/iroh-relay-asset.sha256
echo "    官方 release 未附校验和文件，以上 sha256 仅作留档。"
EXTRACT="$(mktemp -d)"
tar -xzf "/tmp/$PKG" -C "$EXTRACT"
BIN="$(find "$EXTRACT" -type f -name 'iroh-relay' | head -1 || true)"
[ -n "$BIN" ] || { echo "    包内未找到 iroh-relay 二进制"; exit 1; }
install -m 0755 "$BIN" /usr/local/bin/iroh-relay
/usr/local/bin/iroh-relay --version

echo "==> 4. 创建运行用户与目录"
if ! id -u iroh-relay >/dev/null 2>&1; then
  useradd --system --home /var/lib/iroh-relay --shell /usr/sbin/nologin iroh-relay
fi
install -d -m 0700 -o iroh-relay -g iroh-relay /var/lib/iroh-relay "$CERTDIR"
install -d -m 0755 /etc/iroh

echo "==> 5. 写配置 /etc/iroh/relay.toml"
cat > /etc/iroh/relay.toml <<EOF
access.shared_token = ["$RELAY_TOKEN"]

enable_relay = true
http_bind_addr = "$HTTP_BIND"
enable_quic_addr_discovery = true
enable_metrics = true
metrics_bind_addr = "127.0.0.1:9090"

[tls]
hostname = "$RELAY_HOSTNAME"
cert_mode = "$CERT_MODE"
contact = "$ACME_EMAIL"
prod_tls = true
cert_dir = "$CERTDIR"
https_bind_addr = "$HTTPS_BIND"
quic_bind_addr = "$QUIC_BIND"

[limits.client.rx]
bytes_per_second = 2000000
max_burst_bytes = 4000000
EOF
chown iroh-relay:iroh-relay /etc/iroh/relay.toml
chmod 0600 /etc/iroh/relay.toml

echo "==> 6. 安装 systemd unit"
cat > /etc/systemd/system/iroh-relay.service <<'UNIT'
[Unit]
Description=iroh relay server (self-hosted, P0-pre)
Documentation=https://github.com/n0-computer/iroh/tree/main/iroh-relay
After=network-online.target
Wants=network-online.target
AssertPathExists=/etc/iroh/relay.toml

[Service]
Type=simple
User=iroh-relay
Group=iroh-relay
ExecStart=/usr/local/bin/iroh-relay --config-path /etc/iroh/relay.toml
WorkingDirectory=/var/lib/iroh-relay
StateDirectory=iroh-relay
StateDirectoryMode=0700
Environment=RUST_LOG=info
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=/var/lib/iroh-relay

[Install]
WantedBy=multi-user.target
UNIT

echo "==> 7. 证书与 nginx 共存配置"
if [ "$MODE" = nginx ]; then
  command -v nginx >/dev/null || { echo "    未找到 nginx"; exit 1; }
  command -v certbot >/dev/null || { echo "    缺少 certbot，请先安装（apt install certbot）"; exit 1; }

  install -d -m 0755 "$WEBROOT"
  NGINX_CONF=/etc/nginx/sites-available/iroh-relay-acme
  cat > "$NGINX_CONF" <<'NGINX'
# P0-pre: serve certbot HTTP-01 challenge for this hostname only.
# All other hostnames/sites are untouched.
server {
    listen 80;
    listen [::]:80;
    server_name __RELAY_HOSTNAME__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
        try_files $uri =404;
    }

    location / { return 404; }
}
NGINX
  sed -i "s/__RELAY_HOSTNAME__/$RELAY_HOSTNAME/g" "$NGINX_CONF"
  ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/iroh-relay-acme
  if ! nginx -t; then
    rm -f /etc/nginx/sites-enabled/iroh-relay-acme
    echo "    nginx 配置校验失败，已回滚新增的 server 块" >&2
    exit 1
  fi
  systemctl reload nginx
  echo "    nginx 平滑 reload 完成，现有站点未改动"

  certbot certonly --webroot -w "$WEBROOT" -d "$RELAY_HOSTNAME" \
    --non-interactive --agree-tos -m "$ACME_EMAIL" --keep-until-expiring
  cp "/etc/letsencrypt/live/$RELAY_HOSTNAME/fullchain.pem" "$CERTDIR/default.crt"
  cp "/etc/letsencrypt/live/$RELAY_HOSTNAME/privkey.pem" "$CERTDIR/default.key"
  chown iroh-relay:iroh-relay "$CERTDIR/default.crt" "$CERTDIR/default.key"
  chmod 0600 "$CERTDIR/default.crt" "$CERTDIR/default.key"
  echo "    证书已复制到 $CERTDIR/default.{crt,key}（非 root 可读）"

  install -d -m 0755 "$(dirname "$HOOK")"
  cat > "$HOOK" <<HOOK
#!/bin/bash
case "\${RENEWED_DOMAINS:-}" in
  *$RELAY_HOSTNAME*) ;;
  *) exit 0 ;;
esac
cp /etc/letsencrypt/live/$RELAY_HOSTNAME/fullchain.pem $CERTDIR/default.crt
cp /etc/letsencrypt/live/$RELAY_HOSTNAME/privkey.pem $CERTDIR/default.key
chown iroh-relay:iroh-relay $CERTDIR/default.crt $CERTDIR/default.key
chmod 0600 $CERTDIR/default.crt $CERTDIR/default.key
systemctl restart iroh-relay
HOOK
  chmod 0755 "$HOOK"
  echo "    续期 hook 已安装：$HOOK"
else
  rm -f /etc/nginx/sites-enabled/iroh-relay-acme 2>/dev/null || true
  echo "    standalone 模式：由内置 TLS-ALPN-01 在 443 端口自动签发"
fi

echo "==> 8. 防火墙规则（不执行 ufw enable，避免切断 SSH）"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${RELAY_HTTPS_PORT}/tcp" || true
  ufw allow 7842/udp || true
  if [ "$MODE" = standalone ]; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
  ufw status || true
fi
echo "    云安全组需放行：TCP ${RELAY_HTTPS_PORT} / UDP 7842（nginx 模式保留 TCP 80 给 certbot）"

echo "==> 9. 启动并查看日志"
systemctl daemon-reload
systemctl enable --now iroh-relay
systemctl restart iroh-relay
sleep 4
systemctl status iroh-relay --no-pager || true
journalctl -u iroh-relay -n 60 --no-pager || true

echo
echo "================ 部署信息（请立即保存） ================"
echo "模式        : $MODE"
echo "RelayUrl    : $RELAY_URL"
echo "RELAY_TOKEN : $RELAY_TOKEN"
echo "证书        : $CERT_MODE / $([ "$MODE" = nginx ] && echo certbot-webroot || echo builtin-tls-alpn-01)"
echo "metrics     : 127.0.0.1:9090（仅本机）"
echo "========================================================"
echo "验收见 infra/README.md §8："
echo "  curl -I $RELAY_URL"
echo "  openssl s_client -connect ${RELAY_HOSTNAME}:${RELAY_HTTPS_PORT} -servername ${RELAY_HOSTNAME}"
echo "  journalctl -u iroh-relay -n 200 --no-pager   # 确认 TLS/QUIC 生效、配置已加载"
