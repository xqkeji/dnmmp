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
REM MySQL is optional: the installer asks [Y/n], default is install.
REM Unattended skip: win.bat no-mysql  (combinable: win.bat force no-mysql).
REM Pin image versions: win.bat --tag mysql=8.0 --tag nginx=1.27  (repeatable;
REM names: nginx / mysql / mongo / xqkeji). Without --tag images follow latest.
REM Back up data\ before recreate: win.bat backup-data  (opt-in, can be slow).
REM Start/stop installed containers: win.bat start / win.bat stop.
REM Self-upgrade from the latest GitHub tag: win.bat upgrade
REM   (force / backup-data / --local <zip> supported; see bin\upgrade.ps1).
REM Register one site: win.bat site <name> [project-dir]  (vhost + reload).
REM   Interactive domain: default <name>.xqkeji.dev = mkcert cert + hosts entry;
REM   any other domain = ACME auto-issued Let's Encrypt cert (no hosts entry).
REM   ADD_SITE_DOMAIN=<fqdn> overrides the prompt (scripts / hooks).
REM
REM NOTE: cmd.exe mis-parses unquoted UTF-8 Chinese on echo/REM lines under chcp 65001,
REM so every Chinese message is stored via set "MSG=..." and printed with echo !MSG!
REM (the same pattern wnmmp\bin\make-ssl.bat uses). Keep command lines ASCII.

cd /d "%~dp0"
set "BASE=%CD%"
set "FORCE=0"
set "NO_MYSQL=0"
set "BACKUP_DATA=0"
set "TAG_nginx="
set "TAG_mysql="
set "TAG_mongo="
set "TAG_xqkeji="
REM win.bat site <name> [project-dir] -- register one local site without
REM redeploying: nginx vhost + hosts entry + reload. See :add_site below.
if /i "%~1"=="site" goto :add_site
if /i "%~1"=="start" goto :start_env
if /i "%~1"=="stop" goto :stop_env
if /i "%~1"=="upgrade" goto :upgrade_handoff

REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:arg_loop
if "%~1"=="" goto :arg_done
if /i "%~1"=="force" (
  set "FORCE=1"
  shift
  goto :arg_loop
)
if /i "%~1"=="no-mysql" (
  set "NO_MYSQL=1"
  shift
  goto :arg_loop
)
if /i "%~1"=="backup-data" (
  set "BACKUP_DATA=1"
  shift
  goto :arg_loop
)
if /i "%~1"=="--tag" (
  REM cmd splits unquoted name=tag at the '=' into two args; rejoin them.
  set "TAGARG=%~2"
  set "TAGSHIFT=2"
  set "HASEQ="
  for /f "tokens=1,* delims==" %%a in ("!TAGARG!") do if not "%%b"=="" set "HASEQ=1"
  if defined TAGARG if not defined HASEQ if not "%~3"=="" (
    set "TAGARG=!TAGARG!=%~3"
    set "TAGSHIFT=3"
  )
  call :parse_tag "!TAGARG!" || goto :fail
  if "!TAGSHIFT!"=="3" shift
  shift
  shift
  goto :arg_loop
)
set "MSG=[错误] 未知参数：%~1（可用：force / no-mysql / backup-data / --tag 镜像名=tag）"
echo !MSG!
goto :fail
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:arg_done
goto :deploy_start

REM ===================== raw argument value (bypass cmd '=' splitting) =====================
REM cmd splits UNQUOTED batch parameters at spaces and '=', so %3 cannot
REM carry values like name=tag or paths containing '=' or spaces. %* keeps
REM the original text; locate RAW_FLAG in it and return the verbatim remainder
REM (up to the next known flag when RAW_STOP=1), outer quotes stripped.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:raw_value
set "RAW_VALUE="
for /f "usebackq delims=" %%v in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=$env:RAW_TAIL; $f=$env:RAW_FLAG; $ms=[regex]::Matches($t,'\S+'); $idx=-1; for($i=0;$i -lt $ms.Count;$i++){ if($ms[$i].Value.Trim([char]34) -ieq $f){ $idx=$i; break } }; if($idx -ge 0){ $start=$ms[$idx].Index+$ms[$idx].Length; $end=$t.Length; if($env:RAW_STOP){ for($j=$idx+1;$j -lt $ms.Count;$j++){ $v=$ms[$j].Value.Trim([char]34); if($v -ieq 'force' -or $v -ieq '--force' -or $v -ieq 'backup-data' -or $v -ieq '--backup-data' -or $v -ieq '--local'){ $end=$ms[$j].Index; break } } }; $val=$t.Substring($start,$end-$start).Trim(); if($val.Length -ge 2 -and $val[0] -eq [char]34 -and $val[$val.Length-1] -eq [char]34){ $val=$val.Substring(1,$val.Length-2) }; Write-Output $val }"`) do set "RAW_VALUE=%%v"
exit /b 0

REM ===================== parse --tag name=tag =====================
REM Whitelist: nginx / mysql / mongo / xqkeji (xqkeji maps to xqkeji/xqkeji).
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:parse_tag
set "TV=%~1"
if not defined TV (
  set "MSG=[错误] --tag 需要参数，形如 --tag mysql=8.0"
  echo !MSG!
  exit /b 1
)
set "TN="
set "TT="
for /f "tokens=1,* delims==" %%a in ("!TV!") do (
  set "TN=%%a"
  set "TT=%%b"
)
if not defined TT (
  set "MSG=[错误] --tag 格式应为 镜像名=tag，如 mysql=8.0（可用：nginx / mysql / mongo / xqkeji）"
  echo !MSG!
  exit /b 1
)
set "TAGOK=0"
for %%k in (nginx mysql mongo xqkeji) do if /i "!TN!"=="%%k" set "TAGOK=1"
if "!TAGOK!"=="0" (
  set "MSG=[错误] --tag 不支持的镜像名：!TN!（可用：nginx / mysql / mongo / xqkeji）"
  echo !MSG!
  exit /b 1
)
set "TAG_!TN!=!TT!"
set "MSG=[√] 已固定镜像版本：!TN!:!TT!"
echo !MSG!
exit /b 0

REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:deploy_start
echo ==============================================================
set "MSG= dnmmp 部署（Windows + Docker Desktop）"
echo !MSG!
set "MSG= docker + nginx + mysql + mongodb + php 集成开发环境"
echo !MSG!
echo ==============================================================
echo.

call :check_docker || goto :fail
call :ask_mysql
call :prepare_dirs || goto :fail
call :pull_images || goto :fail
call :backup_data || goto :fail
call :warn_db_upgrade
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

REM ===================== ask whether to install MySQL =====================
REM Default is install (Enter or y). n skips it; data\mysql is preserved.
REM win.bat no-mysql skips the prompt entirely (unattended opt-out).
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:ask_mysql
set "WITH_MYSQL=1"
if "%NO_MYSQL%"=="1" (
  set "WITH_MYSQL=0"
  set "MSG=按参数跳过 MySQL 容器（data\mysql 旧数据保留）"
  echo !MSG!
  exit /b 0
)
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:ask_mysql_prompt
set "MSG=是否安装 MySQL 容器？[Y/n]（默认安装）: "
set /p "=!MSG!" <nul
set "MYSQL_ANS="
set /p "MYSQL_ANS="
if "!MYSQL_ANS!"=="" exit /b 0
if /i "!MYSQL_ANS!"=="y" exit /b 0
if /i "!MYSQL_ANS!"=="n" (
  set "WITH_MYSQL=0"
  set "MSG=跳过 MySQL 容器（data\mysql 旧数据保留）"
  echo !MSG!
  exit /b 0
)
set "MSG=[警告] 请输入 y 或 n（直接回车默认安装）"
echo !MSG!
goto :ask_mysql_prompt

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
for %%d in (code www log\nginx log\mongo log\php data\mongo etc\nginx\ssl etc\nginx\modules-enabled data\nginx\acme) do (
  if not exist "%BASE%\%%d" md "%BASE%\%%d"
)
if "%WITH_MYSQL%"=="1" for %%d in (log\mysql data\mysql) do (
  if not exist "%BASE%\%%d" md "%BASE%\%%d"
)
for %%f in (etc\nginx\nginx.conf etc\php\php.ini etc\mongo\mongodb.conf) do (
  if not exist "%BASE%\%%f" (
    set "MSG=[错误] 缺少 %%f，请在完整的 dnmmp 目录内运行 win.bat"
    echo !MSG!
    exit /b 1
  )
)
for %%d in (etc\nginx\conf.d) do (
  if not exist "%BASE%\%%d" (
    set "MSG=[错误] 缺少 %%d 目录，请在完整的 dnmmp 目录内运行 win.bat"
    echo !MSG!
    exit /b 1
  )
)
if "%WITH_MYSQL%"=="1" if not exist "%BASE%\etc\mysql" (
  set "MSG=[错误] 缺少 etc\mysql 目录，请在完整的 dnmmp 目录内运行 win.bat"
  echo !MSG!
  exit /b 1
)
exit /b 0

REM ===================== image reference (latest or pinned tag) =====================
REM %1 = full image name, %2 = short whitelist key; sets REF for the caller.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:image_ref
set "REF=%~1"
if defined TAG_%~2 set "REF=%~1:!TAG_%~2!"
exit /b 0

REM ===================== pull images (retry once, local fallback) =====================
:pull_images
set "IMG_LIST="
for %%i in (nginx mysql mongo xqkeji/xqkeji) do (
  if /i "%%i"=="mysql" (
    if "%WITH_MYSQL%"=="1" (
      for %%k in ("%%i") do call :image_ref "%%i" "%%~nk"
      set "IMG_LIST=!IMG_LIST! !REF!"
      call :pull_one "!REF!" || exit /b 1
    )
  ) else (
    for %%k in ("%%i") do call :image_ref "%%i" "%%~nk"
    set "IMG_LIST=!IMG_LIST! !REF!"
    call :pull_one "!REF!" || exit /b 1
  )
)
exit /b 0

REM ---- pull one image; output goes to a temp log so the Status line can be
REM ---- translated (for /f would swallow errorlevel). Retry once after 5s;
REM ---- if that fails but a local image exists, warn and continue with it.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:pull_one
set "MSG=拉取镜像 %~1"
echo !MSG!
set "PLOG=%TEMP%\dnmmp-pull-%RANDOM%.log"
docker pull %~1 > "!PLOG!" 2>&1
if errorlevel 1 (
  set "MSG=[警告] 拉取 %~1 失败，5 秒后重试"
  echo !MSG!
  timeout /t 5 >nul
  docker pull %~1 > "!PLOG!" 2>&1
  if errorlevel 1 (
    docker image inspect %~1 >nul 2>&1
    if not errorlevel 1 (
      set "MSG=[警告] 拉取仍失败，使用本地已有镜像 %~1 继续（可能不是最新版）"
      echo !MSG!
      del "!PLOG!" >nul 2>&1
      exit /b 0
    )
    set "MSG=[错误] 镜像 %~1 拉取失败且本地不存在。请检查网络，或在 Docker Desktop 配置可用的 registry-mirrors 后重试。"
    echo !MSG!
    del "!PLOG!" >nul 2>&1
    exit /b 1
  )
  set "MSG=[√] %~1 重试拉取成功"
  echo !MSG!
  del "!PLOG!" >nul 2>&1
  exit /b 0
)
findstr /c:"Image is up to date" "!PLOG!" >nul 2>&1
if not errorlevel 1 (
  set "MSG=[√] %~1 已是最新"
  echo !MSG!
)
findstr /c:"Downloaded newer image" "!PLOG!" >nul 2>&1
if not errorlevel 1 (
  set "MSG=[√] %~1 已更新到新版"
  echo !MSG!
)
del "!PLOG!" >nul 2>&1
exit /b 0

REM ===================== optional data\ backup before recreate =====================
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:backup_data
if not "%BACKUP_DATA%"=="1" exit /b 0
if not exist "%BASE%\data" (
  set "MSG=[警告] data\ 不存在，跳过备份"
  echo !MSG!
  exit /b 0
)
set "STAMP="
for /f "delims=" %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%t"
set "DEST=%BASE%\data.backup-!STAMP!"
set "MSG=备份 data\ 到 !DEST!（可能耗时，取决于数据量）"
echo !MSG!
xcopy "%BASE%\data" "!DEST!\" /e /i /h /q >nul
if errorlevel 1 (
  set "MSG=[错误] 备份 data\ 失败，中止部署。请检查磁盘空间与权限后重试。"
  echo !MSG!
  exit /b 1
)
set "MSG=[√] 备份完成：!DEST!"
echo !MSG!
exit /b 0

REM ===================== warn about latest-tag database upgrades =====================
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:warn_db_upgrade
set "DBFOUND=0"
for %%c in (mysql mongo) do (
  docker container inspect %%c >nul 2>&1
  if not errorlevel 1 set "DBFOUND=1"
)
if "!DBFOUND!"=="0" exit /b 0
set "MSG=[警告] mysql/mongo 镜像跟随 latest：跨大版本升级可能无法启动旧数据。担心请先备份（win.bat backup-data 自动备份 data\）；升坏可用 --tag mysql=<旧版> 重跑回退"
echo !MSG!
exit /b 0

REM ===================== remove existing containers (data preserved) =====================
:remove_old
for %%c in (nginx mysql mongo xqkeji) do (
  docker container inspect %%c >nul 2>&1
  if not errorlevel 1 (
    set "MSG=重新创建已存在的容器 %%c（数据库数据保留在 data\ 目录）"
    if /i "%%c"=="mysql" if "%WITH_MYSQL%"=="0" set "MSG=按选择移除已存在的 mysql 容器（数据保留在 data\mysql）"
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
call :image_ref nginx nginx
docker run -d --name nginx --restart=always ^
  --network xqkeji-net --ip 172.0.0.2 -p 80:80 -p 443:443 ^
  -v "%BASE%\www:/home/www" ^
  -v "%BASE%\log\nginx:/home/log" ^
  -v "%BASE%\etc\nginx\nginx.conf:/etc/nginx/nginx.conf" ^
  -v "%BASE%\etc\nginx\conf.d:/etc/nginx/conf.d" ^
  -v "%BASE%\etc\nginx\modules-enabled:/etc/nginx/modules-enabled" ^
  -v "%BASE%\etc\nginx\ssl:/etc/nginx/ssl:ro" ^
  -v "%BASE%\data\nginx\acme:/var/cache/nginx/acme" ^
  !REF! >nul
if errorlevel 1 (
  set "MSG=[错误] 启动 nginx 容器失败（常见原因：80/443 被占用，或 dnmmp 目录不在 Docker Desktop 共享盘）"
  echo !MSG!
  exit /b 1
)

if "%WITH_MYSQL%"=="0" goto :run_mongo
set "MSG=启动 mysql 容器"
echo !MSG!
call :image_ref mysql mysql
docker run -d --name mysql --restart=always ^
  --network xqkeji-net --ip 172.0.0.200 -p 3306:3306 ^
  -v "%BASE%\etc\mysql:/etc/mysql/conf.d" ^
  -v "%BASE%\log\mysql:/logs" ^
  -v "%BASE%\data\mysql:/var/lib/mysql" ^
  -e MYSQL_ROOT_PASSWORD=xqkeji.cn ^
  !REF! >nul
if errorlevel 1 (
  set "MSG=[错误] 启动 mysql 容器失败（常见原因：3306 被占用）"
  echo !MSG!
  exit /b 1
)

REM ---- mysql block above is skipped when WITH_MYSQL=0 ----
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:run_mongo
set "MSG=启动 mongo 容器"
echo !MSG!
call :image_ref mongo mongo
docker run -d --name mongo --restart=always ^
  --network xqkeji-net --ip 172.0.0.100 -p 27017:27017 ^
  -v "%BASE%\log\mongo:/home/log" ^
  -v "%BASE%\etc\mongo:/home/configdb" ^
  -v "%BASE%\data\mongo:/data/db" ^
  -e MONGO_INITDB_ROOT_USERNAME=root ^
  -e MONGO_INITDB_ROOT_PASSWORD=xqkeji.cn ^
  !REF! --config /home/configdb/mongodb.conf >nul
if errorlevel 1 (
  set "MSG=[错误] 启动 mongo 容器失败（常见原因：27017 被占用）"
  echo !MSG!
  exit /b 1
)

set "MSG=启动 xqkeji（php-fpm）容器"
echo !MSG!
call :image_ref xqkeji/xqkeji xqkeji
docker run -d --name xqkeji --restart=always ^
  --network xqkeji-net --ip 172.0.0.10 -p 9000:9000 ^
  -v "%BASE%\code:/home/code" ^
  -v "%BASE%\www:/home/www" ^
  -v "%BASE%\etc\php\php.ini:/usr/local/etc/php/php.ini" ^
  -v "%BASE%\log\php:/home/log" ^
  !REF! >nul
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
if "%WITH_MYSQL%"=="1" (
  set "MSG=MySQL   ：127.0.0.1:3306   root / xqkeji.cn"
) else (
  set "MSG=MySQL   ：本次未安装（data\mysql 旧数据保留；需要时重跑 win.bat 并确认安装）"
)
echo !MSG!
set "MSG=MongoDB ：127.0.0.1:27017  root / xqkeji.cn"
echo !MSG!
set "MSG=PHP-FPM ：127.0.0.1:9000   容器内 172.0.0.10:9000"
echo !MSG!
set "MSG=数据目录：%BASE%\data"
echo !MSG!
set "MSG=日志目录：%BASE%\log"
echo !MSG!
set "MSG=使用镜像：!IMG_LIST!"
echo !MSG!
echo.
set "MSG=容器已设置 --restart=always，Docker 启动后会自动运行。"
echo !MSG!
set "MSG=常用命令：win.bat start 启动 / win.bat stop 停止（Linux/macOS：./start.sh / ./stop.sh）"
echo !MSG!
set "MSG=自动升级：win.bat upgrade（Linux/macOS：./upgrade.sh）"
echo !MSG!
set "MSG=子域名用 win.bat site <name> 自动登记（nginx 配置 + hosts + 重载），例如：win.bat site crm"
echo !MSG!
exit /b 0

REM ===================== add-site: register one local site =====================
REM win.bat site <name> [project-dir]
REM
REM The Windows counterpart of bin/add-site.sh: writes etc\nginx\conf.d\<name>.conf,
REM then reloads nginx in its container. The domain is asked interactively: the
REM default <name>.xqkeji.dev keeps the local path (mkcert cert + 127.0.0.1 hosts
REM entry); any other domain switches to ACME (Let's Encrypt) auto-issuance via
REM the nginx acme module and skips hosts. Does NOT redeploy anything, so it is
REM safe to run on a live env.
REM
REM Idempotent: an existing <name>.conf is never overwritten, a domain already
REM claimed by another vhost is not claimed twice, and a hosts entry that already
REM resolves the domain is not appended again. default.conf is never touched.
REM
REM The project must live under www\ : that is the only directory mounted into
REM the nginx and php containers (as /home/www), so the vhost root is written as
REM a CONTAINER path, not a Windows path.
REM
REM fast-admin's post-create hook calls this automatically when it finds win.bat
REM next to the project. Inside the php container it cannot be found (the dnmmp
REM root is not mounted there), so the hook prints this command instead.
REM ---- keep the lines above this label 100% ASCII: cmd.exe locates a
REM ---- CALL/GOTO target label by byte offset inside a UTF-8 batch file,
REM ---- and the Chinese text elsewhere in this file makes that offset
REM ---- drift, so execution can land a few lines ABOVE the label. Whatever
REM ---- sits there then runs, so it has to stay a harmless ASCII remark.
REM ----
REM ----
REM ----
:add_site
set "NAME=%~2"
REM cmd splits unquoted paths at '=' and spaces, so the project path is taken
REM verbatim from the raw argument tail %* (everything after the site name).
set "RAW_TAIL=%*"
set "RAW_FLAG=%~2"
set "RAW_STOP="
set "RAW_VALUE="
call :raw_value
set "PROJ_ARG=!RAW_VALUE!"
if not defined NAME goto :site_usage
REM Validation goes through PowerShell, not findstr: findstr's regex character
REM classes are case-INsensitive ([a-z] matches CRM), and piping a variable into
REM it is unsafe -- the left side of a pipe runs in a child cmd that re-parses
REM the expanded text, so a name like a&b really does execute b. The name is
REM handed over as an environment variable, so it is never part of the command
REM text and cannot inject anything.
set "AS_NAME=%NAME%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "if($env:AS_NAME -match '^[A-Za-z0-9][A-Za-z0-9-]*$'){exit 0}else{exit 1}"
if errorlevel 1 goto :site_bad_name
if defined PROJ_ARG (
  for %%i in ("%PROJ_ARG%") do set "PROJ=%%~fi"
) else (
  set "PROJ=%BASE%\www\%NAME%"
)
set "DOCROOT=%PROJ%\www"
if not exist "%DOCROOT%" goto :site_no_docroot
REM Host www\ == container /home/www/, so only the part below www\ is usable.
REM OrdinalIgnoreCase because a user may type the path in a different case.
set "AS_PROJ=%PROJ%"
set "AS_WWW=%BASE%\www\"
set "REL="
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:AS_PROJ; $b=$env:AS_WWW; if($p.StartsWith($b,[System.StringComparison]::OrdinalIgnoreCase)){ $p.Substring($b.Length).Replace([char]92,[char]47) }"') do set "REL=%%r"
if not defined REL goto :site_outside
set "CONTAINER_ROOT=/home/www/%REL%/www"
set "CONF=%BASE%\etc\nginx\conf.d\%NAME%.conf"
set "HOSTS_FILE=%SystemRoot%\System32\drivers\etc\hosts"
REM Override for tests / non-standard Windows directories.
if defined ADD_SITE_HOSTS set "HOSTS_FILE=%ADD_SITE_HOSTS%"
REM Interactive domain choice (parity with bin/add-site.sh): Enter keeps the
REM default <name>.xqkeji.dev local path (mkcert + hosts); any other domain
REM switches to ACME auto-issuance. ADD_SITE_DOMAIN overrides without asking.
REM set /p with redirected stdin returns at once leaving DOMAIN unset, which
REM falls back to the default -- the equivalent of the sh [ -t 0 ] guard.
REM The prompt text goes through MSG (Chinese on a command line mis-parses
REM under chcp 65001); the set /p prompt itself stays ASCII.
if defined ADD_SITE_DOMAIN (
  set "DOMAIN=!ADD_SITE_DOMAIN!"
) else (
  set "MSG=站点域名 [默认 %NAME%.xqkeji.dev]（回车用默认；其它域名将用 ACME 自动签发证书）："
  echo !MSG!
  set "DOMAIN="
  set /p "DOMAIN=> "
  if not defined DOMAIN set "DOMAIN=%NAME%.xqkeji.dev"
)
REM Validate + lowercase + strip whitespace via PowerShell (env-var handover,
REM no interpolation into the command text). Invalid input produces no output,
REM leaving DOMAIN unset.
set "AS_DOMAIN_IN=!DOMAIN!"
set "DOMAIN="
for /f "delims=" %%d in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=($env:AS_DOMAIN_IN -replace '\s',''); if($d -match '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'){ $d.ToLower() }"') do set "DOMAIN=%%d"
if not defined DOMAIN goto :site_bad_domain
REM mkcert covers *.xqkeji.dev and the apex xqkeji.dev itself -> local path.
set "AS_DOMAIN=!DOMAIN!"
set "LOCAL_MODE="
powershell -NoProfile -ExecutionPolicy Bypass -Command "if($env:AS_DOMAIN -eq 'xqkeji.dev' -or $env:AS_DOMAIN.EndsWith('.xqkeji.dev')){exit 0}else{exit 1}"
if not errorlevel 1 set "LOCAL_MODE=1"
echo ==============================================================
if defined LOCAL_MODE (
  set "MSG= 添加本地站点：%DOMAIN%"
) else (
  set "MSG= 添加公网域名站点：%DOMAIN%（ACME 自动签发证书）"
)
echo !MSG!
echo ==============================================================
call :site_check_existing
if defined SKIP_CONF goto :site_hosts
if defined LOCAL_MODE (
  call :site_write_conf
) else (
  call :site_acme_mounts
  if errorlevel 1 goto :site_fail
  call :site_acme_base
  call :site_write_conf
)
call :site_reload
if errorlevel 1 goto :site_fail
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_hosts
if not defined LOCAL_MODE goto :site_dns_note
call :site_add_hosts
call :site_report
exit /b 0
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_dns_note
set "MSG=[提示] 公网域名不写 hosts：请确保 %DOMAIN% 的 DNS A 记录已指向本机公网 IP，且 80 端口公网可达"
echo !MSG!
call :site_report
exit /b 0

REM ===================== helper :site_check_existing =====================
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_check_existing
set "SKIP_CONF="
if exist "%CONF%" (
  set "MSG=[跳过] 配置已存在，不覆盖：%CONF%"
  echo !MSG!
  set "SKIP_CONF=1"
  goto :eof
)
findstr /i /m /c:"%DOMAIN%" "%BASE%\etc\nginx\conf.d\*.conf" >nul 2>&1
if not errorlevel 1 (
  set "MSG=[跳过] %DOMAIN% 已被 conf.d 里其它配置使用，不再重复添加"
  echo !MSG!
  set "SKIP_CONF=1"
)
goto :eof

REM ===================== helper :site_write_conf =====================
REM Written line by line with >> instead of one parenthesized block: outside a
REM block the regex parentheses need no escaping, only ^ | & do. The two literal
REM ! in ssl_ciphers must be ^^! because delayed expansion is on -- a single !
REM silently eats "!aNULL:" as if it were a variable name.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_write_conf
if exist "%CONF%" del "%CONF%" >nul 2>&1
> "%CONF%" echo # Generated by win.bat site for %DOMAIN% -- edit freely.
>> "%CONF%" echo # Re-running win.bat site never overwrites an existing file.
>> "%CONF%" echo server {
>> "%CONF%" echo 	listen       443 ssl;
>> "%CONF%" echo 	server_name  %DOMAIN%;
>> "%CONF%" echo 	error_log  /home/log/%NAME%.log;
>> "%CONF%" echo.
if defined LOCAL_MODE (
>> "%CONF%" echo 	ssl_certificate     /etc/nginx/ssl/local.pem;
>> "%CONF%" echo 	ssl_certificate_key /etc/nginx/ssl/local-key.pem;
) else (
>> "%CONF%" echo 	acme_certificate letsencrypt;
>> "%CONF%" echo 	ssl_certificate     $acme_certificate;
>> "%CONF%" echo 	ssl_certificate_key $acme_certificate_key;
>> "%CONF%" echo 	ssl_certificate_cache max=2;
)
>> "%CONF%" echo 	ssl_protocols       TLSv1.2 TLSv1.3;
>> "%CONF%" echo 	ssl_ciphers         HIGH:^^!aNULL:^^!MD5;
>> "%CONF%" echo 	ssl_session_cache   shared:SSL:10m;
>> "%CONF%" echo 	ssl_session_timeout 10m;
>> "%CONF%" echo.
>> "%CONF%" echo 	root    "%CONTAINER_ROOT%";
set "MSG=	# 禁止 asset 与 upload 目录里的 php 被执行，必须排在下面的 php 处理之前"
>> "%CONF%" echo !MSG!
>> "%CONF%" echo 	location ~* ^^/(?:asset^|upload)/.*\.(?:php\d?^|phtml\d?^|phar)$ {
>> "%CONF%" echo 		deny all;
>> "%CONF%" echo 	}
>> "%CONF%" echo 	location / {
>> "%CONF%" echo 		index  index.html index.htm index.php;
>> "%CONF%" echo 		autoindex  off;
>> "%CONF%" echo 		try_files $uri $uri/ /index.php?_url=$uri^&$args;
>> "%CONF%" echo 	}
>> "%CONF%" echo 	location ~ \.php(.*)$  {
>> "%CONF%" echo 		try_files		$uri = 404;
>> "%CONF%" echo 		fastcgi_pass   172.0.0.10:9000;
>> "%CONF%" echo 		fastcgi_index  index.php;
>> "%CONF%" echo 		fastcgi_split_path_info  ^^((?U).+\.php)(/?.+)$;
>> "%CONF%" echo 		fastcgi_param  SCRIPT_FILENAME  $document_root$fastcgi_script_name;
>> "%CONF%" echo 		fastcgi_param  PATH_INFO  $fastcgi_path_info;
>> "%CONF%" echo 		fastcgi_param  PATH_TRANSLATED  $document_root$fastcgi_path_info;
>> "%CONF%" echo 		include        fastcgi_params;
>> "%CONF%" echo 	}
>> "%CONF%" echo }
set "MSG=[√] 已生成 %CONF%"
echo !MSG!
exit /b 0

REM ===================== helper :site_acme_mounts =====================
REM An nginx container deployed by an older win.bat lacks the ACME mounts:
REM the generated files would be invisible inside it, so refuse early.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_acme_mounts
docker container inspect nginx >nul 2>&1
if errorlevel 1 exit /b 0
set "MOUNTS="
for /f "delims=" %%m in ('docker inspect -f "{{range .Mounts}}{{.Destination}} {{end}}" nginx 2^>nul') do set "MOUNTS=%%m"
set "AS_MOUNTS=!MOUNTS!"
powershell -NoProfile -ExecutionPolicy Bypass -Command "if($env:AS_MOUNTS -like '*/etc/nginx/modules-enabled*'){exit 0}else{exit 1}"
if errorlevel 1 (
  set "MSG=[错误] nginx 容器缺少 ACME 挂载（旧版部署），请先重新部署（win.bat），再添加公网域名站点"
  echo !MSG!
  exit /b 1
)
exit /b 0

REM ===================== helper :site_acme_base =====================
REM First ACME site only: main-level load_module snippet + http-level issuer
REM (conf.d is included inside http, so the issuer file belongs there).
REM Existing files are never overwritten. ACMOD_NEW / ACISS_NEW mark what this
REM run created so :site_reload can remove them again if nginx -t fails.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_acme_base
set "ACMOD_NEW="
set "ACISS_NEW="
if not exist "%BASE%\etc\nginx\modules-enabled" md "%BASE%\etc\nginx\modules-enabled"
set "AMOD=%BASE%\etc\nginx\modules-enabled\acme.conf"
if not exist "%AMOD%" (
  > "%AMOD%" echo load_module /usr/lib/nginx/modules/ngx_http_acme_module.so;
  set "ACMOD_NEW=1"
  set "MSG=[√] 已生成 %AMOD%"
  echo !MSG!
)
set "AISS=%BASE%\etc\nginx\conf.d\acme-issuer.conf"
if not exist "%AISS%" (
  > "%AISS%" echo # Generated by win.bat site -- ACME issuer shared by all ACME sites.
  set "MSG=# 127.0.0.11 是 Docker 内置 DNS；state_path 挂载在宿主机 data/nginx/acme，"
  >> "%AISS%" echo !MSG!
  set "MSG=# 容器重建不丢账户密钥与已签证书（避免撞 Let's Encrypt 速率限制）。"
  >> "%AISS%" echo !MSG!
  >> "%AISS%" echo resolver 127.0.0.11 valid=30s ipv6=off;
  >> "%AISS%" echo acme_issuer letsencrypt {
  >> "%AISS%" echo     uri https://acme-v02.api.letsencrypt.org/directory;
  >> "%AISS%" echo     state_path /var/cache/nginx/acme;
  >> "%AISS%" echo     accept_terms_of_service;
  >> "%AISS%" echo }
  >> "%AISS%" echo acme_shared_zone zone=ngx_acme_shared:1M;
  set "ACISS_NEW=1"
  set "MSG=[√] 已生成 %AISS%"
  echo !MSG!
)
exit /b 0

REM ===================== helper :site_reload =====================
REM Only a RUNNING nginx container can be tested and reloaded. A failed -t means
REM the new file is removed again, so a typo can never take the other sites down.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_reload
docker container inspect nginx >nul 2>&1
if errorlevel 1 (
  set "MSG=nginx 容器不存在，下次 win.bat 部署会直接使用新配置"
  echo !MSG!
  exit /b 0
)
set "RUNNING="
for /f "delims=" %%s in ('docker inspect -f "{{.State.Running}}" nginx 2^>nul') do set "RUNNING=%%s"
if not "!RUNNING!"=="true" (
  set "MSG=nginx 容器当前没有运行，下次启动会直接使用新配置"
  echo !MSG!
  exit /b 0
)
docker exec nginx nginx -t
if errorlevel 1 (
  del "%CONF%" >nul 2>&1
  if defined ACMOD_NEW del "%AMOD%" >nul 2>&1
  if defined ACISS_NEW del "%AISS%" >nul 2>&1
  set "MSG=[错误] nginx 自检未通过，已删除刚生成的配置，原有站点未受影响。若报 ngx_http_acme_module.so 找不到，说明镜像太旧：请重新部署（win.bat）拉取新镜像"
  echo !MSG!
  exit /b 1
)
docker exec nginx nginx -s reload
if errorlevel 1 (
  set "MSG=[警告] 重载失败，请手动执行：docker exec nginx nginx -s reload"
  echo !MSG!
  exit /b 0
)
set "MSG=[√] 已通知 nginx 重新加载配置"
echo !MSG!
exit /b 0

REM ===================== helper :site_add_hosts =====================
REM hosts is append-only here: the domain is looked up as an exact hostname
REM token (comments stripped, every name on a line compared), so a line for
REM othercrm.xqkeji.dev does not count as a hit for crm.xqkeji.dev.
REM Writing hosts needs admin: try directly first, and only on "access denied"
REM ask for one UAC elevation.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_add_hosts
call :site_hosts_apply
set "RC=!errorlevel!"
if "!RC!"=="2" (
  set "MSG=[跳过] hosts 里已有 %DOMAIN% 的解析，不重复添加"
  echo !MSG!
  exit /b 0
)
if "!RC!"=="0" (
  set "MSG=[√] hosts 已添加：127.0.0.1 %DOMAIN%"
  echo !MSG!
  exit /b 0
)
call :site_hosts_elevate
call :site_hosts_apply
set "RC=!errorlevel!"
if "!RC!"=="2" (
  set "MSG=[√] hosts 已添加（提权后）：127.0.0.1 %DOMAIN%"
  echo !MSG!
  exit /b 0
)
set "MSG=[警告] 无法写入 hosts（需要管理员权限）。请手动加一行：127.0.0.1 %DOMAIN%"
echo !MSG!
set "MSG=        文件：%HOSTS_FILE%"
echo !MSG!
exit /b 0

REM ===================== helper :site_hosts_apply =====================
REM exit 2 = already resolved, 0 = appended, 3 = denied/failed. Domain and path
REM are passed as environment variables rather than interpolated, so an
REM apostrophe in the Windows profile path cannot break out of the script text.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_hosts_apply
set "AS_DOMAIN=%DOMAIN%"
set "AS_HOSTS=%HOSTS_FILE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=$env:AS_DOMAIN; $p=$env:AS_HOSTS; $hit=$false; if(Test-Path -LiteralPath $p){ foreach($l in (Get-Content -LiteralPath $p)){ $t=($l -split '#')[0].Trim(); if($t){ $f=$t -split '\s+'; for($i=1;$i -lt $f.Count;$i++){ if($f[$i] -eq $d){ $hit=$true } } } } }; if($hit){ exit 2 }; try{ Add-Content -LiteralPath $p -Value ('127.0.0.1 '+$d) -Encoding ASCII -ErrorAction Stop; exit 0 }catch{ exit 3 }"
set "RC=!errorlevel!"
exit /b !RC!

REM ===================== helper :site_hosts_elevate =====================
REM One UAC prompt running a one-line script from the system temp dir. A file is
REM used instead of an inline -Command because the nested quoting of
REM Start-Process plus Add-Content is not survivable in batch. Deleted afterwards.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_hosts_elevate
set "PS1=%TEMP%\dnmmp-add-host.ps1"
> "%PS1%" echo Add-Content -LiteralPath "%HOSTS_FILE%" -Value "127.0.0.1 %DOMAIN%" -Encoding ASCII
set "MSG=写入 hosts 需要管理员权限，正在请求提权（会弹出 UAC 确认框）..."
echo !MSG!
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%PS1%'" >nul 2>&1
del "%PS1%" >nul 2>&1
exit /b 0

REM ===================== helper :site_report =====================
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_report
echo ==============================================================
set "MSG= 站点目录：%DOCROOT%（容器内 %CONTAINER_ROOT%）"
echo !MSG!
set "MSG= 访问地址：https://%DOMAIN%/（http 会被 301 跳到 https）"
echo !MSG!
if defined LOCAL_MODE (
  if exist "%BASE%\etc\nginx\ssl\local.pem" (
    set "MSG= 证书由 ssl.sh / win.bat 生成，已覆盖 *.xqkeji.dev，无需重签"
  ) else (
    set "MSG=[警告] 未找到 etc\nginx\ssl\local.pem，请先运行 win.bat 签发证书，否则 nginx 起不来"
  )
) else (
  set "MSG= 证书由 nginx ACME 模块自动向 Let's Encrypt 签发并续期（首次需几秒到几十秒；前提：80 端口公网可达；进度见 docker logs nginx）"
)
echo !MSG!
echo ==============================================================
exit /b 0

REM ===================== add-site usage / errors =====================
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_usage
set "MSG=用法：win.bat site <name> [project-dir]"
echo !MSG!
set "MSG=      域名交互选择：默认 <name>.xqkeji.dev（本地证书 + hosts），其它域名用 ACME 自动签发 Let's Encrypt 证书（需公网 DNS 与 80 端口）"
echo !MSG!
exit /b 1
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_bad_name
set "MSG=[错误] 站点名只能包含字母、数字和连字符，且以字母或数字开头：%NAME%"
echo !MSG!
exit /b 1
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_bad_domain
REM The raw input is NOT echoed back: it is unvalidated user text and could
REM contain quotes that break out of the set "MSG=..." quoting.
set "MSG=[错误] 域名格式不正确（应为字母、数字、连字符组成的多级域名，如 crm.example.com）"
echo !MSG!
exit /b 1
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_no_docroot
set "MSG=[错误] 找不到站点入口目录：%DOCROOT%"
echo !MSG!
set "MSG=       请先把项目创建好，或用第三个参数指定项目目录"
echo !MSG!
exit /b 1
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_outside
set "MSG=[错误] 项目必须放在 %BASE%\www 下，nginx/php 容器只挂载了 www：%PROJ%"
echo !MSG!
exit /b 1
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:site_fail
exit /b 1

REM ===================== start / stop installed containers =====================
REM win.bat start / win.bat stop -- operate on whichever of the four containers
REM exist (no state file); a missing mysql is normal when it was not installed.
REM start also ensures xqkeji-net exists. data\ is never touched.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:start_env
call :check_docker || goto :fail
call :ensure_network || goto :fail
set "FOUND=0"
for %%c in (nginx mysql mongo xqkeji) do (
  docker container inspect %%c >nul 2>&1
  if not errorlevel 1 (
    set "FOUND=1"
    docker start %%c >nul
    if errorlevel 1 (
      set "MSG=[错误] 启动 %%c 失败（常见原因：端口被占用），详见 docker logs %%c"
      echo !MSG!
      goto :fail
    )
    set "MSG=[√] 已启动 %%c"
    echo !MSG!
  ) else (
    set "MSG=跳过 %%c（容器不存在；MySQL 未安装属正常，其余请先运行 win.bat 部署）"
    echo !MSG!
  )
)
if "!FOUND!"=="0" (
  set "MSG=[错误] 未找到任何 dnmmp 容器，请先运行 win.bat 部署。"
  echo !MSG!
  goto :fail
)
docker ps --filter "network=xqkeji-net" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
set "MSG=访问地址：https://127.0.0.1/（http://127.0.0.1/ 自动跳转 https）"
echo !MSG!
pause
exit /b 0

REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:stop_env
call :check_docker || goto :fail
set "FOUND=0"
for %%c in (nginx mysql mongo xqkeji) do (
  docker container inspect %%c >nul 2>&1
  if not errorlevel 1 (
    set "FOUND=1"
    docker stop %%c >nul
    if errorlevel 1 (
      set "MSG=[错误] 停止 %%c 失败，请手动执行：docker stop %%c"
      echo !MSG!
      goto :fail
    )
    set "MSG=[√] 已停止 %%c"
    echo !MSG!
  ) else (
    set "MSG=跳过 %%c（容器不存在）"
    echo !MSG!
  )
)
if "!FOUND!"=="0" (
  set "MSG=[错误] 未找到任何 dnmmp 容器，请先运行 win.bat 部署。"
  echo !MSG!
  goto :fail
)
docker ps -a --filter "network=xqkeji-net" --format "table {{.Names}}\t{{.Status}}"
set "MSG=数据保留在 %BASE%\data，重新启动执行 win.bat start"
echo !MSG!
pause
exit /b 0

REM ===================== upgrade: hand off to bin\upgrade.ps1 =====================
REM win.bat upgrade [force] [backup-data] [--local <zip>]
REM cmd.exe reads batch files by byte offset, so the handoff MUST stay on ONE
REM parsed line: upgrade.ps1 may overwrite win.bat itself while powershell is
REM running (powershell parses its whole script first, so that side is safe).
REM After powershell returns, exit /b runs from the same already-parsed line
REM and cmd never reads another byte of the replaced file.
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:upgrade_handoff
set "UP_ARGS="
set "UP_ZIP="
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:up_arg_loop
if "%~2"=="" goto :up_run
if /i "%~2"=="force" (
  set "UP_ARGS=!UP_ARGS! -Force"
  shift
  goto :up_arg_loop
)
if /i "%~2"=="--force" (
  set "UP_ARGS=!UP_ARGS! -Force"
  shift
  goto :up_arg_loop
)
if /i "%~2"=="backup-data" (
  set "UP_ARGS=!UP_ARGS! -BackupData"
  shift
  goto :up_arg_loop
)
if /i "%~2"=="--backup-data" (
  set "UP_ARGS=!UP_ARGS! -BackupData"
  shift
  goto :up_arg_loop
)
if /i "%~2"=="--local" (
  REM cmd splits unquoted paths at '=' and spaces, so the value is taken
  REM verbatim from the raw argument tail %* instead of the tokenized %3.
  REM Everything up to the next known flag belongs to the path.
  set "RAW_TAIL=%*"
  set "RAW_FLAG=--local"
  set "RAW_STOP=1"
  set "RAW_VALUE="
  call :raw_value
  set "UP_ZIP=!RAW_VALUE!"
  if not defined UP_ZIP (
    set "MSG=[错误] --local 需要参数：源码 zip 的路径"
    echo !MSG!
    goto :fail
  )
  shift
  goto :up_local_skip
)
set "MSG=[错误] 未知参数：%~2（可用：force / backup-data / --local <zip>）"
echo !MSG!
goto :fail
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:up_local_skip
if "%~2"=="" goto :up_arg_loop
if /i "%~2"=="force" goto :up_arg_loop
if /i "%~2"=="--force" goto :up_arg_loop
if /i "%~2"=="backup-data" goto :up_arg_loop
if /i "%~2"=="--backup-data" goto :up_arg_loop
if /i "%~2"=="--local" goto :up_arg_loop
shift
goto :up_local_skip
REM ---- keep the lines above this label 100% ASCII (see :add_site).
REM ----
REM ----
:up_run
if not exist "%BASE%\bin\upgrade.ps1" (
  set "MSG=[错误] 缺少 bin\upgrade.ps1，请在完整的 dnmmp 目录内运行 win.bat upgrade。"
  echo !MSG!
  goto :fail
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\bin\upgrade.ps1" -Base "%BASE%" !UP_ARGS! & exit /b !errorlevel!
