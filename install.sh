#!/usr/bin/env bash
####################################
# desc: xqkeji 服务器环境搭建脚本（自动识别操作系统）
# author: xqkeji.cn
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
# Linux：自动识别发行版，未安装 Docker 时只安装容器引擎（不安装 Docker Desktop）
# macOS：需已自行安装并启动 Docker Desktop / OrbStack / Colima
# Windows：请使用 win.bat
#
# 结构：本文件是入口，负责识别系统、共用函数与部署容器；
#       准备 Docker 的逻辑按系统拆在 os/linux.sh、os/macos.sh，运行时 source 加载；
#       本地 HTTPS 证书由 ssl.sh 生成（mkcert 优先、openssl 兜底），nginx 443 + 80→443；
#       环境程序自动升级见 upgrade.sh，日常启停见 start.sh / stop.sh。
#       版本号以 VERSION 文件为准。
set -euo pipefail

NET_NAME=xqkeji-net
NET_SUBNET=172.0.0.0/24
IP_NGINX=172.0.0.2
IP_PHP=172.0.0.10
IP_MONGO=172.0.0.100
IP_MYSQL=172.0.0.200
REGISTRY_MIRROR=https://docker.m.daocloud.io
ALL_CONTAINERS=(nginx mysql mongo xqkeji)
IMAGES=(nginx mysql mongo xqkeji/xqkeji)
CONTAINERS=(nginx mysql mongo xqkeji)
WITH_MYSQL=1
MYSQL_FLAG=0
IMAGE_TAGS=()
BACKUP_DATA=0

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
# MySQL 可选：默认安装，交互确认或非交互标志跳过
####################################
parse_args() {
    local a key
    while [ $# -gt 0 ]; do
        a=$1
        case "$a" in
            --with-mysql) WITH_MYSQL=1; MYSQL_FLAG=1 ;;
            --without-mysql) WITH_MYSQL=0; MYSQL_FLAG=1 ;;
            --tag)
                [ $# -ge 2 ] || die "--tag 需要参数，形如 --tag mysql=8.0"
                case "$2" in
                    ?*=?*) ;;
                    *) die "--tag 格式应为 镜像名=tag，如 mysql=8.0（可用：nginx / mysql / mongo / xqkeji）" ;;
                esac
                key=${2%%=*}
                case "$key" in
                    nginx | mysql | mongo | xqkeji | xqkeji/xqkeji) IMAGE_TAGS+=("$2") ;;
                    *) die "--tag 不支持的镜像名：$key（可用：nginx / mysql / mongo / xqkeji）" ;;
                esac
                shift
                ;;
            --backup-data) BACKUP_DATA=1 ;;
            *) die "未知参数：$a（可用：--with-mysql / --without-mysql / --tag 镜像名=tag / --backup-data）" ;;
        esac
        shift
    done
}

# 镜像引用：--tag 指定了就用 镜像名:tag，否则跟随 latest。
# 短名（xqkeji）与全名（xqkeji/xqkeji）都接受。
image_ref() {
    local name=$1 key=${1##*/} t
    for t in ${IMAGE_TAGS[@]+"${IMAGE_TAGS[@]}"}; do
        case "$t" in
            "$key="* | "$name="*) printf '%s:%s' "$name" "${t#*=}"; return 0 ;;
        esac
    done
    printf '%s' "$name"
}

ask_mysql() {
    if [ "$MYSQL_FLAG" = 1 ]; then
        if [ "$WITH_MYSQL" = 1 ]; then
            info "按参数安装 MySQL 容器"
        else
            info "按参数跳过 MySQL 容器（data/mysql 旧数据保留）"
        fi
        return 0
    fi

    if [ ! -t 0 ]; then
        info "非交互环境，默认安装 MySQL（--without-mysql 可跳过）"
        return 0
    fi

    local ans
    while true; do
        read -r -p '是否安装 MySQL 容器？[Y/n]（默认安装）: ' ans
        case "$ans" in
            '' | y | Y) WITH_MYSQL=1; return 0 ;;
            n | N) WITH_MYSQL=0; info "跳过 MySQL 容器（data/mysql 旧数据保留）"; return 0 ;;
            *) warn "请输入 y 或 n（直接回车默认安装）" ;;
        esac
    done
}

apply_mysql_choice() {
    if [ "$WITH_MYSQL" = 1 ]; then
        IMAGES=("$(image_ref nginx)" "$(image_ref mysql)" "$(image_ref mongo)" "$(image_ref xqkeji/xqkeji)")
        CONTAINERS=(nginx mysql mongo xqkeji)
    else
        IMAGES=("$(image_ref nginx)" "$(image_ref mongo)" "$(image_ref xqkeji/xqkeji)")
        CONTAINERS=(nginx mongo xqkeji)
    fi
}

####################################
# 部署容器（MySQL 按选择取舍）
####################################
prepare_dirs() {
    local d f
    for d in code www log/nginx log/mongo log/php data/mongo etc/nginx/modules-enabled data/nginx/acme; do
        mkdir -p "$BASE_DIR/$d"
    done
    if [ "$WITH_MYSQL" = 1 ]; then
        for d in log/mysql data/mysql; do
            mkdir -p "$BASE_DIR/$d"
        done
    fi
    chmod -R a+w "$BASE_DIR/log" "$BASE_DIR/data"
    for f in etc/nginx/nginx.conf etc/nginx/conf.d etc/php/php.ini etc/mongo/mongodb.conf; do
        if [ ! -e "$BASE_DIR/$f" ]; then
            die "缺少 $f，请在完整的 dnmmp 目录内运行本脚本"
        fi
    done
    if [ "$WITH_MYSQL" = 1 ] && [ ! -e "$BASE_DIR/etc/mysql" ]; then
        die "缺少 etc/mysql，请在完整的 dnmmp 目录内运行本脚本"
    fi
}

pull_images() {
    local img out rc
    for img in "${IMAGES[@]}"; do
        info "拉取镜像 $img"
        out=$(docker pull "$img" 2>&1) && rc=0 || rc=$?
        if [ "$rc" != 0 ]; then
            warn "拉取 $img 失败，5 秒后重试"
            sleep 5
            if ! docker pull "$img"; then
                if docker image inspect "$img" >/dev/null 2>&1; then
                    warn "拉取仍失败，使用本地已有镜像 $img 继续（可能不是最新版）"
                    continue
                fi
                die "镜像 $img 拉取失败且本地不存在。请检查网络，或配置可用的 registry-mirrors 后重试"
            fi
            info "$img 重试拉取成功"
            continue
        fi
        case "$out" in
            *"Image is up to date"*) info "$img 已是最新" ;;
            *"Downloaded newer image"*) info "$img 已更新到新版" ;;
        esac
    done
}

# 重建前可选整目录备份 data/（opt-in，数据量大时耗时）
backup_data() {
    [ "$BACKUP_DATA" = 1 ] || return 0
    if [ ! -d "$BASE_DIR/data" ]; then
        warn "data/ 不存在，跳过备份"
        return 0
    fi
    local dest="$BASE_DIR/data.backup-$(date +%Y%m%d-%H%M%S)"
    info "备份 data/ 到 $dest（可能耗时，取决于数据量）"
    cp -a "$BASE_DIR/data" "$dest"
    info "备份完成：$dest"
}

warn_db_upgrade() {
    local c found=0
    for c in mysql mongo; do
        if docker container inspect "$c" >/dev/null 2>&1; then
            found=1
        fi
    done
    [ "$found" = 1 ] || return 0
    warn "mysql/mongo 镜像跟随 latest：跨大版本升级可能无法启动旧数据。担心请先备份（--backup-data 自动备份 data/）；升坏可用 --tag mysql=<旧版> 重跑回退"
}

remove_old_containers() {
    local c
    # 遍历全部四种容器：本次选择不装 MySQL 时，旧的 mysql 容器也一并移除（数据保留）。
    for c in "${ALL_CONTAINERS[@]}"; do
        if docker container inspect "$c" >/dev/null 2>&1; then
            if [ "$c" = mysql ] && [ "$WITH_MYSQL" = 0 ]; then
                info "按选择移除已存在的 mysql 容器（数据保留在 data/mysql）"
            else
                info "重新创建已存在的容器 $c（数据库数据保留在 data/ 目录）"
            fi
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
        -v "$BASE_DIR/etc/nginx/modules-enabled:/etc/nginx/modules-enabled" \
        -v "$BASE_DIR/etc/nginx/ssl:/etc/nginx/ssl:ro" \
        -v "$BASE_DIR/data/nginx/acme:/var/cache/nginx/acme" \
        "$(image_ref nginx)" >/dev/null

    if [ "$WITH_MYSQL" = 1 ]; then
        info "启动 mysql 容器"
        docker run -d --name mysql --restart=always \
            --network "$NET_NAME" --ip "$IP_MYSQL" -p 3306:3306 \
            -v "$BASE_DIR/etc/mysql:/etc/mysql/conf.d" \
            -v "$BASE_DIR/log/mysql:/logs" \
            -v "$BASE_DIR/data/mysql:/var/lib/mysql" \
            -e MYSQL_ROOT_PASSWORD='xqkeji.cn' \
            "$(image_ref mysql)" >/dev/null
    fi

    info "启动 mongo 容器"
    docker run -d --name mongo --restart=always \
        --network "$NET_NAME" --ip "$IP_MONGO" -p 27017:27017 \
        -v "$BASE_DIR/log/mongo:/home/log" \
        -v "$BASE_DIR/etc/mongo:/home/configdb" \
        -v "$BASE_DIR/data/mongo:/data/db" \
        -e MONGO_INITDB_ROOT_USERNAME='root' \
        -e MONGO_INITDB_ROOT_PASSWORD='xqkeji.cn' \
        "$(image_ref mongo)" --config /home/configdb/mongodb.conf >/dev/null

    info "启动 xqkeji（php-fpm）容器"
    docker run -d --name xqkeji --restart=always \
        --network "$NET_NAME" --ip "$IP_PHP" -p 9000:9000 \
        -v "$BASE_DIR/code:/home/code" \
        -v "$BASE_DIR/www:/home/www" \
        -v "$BASE_DIR/etc/php/php.ini:/usr/local/etc/php/php.ini" \
        -v "$BASE_DIR/log/php:/home/log" \
        "$(image_ref xqkeji/xqkeji)" >/dev/null
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
新增站点：./bin/add-site.sh <name> [project-dir]（交互选域名：默认 <name>.xqkeji.dev 走本地证书+hosts；其它域名走 ACME 自动签发，例 ./bin/add-site.sh crm）
EOF
    if [ "$WITH_MYSQL" = 1 ]; then
        echo 'MySQL   ：127.0.0.1:3306   root / xqkeji.cn'
    else
        echo 'MySQL   ：本次未安装（data/mysql 旧数据保留；重装执行 ./install.sh --with-mysql）'
    fi
    cat <<EOF
MongoDB ：127.0.0.1:27017  root / xqkeji.cn
PHP-FPM ：127.0.0.1:9000   容器内 $IP_PHP:9000
数据目录：$BASE_DIR/data
日志目录：$BASE_DIR/log
使用镜像：${IMAGES[*]}

容器已设置 --restart=always，Docker 启动后会自动运行。
常用命令：./start.sh 启动 / ./stop.sh 停止（Windows：win.bat start / win.bat stop）
自动升级：./upgrade.sh（Windows：win.bat upgrade）
EOF
}

main() {
    parse_args "$@"
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
    ask_mysql
    apply_mysql_choice
    prepare_dirs
    pull_images
    backup_data
    warn_db_upgrade
    remove_old_containers
    ensure_network
    bash "$BASE_DIR/ssl.sh"
    run_containers
    verify_service
    summary
}

main "$@"