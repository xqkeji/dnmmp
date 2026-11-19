# dnmmp 环境程序自动升级（Windows 入口，由 win.bat upgrade 调起）
# Copyright (C) 2025-2026 xqkeji.cn
# SPDX-License-Identifier: AGPL-3.0-or-later
# 用法：win.bat upgrade [force] [backup-data] [--local <zip>]
# 只覆盖程序文件（脚本 + etc 基础配置），绝不触碰 data/ www/ code/ log/
# etc/nginx/ssl/ 与 conf.d 里的自定义站点配置。覆盖前旧文件备份到
# .upgrade-backup/<旧版本>-<时间戳>/，覆盖中途失败自动回滚。
# PowerShell 先解析整个脚本再执行，因此运行中覆盖本文件自身是安全的。
param(
    [Parameter(Mandatory = $true)][string]$Base,
    [switch]$Force,
    [switch]$BackupData
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TagsApi = 'https://api.github.com/repos/xqkeji/dnmmp/tags'
$LocalZip = $env:UP_ZIP

# 升级覆盖白名单：只列程序文件与基础配置，用户数据/自定义配置不在其中
$Files = @(
    'install.sh', 'win.bat', 'ssl.sh', 'start.sh', 'stop.sh', 'upgrade.sh',
    'os/linux.sh', 'os/macos.sh', 'bin/add-site.sh', 'bin/upgrade.ps1',
    'README.md', 'LICENSE', 'VERSION', '.gitignore', '.gitattributes',
    'etc/nginx/nginx.conf', 'etc/nginx/conf.d/default.conf',
    'etc/php/php.ini', 'etc/mysql/my.ini', 'etc/mongo/mongodb.conf'
)

function ToWin([string]$p) { return $p.Replace('/', '\') }

$oldVer = 'unknown'
$vf = Join-Path $Base 'VERSION'
if (Test-Path -LiteralPath $vf) { $oldVer = (Get-Content -LiteralPath $vf -Raw).Trim() }

$work = Join-Path $env:TEMP ('dnmmp-upgrade-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    if ($LocalZip) {
        if (!(Test-Path -LiteralPath $LocalZip)) { Write-Host "[错误] --local 文件不存在：$LocalZip"; exit 1 }
        $zip = $LocalZip
        $newVer = 'local'
        Write-Host "==> 离线升级：$LocalZip"
    } else {
        try { $tags = Invoke-RestMethod -Uri $TagsApi -UseBasicParsing -TimeoutSec 60 }
        catch { Write-Host "[错误] 获取 tag 列表失败，请检查网络（可改用 --local <zip> 离线升级）：$_"; exit 1 }
        $newVer = [string]$tags[0].name
        $zipUrl = [string]$tags[0].zipball_url
        if (!$newVer -or !$zipUrl) { Write-Host '[错误] 无法从 tag 列表解析最新版本，请改用 --local <zip> 离线升级'; exit 1 }
        if ($newVer -eq $oldVer -and -not $Force) {
            Write-Host "==> 已是最新版本（$oldVer），无需升级（force 可强制重新覆盖）"
            exit 0
        }
        $zip = Join-Path $work 'dnmmp.zip'
        Write-Host "==> 下载升级包：$zipUrl"
        try { Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 300 }
        catch { Write-Host "[错误] 下载升级包失败，请检查网络（可改用 --local <zip> 离线升级）：$_"; exit 1 }
    }
    $srcDir = Join-Path $work 'src'
    try { Expand-Archive -LiteralPath $zip -DestinationPath $srcDir -Force }
    catch { Write-Host "[错误] 解压升级包失败（文件可能损坏）：$zip"; exit 1 }
    $top = Get-ChildItem -LiteralPath $srcDir -Directory | Select-Object -First 1
    if (!$top) { Write-Host '[错误] 升级包内未找到源码目录（应为 GitHub tag 页下载的 zip）'; exit 1 }
    $srcRoot = $top.FullName
    if ($LocalZip) {
        $pvf = Join-Path $srcRoot 'VERSION'
        if (Test-Path -LiteralPath $pvf) { $newVer = (Get-Content -LiteralPath $pvf -Raw).Trim() }
    }
    foreach ($f in $Files) {
        if (!(Test-Path -LiteralPath (Join-Path $srcRoot (ToWin $f)))) {
            Write-Host "[错误] 升级包缺少 $f，拒绝升级（包可能不完整）"; exit 1
        }
    }
    $iniSrc = Join-Path $srcRoot 'etc\php\conf.d'
    if (!(Test-Path -LiteralPath $iniSrc)) { Write-Host '[错误] 升级包缺少 etc/php/conf.d，拒绝升级（包可能不完整）'; exit 1 }
    Write-Host "==> 升级：$oldVer -> $newVer"
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bk = Join-Path $Base ".upgrade-backup\$oldVer-$stamp"
    New-Item -ItemType Directory -Path $bk -Force | Out-Null
    $targets = @($Files)
    $iniBase = Join-Path $Base 'etc\php\conf.d'
    if (Test-Path -LiteralPath $iniBase) {
        $targets += Get-ChildItem -LiteralPath $iniBase -Filter '*.ini' -File | ForEach-Object { 'etc/php/conf.d/' + $_.Name }
    }
    foreach ($f in $targets) {
        $p = Join-Path $Base (ToWin $f)
        if (Test-Path -LiteralPath $p) {
            $relDir = Split-Path -Parent (ToWin $f)
            $d = $bk
            if ($relDir) { $d = Join-Path $bk $relDir }
            if (!(Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            Copy-Item -LiteralPath $p -Destination $d -Force
        }
    }
    try {
        foreach ($f in $Files) {
            $dst = Join-Path $Base (ToWin $f)
            $dstDir = Split-Path -Parent $dst
            if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath (Join-Path $srcRoot (ToWin $f)) -Destination $dst -Force
        }
        if (!(Test-Path -LiteralPath $iniBase)) { New-Item -ItemType Directory -Path $iniBase -Force | Out-Null }
        Get-ChildItem -LiteralPath $iniSrc -Filter '*.ini' -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $iniBase -Force
        }
    } catch {
        Write-Host '[警告] 升级失败，回滚到升级前的文件'
        Get-ChildItem -LiteralPath $bk -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($bk.Length + 1)
            $dst = Join-Path $Base $rel
            $dstDir = Split-Path -Parent $dst
            if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
        }
        Write-Host "[警告] 已回滚。备份目录保留在：$bk"
        exit 1
    }
    Write-Host "==> 升级完成：$oldVer -> $newVer（旧文件备份：$bk）"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# 重新部署在回滚范围之外：升级本身已成功，部署失败不应回滚脚本
if ([Console]::IsInputRedirected) {
    Write-Host '==> 非交互环境，跳过自动重新部署。请稍后手动执行：win.bat'
    exit 0
}
$ans = Read-Host '升级完成。现在重新部署容器（拉取新镜像并重建）？[Y/n]（默认是）'
if ($ans -match '^[nN]') {
    Write-Host '==> 跳过重新部署。请稍后手动执行：win.bat'
    exit 0
}
# MySQL 取舍按现有容器推导：有 mysql 容器→默认安装；有其它容器但没 mysql→no-mysql；
# 一个容器都没有→不带标志，交给 win.bat 询问/默认（避免首次部署被跳过）。
$any = $false
$hasMysql = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    foreach ($c in 'nginx', 'mysql', 'mongo', 'xqkeji') {
        & docker container inspect $c *> $null
        if ($LASTEXITCODE -eq 0) {
            $any = $true
            if ($c -eq 'mysql') { $hasMysql = $true }
        }
    }
}
$wargs = @()
if ($any -and -not $hasMysql) { $wargs += 'no-mysql' }
if ($BackupData) { $wargs += 'backup-data' }
& cmd.exe /c (Join-Path $Base 'win.bat') @wargs
exit $LASTEXITCODE
