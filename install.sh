#!/usr/bin/env bash
####################################
# desc: xqkeji 服务器环境搭建脚本（自动识别操作系统）
# version: 2.1
# author: xqkeji.cn
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
# Linux：自动识别发行版，未安装 Docker 时只安装容器引擎（不安装 Docker Desktop）
# macOS：需已自行安装并启动 Docker Desktop / OrbStack / Colima
# Windows：请使用 win.bat
#
# 结构：本文件是入口，负责识别系统、共用函数与部署四个容器；
#       准备 Docker 的逻辑按系统拆在 os/linux.sh、os/macos.sh，运行时 source 加载；
#       本地 HTTPS 证书由 ssl.sh 生成（mkcert 优先、openssl 兜底），nginx 443 + 80→443。
set -euo pipefail

NET_NAME=xqkeji-net
NET_SUBNET=172.0.0.0/24
IP_NGINX=172.0.0.2
IP_PHP=172.0.0.10
IP_MONGO=172.0.0.100
IP_MYSQL=172.0.0.200
REGISTRY_MIRROR=https://docker.m.daocloud.io
IMAGES=(nginx mysql mongo xqkeji/xqkeji)
CONTAINERS=(nginx mysql mongo xqkeji)

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SELF="$BASE_DIR/$(basename -- "${BASH_SOURCE[0]}")"
cd "$BASE_DIR"

OS_KIND=linux
OS_NAME=Linux
PKG=
WSL_VER=0
DOCKER_INSTALLED=0

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

####################################
# 识别操作系统、发行版、包管理器、是否 WSL
####################################
detect_platform() {
    local kernel c
    kernel=$(uname -s)
    case "$kernel" in
        Darwin)
            OS_KIND=macos
            OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null || echo '') ($(uname -m))"
            return 0
            ;;
        Linux)
            OS_KIND=linux
            ;;
        MINGW* | MSYS* | CYGWIN*)
            die "Windows 请改用 win.bat（需先安装 Docker Desktop）。"
            ;;
        *)
            die "不支持的操作系统：$kernel"
            ;;
    esac

    if [ -r /etc/os-release ]; then
        . /etc/os-release
    fi
    OS_NAME=${PRETTY_NAME:-${NAME:-${ID:-Linux}}}

    if grep -qi microsoft /proc/version 2>/dev/null; then
        WSL_VER=1
        if grep -qi WSL2 /proc/version 2>/dev/null; then
            WSL_VER=2
        fi
        OS_NAME="$OS_NAME (WSL$WSL_VER)"
    fi

    for c in apt-get dnf yum zypper pacman apk; do
        if command -v "$c" >/dev/null 2>&1; then
            PKG=${c%-get}
            break
        fi
    done
}

docker_ready() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

####################################
# 部署四个容器
####################################
prepare_dirs() {
    local d f
    for d in code www log/nginx log/mysql log/mongo log/php data/mysql data/mongo; do
        mkdir -p "$BASE_DIR/$d"
    done
    chmod -R a+w "$BASE_DIR/log" "$BASE_DIR/data"
    for f in etc/nginx/nginx.conf etc/nginx/conf.d etc/php/php.ini etc/mongo/mongodb.conf etc/mysql; do
        if [ ! -e "$BASE_DIR/$f" ]; then
            die "缺少 $f，请在完整的 dnmmp 目录内运行本脚本"
        fi
    done
}

pull_images() {
    local img
    for img in "${IMAGES[@]}"; do
        info "拉取镜像 $img"
        if docker pull "$img"; then
            continue
        fi
        warn "拉取 $img 失败，5 秒后重试"
        sleep 5
        docker pull "$img" || die "镜像 $img 拉取失败。请检查网络，或配置可用的 registry-mirrors 后重试"
    done
}

remove_old_containers() {
    local c
    for c in "${CONTAINERS[@]}"; do
        if docker container inspect "$c" >/dev/null 2>&1; then
            info "重新创建已存在的容器 $c（数据库数据保留在 data/ 目录）"
            docker rm -f "$c" >/dev/null
        fi
    done
}

ensure_network() {
    local subnet
    if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
        subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NET_NAME")
        if [ "$subnet" = "$NET_SUBNET" ]; then
            info "复用已存在的网络 $NET_NAME ($NET_SUBNET)"
            return 0
        fi
        warn "已存在的 $NET_NAME 网段为 $subnet，与 $NET_SUBNET 不符，重新创建"
        docker network rm "$NET_NAME" >/dev/null
    fi
    docker network create --subnet "$NET_SUBNET" "$NET_NAME" >/dev/null
    info "已创建网络 $NET_NAME ($NET_SUBNET)"
}

run_containers() {
    info "启动 nginx 容器"
    docker run -d --name nginx --restart=always \
        --network "$NET_NAME" --ip "$IP_NGINX" -p 80:80 -p 443:443 \
        -v "$BASE_DIR/www:/home/www" \
        -v "$BASE_DIR/log/nginx:/home/log" \
        -v "$BASE_DIR/etc/nginx/nginx.conf:/etc/nginx/nginx.conf" \
        -v "$BASE_DIR/etc/nginx/conf.d:/etc/nginx/conf.d" \
        -v "$BASE_DIR/etc/nginx/ssl:/etc/nginx/ssl:ro" \
        nginx >/dev/null

    info "启动 mysql 容器"
    docker run -d --name mysql --restart=always \
        --network "$NET_NAME" --ip "$IP_MYSQL" -p 3306:3306 \
        -v "$BASE_DIR/etc/mysql:/etc/mysql/conf.d" \
        -v "$BASE_DIR/log/mysql:/logs" \
        -v "$BASE_DIR/data/mysql:/var/lib/mysql" \
        -e MYSQL_ROOT_PASSWORD='xqkeji.cn' \
        mysql >/dev/null

    info "启动 mongo 容器"
    docker run -d --name mongo --restart=always \
        --network "$NET_NAME" --ip "$IP_MONGO" -p 27017:27017 \
        -v "$BASE_DIR/log/mongo:/home/log" \
        -v "$BASE_DIR/etc/mongo:/home/configdb" \
        -v "$BASE_DIR/data/mongo:/data/db" \
        -e MONGO_INITDB_ROOT_USERNAME='root' \
        -e MONGO_INITDB_ROOT_PASSWORD='xqkeji.cn' \
        mongo --config /home/configdb/mongodb.conf >/dev/null

    info "启动 xqkeji（php-fpm）容器"
    docker run -d --name xqkeji --restart=always \
        --network "$NET_NAME" --ip "$IP_PHP" -p 9000:9000 \
        -v "$BASE_DIR/code:/home/code" \
        -v "$BASE_DIR/www:/home/www" \
        -v "$BASE_DIR/etc/php/php.ini:/usr/local/etc/php/php.ini" \
        -v "$BASE_DIR/log/php:/home/log" \
        xqkeji/xqkeji >/dev/null
}

verify_service() {
    local i
    if ! command -v curl >/dev/null 2>&1; then
        warn "未安装 curl，跳过站点连通性检查"
        return 0
    fi
    for ((i = 0; i < 30; i++)); do
        if curl -fsSk -o /dev/null --max-time 3 https://127.0.0.1/ 2>/dev/null; then
            info "站点已可访问：https://127.0.0.1/（80 自动跳转 443）"
            return 0
        fi
        sleep 1
    done
    warn "30 秒内 https://127.0.0.1/ 未响应，请检查：docker ps 与 docker logs nginx"
}

summary() {
    docker ps --filter "network=$NET_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    cat <<EOF

站点目录：$BASE_DIR/www/default
访问地址：https://127.0.0.1/（http://127.0.0.1/ 自动跳转 https）
新增站点：./bin/add-site.sh <name> [project-dir]（nginx 配置 + hosts + 重载，例 ./bin/add-site.sh crm）
MySQL   ：127.0.0.1:3306   root / xqkeji.cn
MongoDB ：127.0.0.1:27017  root / xqkeji.cn
PHP-FPM ：127.0.0.1:9000   容器内 $IP_PHP:9000
数据目录：$BASE_DIR/data
日志目录：$BASE_DIR/log

容器已设置 --restart=always，Docker 启动后会自动运行。
常用命令：docker stop ${CONTAINERS[*]} / docker start ${CONTAINERS[*]}
EOF
}

main() {
    detect_platform
    local os_script="$BASE_DIR/os/$OS_KIND.sh"
    [ -r "$os_script" ] || die "缺少 os/$OS_KIND.sh，请在完整的 dnmmp 目录内运行本脚本"
    source "$os_script"
    "ensure_docker_$OS_KIND"
    info "操作系统：$OS_NAME"
    if [ -n "$PKG" ]; then
        info "包管理器：$PKG"
    fi
    info "Docker 版本：$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    prepare_dirs
    pull_images
    remove_old_containers
    ensure_network
    bash "$BASE_DIR/ssl.sh"
    run_containers
    verify_service
    summary
}

main "$@"