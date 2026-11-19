#!/usr/bin/env bash
####################################
# desc: 为已有项目登记一个站点：nginx 虚拟主机 + 重载 nginx。域名交互选择：
#       默认 <name>.xqkeji.dev（mkcert 本地证书 + hosts 解析）；其它域名走
#       nginx ACME 模块自动签发/续期 Let's Encrypt 证书（不写 hosts）
# usage: ./bin/add-site.sh <name> [project-dir]
# author: xqkeji.cn
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
####################################
# <name> 默认成为 <name>.xqkeji.dev。project-dir 默认是 www/<name>，
# 项目必须放在 www/ 下：nginx 与 php 容器只挂载了 www（容器内 /home/www），
# 放在别处容器里看不到，配置写了也是 404。
#
# 域名交互：回车用默认本地域名（mkcert 证书 + hosts，原行为不变）；输入其它
# 域名（如 crm.example.com）则用 ACME 模块自动签发公网证书。前提：该域名 DNS
# 已解析到本机公网 IP、80 端口公网可达、nginx 镜像带 ACME 模块（官方非 slim
# 镜像 1.29.4 / 1.28.1 起自带）、容器按新版 install.sh/win.bat 部署过（有 ACME
# 挂载）。非交互环境（钩子/管道）不提问直接用默认；ADD_SITE_DOMAIN 可显式指定。
#
# 幂等：conf.d/<name>.conf 已存在就不覆盖（可能已被手工改过），
# 域名已被别的虚拟主机占用就不再抢，hosts 里已解析该域名就不再追加。
# 全程不碰 default.conf，默认站点照常。
#
# 在宿主机上跑，不是在容器里跑：hosts 是宿主机的文件，重载要 docker exec。
# Windows + Docker Desktop 请用 win.bat site <name>。
# fast-admin 的 post-create 钩子找到本脚本就会自动调用它。
set -euo pipefail

# 本脚本在 bin/ 里，环境根目录是它的上一级（与 ssl.sh 的 BASE_DIR 含义一致）
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DOMAIN_SUFFIX=xqkeji.dev
CONF_DIR="$BASE_DIR/etc/nginx/conf.d"
# ACME 三件套的另外两件：main 级 load_module 片段 + http 级 issuer 配置
# （conf.d 在 http 内被 include，issuer 放这里合法）。只在首个公网域名站点时生成。
MODULES_DIR="$BASE_DIR/etc/nginx/modules-enabled"
MODULE_CONF="$MODULES_DIR/acme.conf"
ISSUER_CONF="$CONF_DIR/acme-issuer.conf"
# 本次运行新生成的文件；nginx -t 失败时全部删掉，不留半成品
CREATED_FILES=()
# 与 install.sh 的 IP_PHP 一致；nginx 容器通过它连 php-fpm
FASTCGI_PASS=172.0.0.10:9000
# 便于测试/非标准系统覆盖
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法：./bin/add-site.sh <name> [project-dir]
      域名交互选择：默认 <name>.${DOMAIN_SUFFIX}（本地证书 + hosts），
      其它域名用 ACME 模块自动签发 Let's Encrypt 证书（需公网 DNS 与 80 端口）
      例：./bin/add-site.sh crm
          ./bin/add-site.sh crm "$BASE_DIR/www/default/crm"
EOF
    exit 1
}

[ $# -ge 1 ] || usage
NAME=$1
[[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "站点名只能包含字母、数字和连字符，且以字母或数字开头：$NAME"

PROJ_ARG=${2:-$BASE_DIR/www/$NAME}
[ -d "$PROJ_ARG" ] || die "找不到项目目录：$PROJ_ARG（请先把项目创建好，或用第二个参数指定）"
PROJ=$(cd -- "$PROJ_ARG" && pwd)
DOCROOT="$PROJ/www"
[ -d "$DOCROOT" ] || die "找不到站点入口目录：$DOCROOT"

# 换算成容器内路径。宿主机 www/ 就是容器内 /home/www/，所以只能取相对部分。
case "$PROJ" in
    "$BASE_DIR/www/"*) REL=${PROJ#"$BASE_DIR/www/"} ;;
    *) die "项目必须放在 $BASE_DIR/www 下，nginx/php 容器只挂载了 www：$PROJ" ;;
esac
CONTAINER_ROOT="/home/www/$REL/www"

CONF="$CONF_DIR/$NAME.conf"
[ -d "$CONF_DIR" ] || die "缺少 $CONF_DIR，请在完整的 dnmmp 目录内运行本脚本"

# 域名交互：默认本地域名走 mkcert+hosts（原行为）；其它域名走 ACME。
# 非交互（钩子/管道）不提问直接用默认；ADD_SITE_DOMAIN 可显式指定（两平台一致）。
if [ -n "${ADD_SITE_DOMAIN:-}" ]; then
    DOMAIN=$ADD_SITE_DOMAIN
elif [ -t 0 ]; then
    read -r -p "站点域名 [$NAME.$DOMAIN_SUFFIX]（回车用默认；其它域名将用 ACME 自动签发证书）: " DOMAIN || DOMAIN=
    DOMAIN=${DOMAIN:-$NAME.$DOMAIN_SUFFIX}
else
    DOMAIN="$NAME.$DOMAIN_SUFFIX"
    info "非交互环境，使用默认本地域名 $DOMAIN"
fi
DOMAIN=$(printf '%s' "$DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
[[ $DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || die "域名格式不正确：$DOMAIN"
# mkcert 证书覆盖 *.xqkeji.dev 与 xqkeji.dev 本身，这两类走本地路径
LOCAL_MODE=
case "$DOMAIN" in
    *."$DOMAIN_SUFFIX" | "$DOMAIN_SUFFIX") LOCAL_MODE=1 ;;
esac

if [ -n "$LOCAL_MODE" ]; then
    info "添加本地站点：$DOMAIN"
else
    info "添加公网域名站点：$DOMAIN（ACME 自动签发证书）"
fi

# hosts 里是否已有该域名：按“主机名 token”精确比对，先剥掉注释，
# 再逐个比较一行里的每个名字，所以 othercrm.xqkeji.dev 不算 crm.xqkeji.dev，
# 被注释掉的那行也不算。
hosts_has() {
    [ -r "$HOSTS_FILE" ] || return 1
    awk -v d="$DOMAIN" '
        { sub(/#.*/, "")
          for (i = 2; i <= NF; i++) if (tolower($i) == tolower(d)) found = 1 }
        END { exit !found }' "$HOSTS_FILE"
}

add_hosts() {
    if hosts_has; then
        info "hosts 里已有 $DOMAIN 的解析，不重复添加"
        return 0
    fi
    local text="127.0.0.1 $DOMAIN"
    # 原文件末尾没有换行时先补一个，否则会和最后一行黏在一起
    if [ -s "$HOSTS_FILE" ] && [ -n "$(tail -c1 "$HOSTS_FILE" 2>/dev/null)" ]; then
        text=$'\n'"$text"
    fi
    if [ -w "$HOSTS_FILE" ]; then
        printf '%s\n' "$text" >> "$HOSTS_FILE"
    elif command -v sudo >/dev/null 2>&1; then
        info "写入 $HOSTS_FILE 需要 root，正在用 sudo 追加"
        sudo sh -c 'printf "%s\n" "$1" >> "$2"' _ "$text" "$HOSTS_FILE" || {
            warn "无法写入 hosts，请手动加一行：127.0.0.1 $DOMAIN"
            return 0
        }
    else
        warn "无法写入 hosts（需要 root），请手动加一行：127.0.0.1 $DOMAIN"
        return 0
    fi
    if hosts_has; then
        info "hosts 已添加：127.0.0.1 $DOMAIN"
    else
        warn "hosts 写入后仍未查到解析，请手动确认：127.0.0.1 $DOMAIN"
    fi
}

write_conf() {
    local cert_block
    if [ -n "$LOCAL_MODE" ]; then
        cert_block=$(cat <<'CERT'
	ssl_certificate     /etc/nginx/ssl/local.pem;
	ssl_certificate_key /etc/nginx/ssl/local-key.pem;
CERT
)
    else
        cert_block=$(cat <<'CERT'
	acme_certificate letsencrypt;
	ssl_certificate     $acme_certificate;
	ssl_certificate_key $acme_certificate_key;
	ssl_certificate_cache max=2;
CERT
)
    fi
    cat > "$CONF" <<EOF
# Generated by add-site.sh for $DOMAIN -- edit freely.
# Re-running add-site.sh never overwrites an existing file.
server {
	listen       443 ssl;
	server_name  $DOMAIN;
	error_log  /home/log/$NAME.log;

$cert_block
	ssl_protocols       TLSv1.2 TLSv1.3;
	ssl_ciphers         HIGH:!aNULL:!MD5;
	ssl_session_cache   shared:SSL:10m;
	ssl_session_timeout 10m;

	root    "$CONTAINER_ROOT";
	# 禁止 asset 与 upload 目录里的 php 被执行，必须排在下面的 php 处理之前
	location ~* ^/(?:asset|upload)/.*\.(?:php\d?|phtml\d?|phar)\$ {
		deny all;
	}
	location / {
		index  index.html index.htm index.php;
		autoindex  off;
		try_files \$uri \$uri/ /index.php?_url=\$uri&\$args;
	}
	location ~ \.php(.*)\$  {
		try_files		\$uri = 404;
		fastcgi_pass   $FASTCGI_PASS;
		fastcgi_index  index.php;
		fastcgi_split_path_info  ^((?U).+\.php)(/?.+)\$;
		fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
		fastcgi_param  PATH_INFO  \$fastcgi_path_info;
		fastcgi_param  PATH_TRANSLATED  \$document_root\$fastcgi_path_info;
		include        fastcgi_params;
	}
}
EOF
    CREATED_FILES+=("$CONF")
    info "已生成 $CONF"
}

# ACME 基础设施：main 级 load_module 片段 + http 级 issuer。
# 只在首个公网域名站点时生成；已存在就不覆盖（可能被手工改过）。
write_acme_base() {
    mkdir -p "$MODULES_DIR"
    if [ ! -e "$MODULE_CONF" ]; then
        printf 'load_module /usr/lib/nginx/modules/ngx_http_acme_module.so;\n' > "$MODULE_CONF"
        CREATED_FILES+=("$MODULE_CONF")
        info "已生成 $MODULE_CONF"
    fi
    if [ ! -e "$ISSUER_CONF" ]; then
        cat > "$ISSUER_CONF" <<'EOF'
# Generated by add-site.sh -- ACME issuer shared by all ACME sites.
# 127.0.0.11 是 Docker 内置 DNS；state_path 挂载在宿主机 data/nginx/acme，
# 容器重建不丢账户密钥与已签证书（避免撞 Let's Encrypt 速率限制）。
resolver 127.0.0.11 valid=30s ipv6=off;
acme_issuer letsencrypt {
    uri https://acme-v02.api.letsencrypt.org/directory;
    state_path /var/cache/nginx/acme;
    accept_terms_of_service;
}
acme_shared_zone zone=ngx_acme_shared:1M;
EOF
        CREATED_FILES+=("$ISSUER_CONF")
        info "已生成 $ISSUER_CONF"
    fi
}

# 旧版部署的 nginx 容器没有 ACME 挂载：配置写了容器里也看不到，先拦住。
check_acme_mounts() {
    command -v docker >/dev/null 2>&1 || return 0
    docker container inspect nginx >/dev/null 2>&1 || return 0
    local mounts
    mounts=$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' nginx 2>/dev/null) || return 0
    case "$mounts" in
        */etc/nginx/modules-enabled*) return 0 ;;
    esac
    die "nginx 容器缺少 ACME 挂载（旧版部署），请先重新部署：./install.sh（Windows：win.bat），再添加公网域名站点"
}

cleanup_created() {
    local f
    for f in ${CREATED_FILES[@]+"${CREATED_FILES[@]}"}; do
        rm -f "$f"
    done
}

# nginx 容器在跑才自检+重载；没跑就留给下次启动，配置照样写好。
reload_nginx() {
    command -v docker >/dev/null 2>&1 || { info "未找到 docker 命令，跳过重载"; return 0; }
    docker container inspect nginx >/dev/null 2>&1 || { info "nginx 容器不存在，下次部署会直接使用新配置"; return 0; }
    [ "$(docker inspect -f '{{.State.Running}}' nginx 2>/dev/null)" = "true" ] || {
        info "nginx 容器当前没有运行，下次启动会直接使用新配置"
        return 0
    }
    if ! docker exec nginx nginx -t; then
        cleanup_created
        die "nginx 自检未通过，已删除刚生成的配置，原有站点未受影响。若报 ngx_http_acme_module.so 找不到，说明镜像太旧：请重新部署（./install.sh / win.bat）拉取新镜像"
    fi
    docker exec nginx nginx -s reload || { warn "重载失败，请手动执行：docker exec nginx nginx -s reload"; return 0; }
    info "已通知 nginx 重新加载配置"
}

SKIP_CONF=
if [ -e "$CONF" ]; then
    info "配置已存在，不覆盖：$CONF"
    SKIP_CONF=1
elif grep -rqi -- "$DOMAIN" "$CONF_DIR" 2>/dev/null; then
    info "$DOMAIN 已被 conf.d 里其它配置使用，不再重复添加"
    SKIP_CONF=1
fi

if [ -z "$SKIP_CONF" ]; then
    if [ -z "$LOCAL_MODE" ]; then
        check_acme_mounts
        write_acme_base
    fi
    write_conf
    reload_nginx
fi
if [ -n "$LOCAL_MODE" ]; then
    add_hosts
else
    info "公网域名不写 hosts：请确保 $DOMAIN 的 DNS A 记录已指向本机公网 IP"
fi

if [ -n "$LOCAL_MODE" ]; then
    if [ -f "$BASE_DIR/etc/nginx/ssl/local.pem" ]; then
        CERT_NOTE="证书由 ssl.sh 生成，已覆盖 *.$DOMAIN_SUFFIX，无需重签"
    else
        CERT_NOTE="[警告] 未找到 etc/nginx/ssl/local.pem，请先运行 ./ssl.sh 签发证书，否则 nginx 起不来"
    fi
else
    CERT_NOTE="证书由 nginx ACME 模块自动向 Let's Encrypt 签发并续期（首次需几秒到几十秒；前提：80 端口公网可达；进度见 docker logs nginx）"
fi

cat <<EOF

站点目录：$DOCROOT（容器内 $CONTAINER_ROOT）
访问地址：https://$DOMAIN/（http://$DOMAIN/ 自动跳转 https）
$CERT_NOTE
EOF