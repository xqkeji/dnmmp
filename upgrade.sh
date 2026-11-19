#!/usr/bin/env bash
####################################
# desc: dnmmp 环境程序自动升级（取 GitHub 最新 tag，覆盖脚本与基础配置，数据不动）
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
# 用法：./upgrade.sh [--force] [--local <zip>] [--backup-data]
#   --force         版本相同也重新覆盖一遍
#   --local <zip>   离线升级：使用已下载的 GitHub 源码 zip（tag 页 Download ZIP）
#   --backup-data   升级后重新部署前备份 data/（透传给 install.sh）
# 只覆盖程序文件（脚本 + etc 基础配置），绝不触碰 data/ www/ code/ log/
# etc/nginx/ssl/ 与 conf.d 里的自定义站点配置。覆盖前旧文件备份到
# .upgrade-backup/<旧版本>-<时间戳>/，覆盖中途失败自动回滚。
# Windows 对应入口：win.bat upgrade（bin/upgrade.ps1）。
set -Eeuo pipefail

TAGS_API=https://api.github.com/repos/xqkeji/dnmmp/tags
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FORCE=0
LOCAL_ZIP=
BACKUP_DATA=0

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# 升级覆盖白名单：只列程序文件与基础配置，用户数据/自定义配置不在其中
UPGRADE_FILES=(
    install.sh win.bat ssl.sh start.sh stop.sh upgrade.sh
    os/linux.sh os/macos.sh
    bin/add-site.sh bin/upgrade.ps1
    README.md LICENSE VERSION .gitignore .gitattributes
    etc/nginx/nginx.conf etc/nginx/conf.d/default.conf
    etc/php/php.ini etc/mysql/my.ini etc/mongo/mongodb.conf
)

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE=1 ;;
            --backup-data) BACKUP_DATA=1 ;;
            --local)
                [ $# -ge 2 ] || die "--local 需要参数：源码 zip 的路径"
                LOCAL_ZIP=$2
                shift
                ;;
            *) die "未知参数：$1（可用：--force / --local <zip> / --backup-data）" ;;
        esac
        shift
    done
}

fetch_latest_tag() {
    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法查询最新版本（可改用 --local <zip> 离线升级）"
    local json
    json=$(curl -fsSL --retry 3 --max-time 60 "$TAGS_API") || die "获取 tag 列表失败，请检查网络（可改用 --local <zip> 离线升级）"
    # head 提前退出会让 grep 收 SIGPIPE，pipefail 下整条管道非零，故 || true 兜底，
    # 解析结果是否为空由下面的 -n 校验负责。
    TAG=$(printf '%s' "$json" | grep -o '"name": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    ZIP_URL=$(printf '%s' "$json" | grep -o '"zipball_url": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    [ -n "$TAG" ] && [ -n "$ZIP_URL" ] || die "无法从 tag 列表解析最新版本，请改用 --local <zip> 离线升级"
}

download_zip() {
    info "下载升级包：$ZIP_URL"
    ZIP="$WORK/dnmmp.zip"
    curl -fsSL --retry 3 --max-time 300 -o "$ZIP" "$ZIP_URL" || die "下载升级包失败，请检查网络（可改用 --local <zip> 离线升级）"
}

verify_package() {
    local f
    for f in "${UPGRADE_FILES[@]}"; do
        [ -f "$SRC/$f" ] || die "升级包缺少 $f，拒绝升级（包可能不完整）"
    done
    [ -d "$SRC/etc/php/conf.d" ] || die "升级包缺少 etc/php/conf.d，拒绝升级（包可能不完整）"
}

backup_targets() {
    local f rel
    for f in "${UPGRADE_FILES[@]}"; do
        if [ -e "$BASE_DIR/$f" ]; then
            mkdir -p "$BK/$(dirname "$f")"
            cp -p "$BASE_DIR/$f" "$BK/$f"
        fi
    done
    for f in "$BASE_DIR"/etc/php/conf.d/*.ini; do
        [ -e "$f" ] || continue
        rel=${f#"$BASE_DIR"/}
        mkdir -p "$BK/$(dirname "$rel")"
        cp -p "$f" "$BK/$rel"
    done
}

rollback() {
    warn "升级失败，回滚到升级前的文件"
    local f rel
    while IFS= read -r -d '' f; do
        rel=${f#"$BK"/}
        mkdir -p "$BASE_DIR/$(dirname "$rel")"
        cp -p "$f" "$BASE_DIR/$rel"
    done < <(find "$BK" -type f -print0)
    warn "已回滚。备份目录保留在：$BK"
}

overlay() {
    local f
    for f in "${UPGRADE_FILES[@]}"; do
        mkdir -p "$BASE_DIR/$(dirname "$f")"
        cp -p "$SRC/$f" "$BASE_DIR/$f"
    done
    mkdir -p "$BASE_DIR/etc/php/conf.d"
    cp -p "$SRC"/etc/php/conf.d/*.ini "$BASE_DIR/etc/php/conf.d/"
    chmod +x "$BASE_DIR/install.sh" "$BASE_DIR/ssl.sh" "$BASE_DIR/start.sh" \
        "$BASE_DIR/stop.sh" "$BASE_DIR/upgrade.sh" "$BASE_DIR/bin/add-site.sh" \
        "$BASE_DIR/os/linux.sh" "$BASE_DIR/os/macos.sh"
}

redeploy() {
    if [ ! -t 0 ]; then
        info "非交互环境，跳过自动重新部署。请稍后手动执行：./install.sh"
        return 0
    fi
    local ans
    read -r -p '升级完成。现在重新部署容器（拉取新镜像并重建）？[Y/n]（默认是）: ' ans || ans=n
    case "$ans" in
        n | N)
            info "跳过重新部署。请稍后手动执行：./install.sh"
            return 0
            ;;
    esac
    # MySQL 取舍按现有容器推导：有 mysql 容器→装；有其它容器但没 mysql→不装；
    # 一个容器都没有→不带标志，交给 install.sh 询问/默认（避免首次部署被跳过）。
    local c any=0 args=()
    for c in nginx mysql mongo xqkeji; do
        if docker container inspect "$c" >/dev/null 2>&1; then
            any=1
        fi
    done
    if [ "$any" = 1 ]; then
        if docker container inspect mysql >/dev/null 2>&1; then
            args+=(--with-mysql)
        else
            args+=(--without-mysql)
        fi
    fi
    if [ "$BACKUP_DATA" = 1 ]; then
        args+=(--backup-data)
    fi
    bash "$BASE_DIR/install.sh" ${args[@]+"${args[@]}"}
}

main() {
    parse_args "$@"
    cd "$BASE_DIR"
    OLD_VERSION=$(tr -d '[:space:]' <VERSION 2>/dev/null || true)
    OLD_VERSION=${OLD_VERSION:-unknown}
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    if [ -n "$LOCAL_ZIP" ]; then
        [ -f "$LOCAL_ZIP" ] || die "--local 文件不存在：$LOCAL_ZIP"
        ZIP=$LOCAL_ZIP
        NEW_VERSION=local
        info "离线升级：$LOCAL_ZIP"
    else
        fetch_latest_tag
        NEW_VERSION=$TAG
        if [ "$NEW_VERSION" = "$OLD_VERSION" ] && [ "$FORCE" != 1 ]; then
            info "已是最新版本（$OLD_VERSION），无需升级（--force 可强制重新覆盖）"
            return 0
        fi
        download_zip
    fi
    command -v unzip >/dev/null 2>&1 || die "缺少 unzip，无法解压升级包。请先安装 unzip（apt install unzip / brew install unzip 等）"
    unzip -q "$ZIP" -d "$WORK/src" || die "解压升级包失败（文件可能损坏）：$ZIP"
    SRC=
    for d in "$WORK/src"/*/; do
        if [ -d "$d" ]; then
            SRC=${d%/}
            break
        fi
    done
    [ -n "$SRC" ] || die "升级包内未找到源码目录（应为 GitHub tag 页下载的 zip）"
    if [ -n "$LOCAL_ZIP" ] && [ -f "$SRC/VERSION" ]; then
        NEW_VERSION=$(tr -d '[:space:]' <"$SRC/VERSION")
    fi
    verify_package
    info "升级：$OLD_VERSION -> $NEW_VERSION"
    STAMP=$(date +%Y%m%d-%H%M%S)
    BK="$BASE_DIR/.upgrade-backup/$OLD_VERSION-$STAMP"
    mkdir -p "$BK"
    backup_targets
    trap rollback ERR
    overlay
    trap - ERR
    info "升级完成：$OLD_VERSION -> $NEW_VERSION（旧文件备份：$BK）"
    redeploy
}

# 本脚本会在运行中覆盖自身：main 与 exit 必须在同一条已解析的语句里，
# 保证 main 返回后不再从（已被替换的）文件读取任何字节。
main "$@"; exit $?
