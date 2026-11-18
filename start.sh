#!/usr/bin/env bash
####################################
# desc: 启动 dnmmp 环境容器（只启动已安装的容器，未装 MySQL 自动跳过）
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
set -euo pipefail

NET_NAME=xqkeji-net
NET_SUBNET=172.0.0.0/24
CONTAINERS=(nginx mysql mongo xqkeji)

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$BASE_DIR"

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "未找到 docker 命令，请先运行 install.sh"
docker info >/dev/null 2>&1 || die "Docker 未运行，请先启动 Docker（Linux：systemctl start docker；Windows/macOS：启动 Docker Desktop）"

if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    docker network create --subnet "$NET_SUBNET" "$NET_NAME" >/dev/null
    info "已创建网络 $NET_NAME ($NET_SUBNET)"
fi

FOUND=0
for c in "${CONTAINERS[@]}"; do
    if docker container inspect "$c" >/dev/null 2>&1; then
        FOUND=1
        docker start "$c" >/dev/null
        info "已启动 $c"
    else
        info "跳过 $c（容器不存在；MySQL 未安装属正常，其余请先运行 install.sh）"
    fi
done

[ "$FOUND" = 1 ] || die "未找到任何 dnmmp 容器，请先运行 install.sh"

docker ps --filter "network=$NET_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
info "访问地址：https://127.0.0.1/（http://127.0.0.1/ 自动跳转 https）"