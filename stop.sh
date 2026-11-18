#!/usr/bin/env bash
####################################
# desc: 停止 dnmmp 环境容器（只停止已安装的容器，数据保留在 data/ 目录）
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
set -euo pipefail

NET_NAME=xqkeji-net
CONTAINERS=(nginx mysql mongo xqkeji)

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$BASE_DIR"

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未找到 docker 命令，请先运行 install.sh"
docker info >/dev/null 2>&1 || die "Docker 未运行，请先启动 Docker 后再执行本脚本"

FOUND=0
for c in "${CONTAINERS[@]}"; do
    if docker container inspect "$c" >/dev/null 2>&1; then
        FOUND=1
        docker stop "$c" >/dev/null
        info "已停止 $c"
    else
        info "跳过 $c（容器不存在）"
    fi
done

[ "$FOUND" = 1 ] || die "未找到任何 dnmmp 容器，请先运行 install.sh"

docker ps -a --filter "network=$NET_NAME" --format 'table {{.Names}}\t{{.Status}}'
info "数据保留在 $BASE_DIR/data，重新启动执行 ./start.sh"