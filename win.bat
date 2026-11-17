@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title dnmmp deploy (Windows + Docker Desktop)
REM Copyright (C) 2025-2026 xqkeji.cn
REM SPDX-License-Identifier: AGPL-3.0-or-later
REM
REM Native Windows deployment script. Requires Docker Desktop installed and running.
REM Equivalent to install.sh: deploys nginx/mysql/mongo/xqkeji on xqkeji-net
REM (172.0.0.0/24) with static IPs; nginx listens on 443 (https) and redirects 80 to 443.
REM Local HTTPS cert: mkcert.exe first (downloaded into bin\), openssl self-signed fallback.
REM Re-runnable: existing containers are removed and recreated, data\ is preserved.
REM Force re-issue cert: win.bat force  (or set FORCE=1 then re-run win.bat).
REM
REM NOTE: cmd.exe mis-parses unquoted UTF-8 Chinese on echo/REM lines under chcp 65001,
REM so every Chinese message is stored via set "MSG=..." and printed with echo !MSG!
REM (the same pattern wnmmp\bin\make-ssl.bat uses). Keep command lines ASCII.

cd /d "%~dp0"
set "BASE=%CD%"
if /i "%~1"=="force" set "FORCE=1"

echo ==============================================================
set "MSG= dnmmp 部署（Windows + Docker Desktop）"
echo !MSG!
set "MSG= docker + nginx + mysql + mongodb + php 集成开发环境"
echo !MSG!
echo ==============================================================
echo.

call :check_docker || goto :fail
call :prepare_dirs || goto :fail
call :pull_images || goto :fail
call :remove_old || goto :fail
call :ensure_network || goto :fail
call :make_ssl || goto :fail
call :run_containers || goto :fail
call :verify
call :summary
echo.
set "MSG=[√] 部署完成。"
echo !MSG!
pause
exit /b 0

:fail
echo.
set "MSG=部署未完成，请根据上面的错误处理后重新运行 win.bat。"
echo !MSG!
pause
exit /b 1

REM ===================== check Docker Desktop =====================
:check_docker
docker --version >nul 2>&1
if errorlevel 1 (
  set "MSG=[错误] 未找到 docker 命令。请先安装 Docker Desktop 并启动。"
  echo !MSG!
  exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  set "MSG=[错误] Docker 未在运行。请启动 Docker Desktop，待其就绪后重试。"
  echo !MSG!
  exit /b 1
)
set "DVER="
for /f "delims=" %%v in ('docker version --format "{{.Server.Version}}" 2^>nul') do set "DVER=%%v"
set "MSG=[√] Docker 服务端版本：!DVER!"
echo !MSG!
exit /b 0

REM ===================== prepare dirs and required config =====================
:prepare_dirs
for %%d in (code www log\nginx log\mysql log\mongo log\php data\mysql data\mongo etc\nginx\ssl) do (
  if not exist "%BASE%\%%d" md "%BASE%\%%d"
)
for %%f in (etc\nginx\nginx.conf etc\php\php.ini etc\mongo\mongodb.conf) do (
  if not exist "%BASE%\%%f" (
    set "MSG=[错误] 缺少 %%f，请在完整的 dnmmp 目录内运行 win.bat"
    echo !MSG!
    exit /b 1
  )
)
for %%d in (etc\nginx\conf.d etc\mysql) do (
  if not exist "%BASE%\%%d" (
    set "MSG=[错误] 缺少 %%d 目录，请在完整的 dnmmp 目录内运行 win.bat"
    echo !MSG!
    exit /b 1
  )
)
exit /b 0

REM ===================== pull images (retry once on failure) =====================
:pull_images
for %%i in (nginx mysql mongo xqkeji/xqkeji) do (
  set "MSG=拉取镜像 %%i"
  echo !MSG!
  docker pull %%i
  if errorlevel 1 (
    set "MSG=[警告] 拉取 %%i 失败，5 秒后重试"
    echo !MSG!
    timeout /t 5 >nul
    docker pull %%i
    if errorlevel 1 (
      set "MSG=[错误] 镜像 %%i 拉取失败。请检查网络，或在 Docker Desktop 配置可用的 registry-mirrors 后重试。"
      echo !MSG!
      exit /b 1
    )
  )
)
exit /b 0

REM ===================== remove existing containers (data preserved) =====================
:remove_old
for %%c in (nginx mysql mongo xqkeji) do (
  docker container inspect %%c >nul 2>&1
  if not errorlevel 1 (
    set "MSG=重新创建已存在的容器 %%c（数据库数据保留在 data\ 目录）"
    echo !MSG!
    docker rm -f %%c >nul 2>&1
  )
)
exit /b 0

REM ===================== ensure network (reuse if subnet matches) =====================
:ensure_network
docker network inspect xqkeji-net >nul 2>&1
if errorlevel 1 (
  docker network create --subnet 172.0.0.0/24 xqkeji-net >nul
  set "MSG=[√] 已创建网络 xqkeji-net（172.0.0.0/24）"
  echo !MSG!
  exit /b 0
)
set "SUBNET="
for /f "delims=" %%s in ('docker network inspect -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}" xqkeji-net 2^>nul') do set "SUBNET=%%s"
if "!SUBNET!"=="172.0.0.0/24" (
  set "MSG=[√] 复用已存在的网络 xqkeji-net（172.0.0.0/24）"
  echo !MSG!
  exit /b 0
)
set "MSG=[警告] 已存在的 xqkeji-net 网段为 !SUBNET!，与 172.0.0.0/24 不符，重新创建"
echo !MSG!
docker network rm xqkeji-net >nul 2>&1
docker network create --subnet 172.0.0.0/24 xqkeji-net >nul
set "MSG=[√] 已创建网络 xqkeji-net（172.0.0.0/24）"
echo !MSG!
exit /b 0

REM ===================== local HTTPS certificate =====================
:make_ssl
set "SSL_DIR=%BASE%\etc\nginx\ssl"
set "CERT=%SSL_DIR%\local.pem"
set "KEY=%SSL_DIR%\local-key.pem"
if not exist "%SSL_DIR%" md "%SSL_DIR%"
if exist "%CERT%" if exist "%KEY%" (
  if not "%FORCE%"=="1" (
    set "MSG=[√] 已存在本地证书，跳过签发（强制重签：win.bat force）"
    echo !MSG!
    exit /b 0
  )
)
call :gen_mkcert && exit /b 0
call :gen_openssl && exit /b 0
set "MSG=[错误] 证书生成失败：mkcert 与 openssl 均不可用。"
echo !MSG!
set "MSG=       请安装 Git for Windows（自带 openssl），或手动把 mkcert.exe 放到 bin\ 后重试。"
echo !MSG!
exit /b 1

REM ---- mkcert primary: trusted local CA, browser green lock ----
:gen_mkcert
set "MKCERT=%BASE%\bin\mkcert.exe"
set "ARCH=amd64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"
set "MKCERT_URL=https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-windows-%ARCH%.exe"
if not exist "%BASE%\bin" md "%BASE%\bin"
if exist "%MKCERT%" (
  "%MKCERT%" -CAROOT >nul 2>&1
  if errorlevel 1 del "%MKCERT%" >nul 2>&1
)
if not exist "%MKCERT%" (
  for /l %%i in (1,1,3) do (
    if not exist "%MKCERT%" (
      set "MSG=  下载 mkcert v1.4.4（windows-%ARCH%，第 %%i/3 次）..."
      echo !MSG!
      curl.exe -fsSL --retry 2 --max-time 120 -o "%MKCERT%" "%MKCERT_URL%" >nul 2>&1
      if exist "%MKCERT%" (
        "%MKCERT%" -CAROOT >nul 2>&1
        if errorlevel 1 del "%MKCERT%" >nul 2>&1
      )
      if not exist "%MKCERT%" timeout /t 3 >nul
    )
  )
)
if not exist "%MKCERT%" exit /b 1
set "MSG=使用 mkcert 本地 CA 签发受信任证书"
echo !MSG!
"%MKCERT%" -install >nul 2>&1
if errorlevel 1 (
  set "MSG=[警告] mkcert -install 未完全成功（装入信任库可能需更高权限），证书仍会生成"
  echo !MSG!
)
"%MKCERT%" -cert-file "%CERT%" -key-file "%KEY%" localhost 127.0.0.1 ::1 *.xqkeji.dev xqkeji.dev
if errorlevel 1 exit /b 1
if not exist "%CERT%" exit /b 1
if not exist "%KEY%" exit /b 1
set "MSG=[√] 证书：%CERT%"
echo !MSG!
set "MSG=[√] 私钥：%KEY%"
echo !MSG!
set "CAROOT="
for /f "delims=" %%c in ('"%MKCERT%" -CAROOT 2^>nul') do set "CAROOT=%%c"
if defined CAROOT (
  set "MSG=[√] 本地 CA 目录：!CAROOT!（mkcert -install 已尝试装入 Windows 信任库）"
  echo !MSG!
)
exit /b 0

REM ---- openssl fallback: self-signed, browser shows untrusted (fine for testing) ----
:gen_openssl
set "OPENSSL="
where openssl >nul 2>&1
if not errorlevel 1 set "OPENSSL=openssl"
if not defined OPENSSL if exist "%ProgramFiles%\Git\mingw64\bin\openssl.exe" set "OPENSSL=%ProgramFiles%\Git\mingw64\bin\openssl.exe"
if not defined OPENSSL if exist "%ProgramFiles%\Git\usr\bin\openssl.exe" set "OPENSSL=%ProgramFiles%\Git\usr\bin\openssl.exe"
if not defined OPENSSL exit /b 1
set "MSG=[警告] 改用 openssl 自签证书：浏览器会提示不受信任（测试无碍）"
echo !MSG!
set "CNF=%TEMP%\dnmmp-ssl-%RANDOM%.cnf"
> "%CNF%" (
  echo [req]
  echo distinguished_name=dn
  echo x509_extensions=v3
  echo prompt=no
  echo [dn]
  echo CN=localhost
  echo O=dnmmp local dev
  echo [v3]
  echo subjectAltName=@alt
  echo basicConstraints=CA:FALSE
  echo keyUsage=digitalSignature,keyEncipherment
  echo extendedKeyUsage=serverAuth
  echo [alt]
  echo DNS.1=localhost
  echo DNS.2=*.xqkeji.dev
  echo DNS.3=xqkeji.dev
  echo IP.1=127.0.0.1
  echo IP.2=::1
)
"%OPENSSL%" req -x509 -nodes -newkey rsa:2048 -days 825 -keyout "%KEY%" -out "%CERT%" -config "%CNF%" >nul 2>&1
set "RC=%errorlevel%"
del "%CNF%" >nul 2>&1
if not "%RC%"=="0" exit /b 1
if not exist "%CERT%" exit /b 1
if not exist "%KEY%" exit /b 1
set "MSG=[√] 证书：%CERT%"
echo !MSG!
set "MSG=[√] 私钥：%KEY%"
echo !MSG!
exit /b 0

REM ===================== start the four containers =====================
:run_containers
set "MSG=启动 nginx 容器"
echo !MSG!
docker run -d --name nginx --restart=always ^
  --network xqkeji-net --ip 172.0.0.2 -p 80:80 -p 443:443 ^
  -v "%BASE%\www:/home/www" ^
  -v "%BASE%\log\nginx:/home/log" ^
  -v "%BASE%\etc\nginx\nginx.conf:/etc/nginx/nginx.conf" ^
  -v "%BASE%\etc\nginx\conf.d:/etc/nginx/conf.d" ^
  -v "%BASE%\etc\nginx\ssl:/etc/nginx/ssl:ro" ^
  nginx >nul
if errorlevel 1 (
  set "MSG=[错误] 启动 nginx 容器失败（常见原因：80/443 被占用，或 dnmmp 目录不在 Docker Desktop 共享盘）"
  echo !MSG!
  exit /b 1
)

set "MSG=启动 mysql 容器"
echo !MSG!
docker run -d --name mysql --restart=always ^
  --network xqkeji-net --ip 172.0.0.200 -p 3306:3306 ^
  -v "%BASE%\etc\mysql:/etc/mysql/conf.d" ^
  -v "%BASE%\log\mysql:/logs" ^
  -v "%BASE%\data\mysql:/var/lib/mysql" ^
  -e MYSQL_ROOT_PASSWORD=xqkeji.cn ^
  mysql >nul
if errorlevel 1 (
  set "MSG=[错误] 启动 mysql 容器失败（常见原因：3306 被占用）"
  echo !MSG!
  exit /b 1
)

set "MSG=启动 mongo 容器"
echo !MSG!
docker run -d --name mongo --restart=always ^
  --network xqkeji-net --ip 172.0.0.100 -p 27017:27017 ^
  -v "%BASE%\log\mongo:/home/log" ^
  -v "%BASE%\etc\mongo:/home/configdb" ^
  -v "%BASE%\data\mongo:/data/db" ^
  -e MONGO_INITDB_ROOT_USERNAME=root ^
  -e MONGO_INITDB_ROOT_PASSWORD=xqkeji.cn ^
  mongo --config /home/configdb/mongodb.conf >nul
if errorlevel 1 (
  set "MSG=[错误] 启动 mongo 容器失败（常见原因：27017 被占用）"
  echo !MSG!
  exit /b 1
)

set "MSG=启动 xqkeji（php-fpm）容器"
echo !MSG!
docker run -d --name xqkeji --restart=always ^
  --network xqkeji-net --ip 172.0.0.10 -p 9000:9000 ^
  -v "%BASE%\code:/home/code" ^
  -v "%BASE%\www:/home/www" ^
  -v "%BASE%\etc\php\php.ini:/usr/local/etc/php/php.ini" ^
  -v "%BASE%\log\php:/home/log" ^
  xqkeji/xqkeji >nul
if errorlevel 1 (
  set "MSG=[错误] 启动 xqkeji 容器失败（常见原因：9000 被占用）"
  echo !MSG!
  exit /b 1
)
exit /b 0

REM ===================== verify site reachability =====================
:verify
where curl.exe >nul 2>&1
if errorlevel 1 (
  set "MSG=[警告] 未找到 curl，跳过站点连通性检查"
  echo !MSG!
  exit /b 0
)
for /l %%i in (1,1,30) do (
  curl.exe -fsSk -o nul --max-time 3 https://127.0.0.1/ >nul 2>&1
  if not errorlevel 1 (
    set "MSG=[√] 站点已可访问：https://127.0.0.1/（80 自动跳转 443）"
    echo !MSG!
    exit /b 0
  )
  timeout /t 1 >nul
)
set "MSG=[警告] 30 秒内 https://127.0.0.1/ 未响应，请检查：docker ps 与 docker logs nginx"
echo !MSG!
exit /b 0

REM ===================== print status and connection info =====================
:summary
echo.
docker ps --filter "network=xqkeji-net" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo.
set "MSG=站点目录：%BASE%\www\default"
echo !MSG!
set "MSG=访问地址：https://127.0.0.1/（http://127.0.0.1/ 自动跳转 https）"
echo !MSG!
set "MSG=MySQL   ：127.0.0.1:3306   root / xqkeji.cn"
echo !MSG!
set "MSG=MongoDB ：127.0.0.1:27017  root / xqkeji.cn"
echo !MSG!
set "MSG=PHP-FPM ：127.0.0.1:9000   容器内 172.0.0.10:9000"
echo !MSG!
set "MSG=数据目录：%BASE%\data"
echo !MSG!
set "MSG=日志目录：%BASE%\log"
echo !MSG!
echo.
set "MSG=容器已设置 --restart=always，Docker 启动后会自动运行。"
echo !MSG!
set "MSG=常用命令：docker stop nginx mysql mongo xqkeji / docker start nginx mysql mongo xqkeji"
echo !MSG!
set "MSG=子域名要自己写进 hosts，例如：127.0.0.1 crm.xqkeji.dev"
echo !MSG!
exit /b 0
