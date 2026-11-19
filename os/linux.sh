#!/usr/bin/env bash
####################################
# desc: Linux 准备 Docker 引擎（自动识别发行版，只装容器运行时，不装 Docker Desktop）
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
# 本文件由 install.sh 通过 source 加载，共用其 info/warn/die/docker_ready 与常量，请勿单独执行。

require_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 || die "需要 root 权限，请改用 root 执行：bash $SELF"
    info "需要 root 权限，改用 sudo 重新执行"
    exec sudo env "PATH=$PATH" bash "$SELF"
}

install_docker_official() {
    info "发行版仓库未提供 Docker，改用官方安装脚本（阿里云镜像源）"
    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 Docker 官方安装脚本"
    local tmp
    tmp=$(mktemp)
    curl -fsSL --retry 3 --max-time 120 -o "$tmp" https://get.docker.com || die "下载 https://get.docker.com 失败，请检查网络"
    sh "$tmp" --mirror Aliyun || sh "$tmp"
    rm -f "$tmp"
}

install_docker_ce_el() {
    local distro=centos
    if [ "${ID:-}" = fedora ]; then
        distro=fedora
    fi
    info "配置 Docker CE 仓库（阿里云 $distro 镜像源）"
    # 阿里云没有 rocky/almalinux 目录，EL 衍生版统一走 centos 路径，$releasever 由包管理器展开
    cat >/etc/yum.repos.d/docker-ce.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/$distro/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/$distro/gpg
EOF
    "$PKG" install -y docker-ce docker-ce-cli containerd.io
}

install_docker() {
    info "未检测到 Docker，开始安装容器引擎（不安装 Docker Desktop）"
    DOCKER_INSTALLED=1
    case "$PKG" in
        apt)
            apt-get update || warn "软件源更新失败，继续尝试安装"
            DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
            DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io || install_docker_official
            ;;
        dnf | yum)
            "$PKG" install -y docker-engine || "$PKG" install -y moby-engine || install_docker_ce_el
            ;;
        zypper)
            zypper --non-interactive install docker || install_docker_official
            ;;
        pacman)
            pacman -Sy --noconfirm docker
            ;;
        apk)
            apk add --no-cache docker
            ;;
        *)
            die "未识别的包管理器，请手动安装 Docker 引擎后重新运行本脚本"
            ;;
    esac
    command -v docker >/dev/null 2>&1 || die "Docker 安装失败：未找到 docker 命令"
}

configure_registry_mirror() {
    if [ "$DOCKER_INSTALLED" -ne 1 ]; then
        return 0
    fi
    if [ -e /etc/docker/daemon.json ]; then
        info "已存在 /etc/docker/daemon.json，保留原有配置"
        return 0
    fi
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["$REGISTRY_MIRROR"]
}
EOF
    info "已配置镜像加速：$REGISTRY_MIRROR"
}

start_docker() {
    local docker_bin
    if docker_ready; then
        return 0
    fi
    docker_bin=$(command -v docker || true)
    case "$docker_bin" in
        /mnt/*)
            die "当前 docker 来自 Windows 的 Docker Desktop（WSL 集成）。请先在 Windows 启动 Docker Desktop 并开启本发行版的 WSL 集成，再重新运行。"
            ;;
    esac
    info "启动 Docker 服务"
    # 服务管理器可能因开机自启已在拉起而返回非零，是否就绪统一由 wait_docker 判定
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker || warn "systemctl start docker 返回非零，继续等待服务就绪"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || true
        rc-service docker start || warn "rc-service docker start 返回非零，继续等待服务就绪"
    elif command -v service >/dev/null 2>&1; then
        service docker start || warn "service docker start 返回非零，继续等待服务就绪"
    else
        die "未找到 systemd/OpenRC/service，请手动启动 dockerd 后重新运行本脚本"
    fi
}

wait_docker() {
    local i
    for ((i = 0; i < 30; i++)); do
        if docker_ready; then
            return 0
        fi
        sleep 1
    done
    return 1
}

ensure_docker_linux() {
    if [ "$WSL_VER" -eq 1 ]; then
        die "WSL1 无法运行 Docker 引擎，请先在 Windows 执行：wsl --set-version <发行版名> 2"
    fi
    # 旧版 ubuntu.sh/wsl.sh 写入的 iptables:false 会让 -p 端口映射失效
    if [ -r /etc/docker/daemon.json ] && grep -Eq '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json; then
        die "/etc/docker/daemon.json 含 \"iptables\": false，会导致端口映射失效。请删除该配置项并重启 Docker（systemctl restart docker）后重新运行。"
    fi
    if docker_ready; then
        info "Docker 已安装并正在运行"
        return 0
    fi
    require_root
    if ! command -v docker >/dev/null 2>&1; then
        install_docker
        configure_registry_mirror
    fi
    start_docker
    wait_docker || die "Docker 服务未能就绪，请检查：systemctl status docker 或 journalctl -u docker"
}