#!/usr/bin/env bash
####################################
# desc: macOS 检查 Docker（前提已自行安装并启动 Docker Desktop / OrbStack / Colima，不做任何安装）
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
# 本文件由 install.sh 通过 source 加载，共用其 info/warn/die/docker_ready，请勿单独执行。

ensure_docker_macos() {
    command -v docker >/dev/null 2>&1 || die "未检测到 docker 命令。macOS 请先安装 Docker Desktop（https://www.docker.com/products/docker-desktop/）并启动，再运行本脚本。"
    docker_ready || die "Docker 未运行。请先启动 Docker Desktop（或 OrbStack/Colima），待状态为 Running 后重新运行本脚本。"
}