#!/usr/bin/env bash
####################################
# desc: 生成本地 HTTPS 测试证书（mkcert 本地 CA 优先，openssl 自签兜底）
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
# 为 localhost / 127.0.0.1 / ::1 / *.xqkeji.dev / xqkeji.dev 签发证书，
# 输出 etc/nginx/ssl/local.pem 与 local-key.pem，供 nginx 443 使用。
# 可单独执行 ./ssl.sh 重签（FORCE=1 覆盖已有证书）；install.sh 部署时也会自动调用。
# 注意：localhost/127.0.0.1 无法申请公网证书，这里用的是本地 CA，不是 Let's Encrypt。
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SSL_DIR="$BASE_DIR/etc/nginx/ssl"
CERT="$SSL_DIR/local.pem"
KEY="$SSL_DIR/local-key.pem"
BIN_DIR="$BASE_DIR/bin"
MKCERT_VERSION=v1.4.4
DOMAINS=(localhost 127.0.0.1 ::1 "*.xqkeji.dev" xqkeji.dev)
MKCERT_BIN=

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# 正版 mkcert 支持 -CAROOT；npm 上的同名包不支持，据此区分
is_real_mkcert() { command -v "$1" >/dev/null 2>&1 && "$1" -CAROOT >/dev/null 2>&1; }

mkcert_platform() {
    local os arch
    os=$(uname -s); arch=$(uname -m)
    case "$os" in
        Linux) os=linux ;;
        Darwin) os=darwin ;;
        *) return 1 ;;
    esac
    case "$arch" in
        x86_64 | amd64) arch=amd64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) return 1 ;;
    esac
    printf '%s-%s' "$os" "$arch"
}

ensure_mkcert() {
    if is_real_mkcert mkcert; then MKCERT_BIN=$(command -v mkcert); return 0; fi
    if [ -x "$BIN_DIR/mkcert" ] && is_real_mkcert "$BIN_DIR/mkcert"; then MKCERT_BIN="$BIN_DIR/mkcert"; return 0; fi
    local plat url i
    plat=$(mkcert_platform) || { warn "无法识别 mkcert 平台：$(uname -s)/$(uname -m)"; return 1; }
    url="https://github.com/FiloSottile/mkcert/releases/download/$MKCERT_VERSION/mkcert-$MKCERT_VERSION-$plat"
    mkdir -p "$BIN_DIR"
    info "下载 mkcert $MKCERT_VERSION（$plat）"
    for i in 1 2 3; do
        if curl -fsSL --retry 2 --max-time 120 -o "$BIN_DIR/mkcert" "$url"; then
            chmod +x "$BIN_DIR/mkcert"
            if is_real_mkcert "$BIN_DIR/mkcert"; then MKCERT_BIN="$BIN_DIR/mkcert"; return 0; fi
        fi
        warn "mkcert 下载失败（第 $i 次）"
        sleep 3
    done
    return 1
}

gen_with_mkcert() {
    info "使用 mkcert 本地 CA 签发受信任证书"
    "$MKCERT_BIN" -install || warn "mkcert -install 未完全成功（装系统信任可能需更高权限），证书仍会生成"
    "$MKCERT_BIN" -cert-file "$CERT" -key-file "$KEY" "${DOMAINS[@]}"
}

gen_with_openssl() {
    command -v openssl >/dev/null 2>&1 || return 1
    warn "改用 openssl 自签证书：浏览器会提示不受信任（测试可用）"
    local cnf rc
    cnf=$(mktemp)
    cat >"$cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=localhost
O=dnmmp local dev
[v3]
subjectAltName=@alt
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[alt]
DNS.1=localhost
DNS.2=*.xqkeji.dev
DNS.3=xqkeji.dev
IP.1=127.0.0.1
IP.2=::1
EOF
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout "$KEY" -out "$CERT" -config "$cnf" >/dev/null 2>&1
    rc=$?
    rm -f "$cnf"
    return "$rc"
}

main() {
    mkdir -p "$SSL_DIR"
    if [ -f "$CERT" ] && [ -f "$KEY" ] && [ "${FORCE:-0}" != 1 ]; then
        info "已存在证书：$CERT（重签请执行 FORCE=1 ./ssl.sh）"
        return 0
    fi
    local method=
    if ensure_mkcert && gen_with_mkcert; then
        method=mkcert
    elif gen_with_openssl; then
        method=openssl
    else
        die "证书生成失败：mkcert 与 openssl 均不可用，请安装其一后重试"
    fi
    chmod 644 "$CERT"
    chmod 600 "$KEY"
    info "证书：$CERT"
    info "私钥：$KEY"
    info "覆盖域名：${DOMAINS[*]}"
    if [ "$method" = mkcert ]; then
        info "本地 CA 目录：$("$MKCERT_BIN" -CAROOT)（mkcert -install 已尝试装入系统/浏览器信任）"
    else
        warn "自签证书不被浏览器信任；要绿锁请安装 mkcert 后执行 FORCE=1 ./ssl.sh 重签"
    fi
}

main "$@"