# dnmmp

docker + nginx + mysql + mongodb + php 集成开发环境。

先下载 dnmmp 并解压，把 dnmmp 目录放到合适的位置：数据库数据保存在 `data/` 目录里，要确保磁盘有足够空间，并尽量避免中文路径。

## 快速开始

| 系统 | 命令 | 前置条件 |
| --- | --- | --- |
| Linux（各发行版） | `./install.sh` | 无。未安装 Docker 时脚本自动安装容器引擎 |
| Windows + WSL2 | 在 WSL 里 `./install.sh` | 已安装 WSL2 与 Linux 发行版 |
| macOS | `./install.sh` | 已自行安装并启动 Docker Desktop / OrbStack / Colima |
| Windows | `win.bat` | 已安装并启动 Docker Desktop |

`install.sh` 会自己判断操作系统，不需要再按系统挑脚本。

脚本按「入口 + 分系统」组织：`install.sh` 是入口，负责识别系统、共用函数和部署四个容器；准备 Docker 的逻辑拆在 `os/linux.sh`（自动安装引擎）与 `os/macos.sh`（只检查、不安装），运行时由入口 `source` 加载，不能单独执行。发行版分派集中在 `os/linux.sh`，以后新增发行版只改这一个文件。本地 HTTPS 证书由独立的 `ssl.sh` 生成（可单独重跑），nginx 监听 443 并把 80 跳转到 443。

## install.sh 做了什么

1. 识别操作系统：macOS、Linux 发行版（读 `/etc/os-release`）、是否 WSL 及 WSL 版本，并找出可用的包管理器。
2. 准备 Docker：
   - Linux 已装且正在运行 → 直接复用；
   - Linux 未装 → 用发行版包管理器安装 **Docker 引擎（只有容器运行时，不安装 Docker Desktop 桌面版）**，首次安装且没有 `/etc/docker/daemon.json` 时写入镜像加速配置，然后启动服务并设为开机自启；
   - Linux 非 root 执行 → 自动用 `sudo` 重新执行；
   - macOS → 只检查 Docker 是否已安装并运行，未运行则提示先启动，不做任何安装。
3. 创建 `code/`、`www/`、`log/*`、`data/*` 目录并放开写权限。
4. 拉取 `nginx`、`mysql`、`mongo`、`xqkeji/xqkeji` 四个镜像（失败自动重试一次）。
5. 创建 `xqkeji-net` 网络（`172.0.0.0/24`）。
6. 用 `ssl.sh` 生成本地 HTTPS 证书（mkcert 本地 CA 优先，拉不到 mkcert 时退回 openssl 自签），覆盖 `localhost`、`127.0.0.1`、`*.xqkeji.dev` 等。
7. 启动四个容器，全部 `--restart=always`；nginx 监听 443（https），并把 80 自动跳转到 443。
8. 访问 `https://127.0.0.1/` 校验站点是否真的可用，最后打印容器状态与连接信息。

## 支持的 Linux 发行版

按包管理器分派，覆盖主流发行版及其衍生版：

| 发行版 | 包管理器 | Docker 安装方式 |
| --- | --- | --- |
| Debian、Ubuntu、Mint、Deepin、UOS 等 | apt | `docker.io`；仓库没有时用 Docker 官方安装脚本 |
| CentOS、RHEL、Rocky、AlmaLinux、Anolis 等 | dnf / yum | `docker-engine` → `moby-engine` → 自建 Docker CE 仓库（阿里云 centos 镜像） |
| Fedora | dnf | `moby-engine` → 自建 Docker CE 仓库（阿里云 fedora 镜像） |
| openEuler | dnf | `docker-engine` → 自建 Docker CE 仓库 |
| openSUSE、SLES | zypper | `docker`；失败时用 Docker 官方安装脚本 |
| Arch、Manjaro | pacman | `docker` |
| Alpine | apk | `docker`（Alpine 需先 `apk add bash`，脚本用 bash 编写） |

「自建 Docker CE 仓库」指脚本直接写 `/etc/yum.repos.d/docker-ce.repo`，baseurl 指向 `https://mirrors.aliyun.com/docker-ce/linux/centos/$releasever/$basearch/stable`，再安装 `docker-ce docker-ce-cli containerd.io`。EL 衍生版统一走 centos 路径，因为阿里云镜像站没有 `rocky`/`almalinux` 目录——官方 `get.docker.com --mirror Aliyun` 在 Rocky 上会拼出 404 的仓库地址。

「Docker 官方安装脚本」指 `https://get.docker.com`，先以 `--mirror Aliyun` 调用，失败再不带镜像重试一次。

WSL2 里的发行版按上表同样处理；**WSL1 无法运行 Docker 引擎**，脚本会直接提示先升级到 WSL2。如果在 Windows 上装了 Docker Desktop 并开启了该发行版的 WSL 集成，脚本会直接复用，不再重复安装引擎。

## 1. Linux 安装

进入 dnmmp 目录后执行：

```bash
cd dnmmp
chmod +x install.sh
./install.sh
```

普通用户执行即可，安装 Docker 需要 root 权限时脚本会自动 `sudo`。没有 `sudo` 的机器请用 root 执行 `bash install.sh`。

执行完成后会自动拉取镜像并启动 nginx、mysql、mongo、xqkeji（php-fpm）四个容器。Docker 服务已设为开机自启，容器为 `--restart=always`，重启机器后环境自动恢复。

## 2. Windows + WSL2 安装

### 一、安装 WSL2 的 Ubuntu 应用

（1）检查 CPU 是否开启虚拟化技术

在 Windows 打开「任务管理器」→「性能」→「CPU」，信息里显示「虚拟化：已启用」说明已开启。若未开启，需要重启进入主板 BIOS 启用 CPU 虚拟化技术。

（2）开启 WSL 功能

右键任务栏「开始」图标 →「系统」→「可选功能」→ 页面底部「相关设置」→「更多 Windows 功能」，勾选「适用于 Linux 的 Windows 子系统」和「虚拟机平台」，确定后重启。

（3）检查并升级 WSL

```powershell
wsl --update
wsl --status
```

状态里的「默认版本」需要为 **2**。若不是 2：

```powershell
wsl --set-default-version 2
```

已装好的发行版若是 WSL1，需要单独转换（脚本检测到 WSL1 会报错并给出该命令）：

```powershell
wsl --set-version Ubuntu 2
```

（4）安装 Ubuntu 应用

从「开始」菜单打开 Microsoft Store，搜索 Ubuntu 并安装。安装完成后可以用命令启动：

```powershell
wsl -d ubuntu
```

也可以在「开始」菜单的应用列表里直接点 Ubuntu 图标进入。

### 二、安装 dnmmp 服务

进入 Ubuntu 后，切到 dnmmp 目录（`/mnt/d/` 是 D 盘、`/mnt/e/` 是 E 盘，假设 dnmmp 在 D 盘）：

```bash
cd /mnt/d/dnmmp
./install.sh
```

后续行为与 Linux 一致。注意两点：

- 若 Windows 上的 Docker Desktop 已开启本发行版的 WSL 集成，请先启动 Docker Desktop，脚本会直接复用它；脚本不会在 WSL 里重复安装引擎。
- 若要在 WSL 内独立安装引擎，建议开启 systemd（`/etc/wsl.conf` 里 `[boot] systemd=true`，改完在 Windows 执行 `wsl --shutdown` 后重进），这样 Docker 才能随发行版启动自启；没有 systemd 时脚本会用 `service docker start` 启动，但重开窗口后需要再执行一次 `./install.sh`。

## 3. macOS 安装

### 一、先装好 Docker

macOS 上脚本**不会**自动安装 Docker，需要自行安装并启动其中一种：

- Docker Desktop：官网下载 `.dmg`，把 Docker 拖进「应用程序」，然后启动它；
- 或 OrbStack / Colima 等提供 `docker` 命令与 Docker 守护进程的运行时。

启动后在终端验证：

```bash
docker --version
docker info
```

`docker info` 能输出服务端信息才算就绪。脚本会做同样的检查，未就绪时直接提示先启动，不会继续往下跑。

### 二、安装 dnmmp 服务

```bash
cd dnmmp
chmod +x install.sh
./install.sh
```

macOS 上需要注意：

- **文件共享**：dnmmp 目录必须在 Docker Desktop 的 Settings → Resources → File Sharing 列表里（默认已共享 `/Users`、`/Volumes`、`/tmp`、`/private`）。放在其它位置时容器会挂载失败。
- **Apple Silicon（M 系列芯片）**：`xqkeji/xqkeji` 镜像是 `linux/amd64`，需要 Docker Desktop 开启 Settings → General →「Use Rosetta for x86/amd64 emulation」才能运行。是否有 arm64 版本可以用这条命令确认：`docker manifest inspect xqkeji/xqkeji`。
- macOS 上 `--net=host` 指的是 Docker 虚拟机而不是 Mac 本机，所以四个容器统一走 `xqkeji-net` 桥接网络 + 端口发布，访问地址一律是 `127.0.0.1`。

## 4. Windows 安装

先安装并启动 Docker Desktop（官网 → Get Docker → Docker Desktop for Windows），在命令提示符里用 `docker --version` 验证。

然后进入 dnmmp 目录，双击或在命令行执行 `win.bat`。

`win.bat` 是 `install.sh` 的 Windows 原生批处理版（`install.sh` 不在 Windows Git Bash 里运行），用已装好的 Docker Desktop 完成等价部署：检查 Docker → 建目录 → 拉取四个镜像（失败重试一次）→ 删除重建已存在的容器（`data/` 数据保留）→ 确保 `xqkeji-net`（`172.0.0.0/24`）→ 生成本地 HTTPS 证书 → 启动 nginx/mysql/mongo/xqkeji 四个容器（nginx 监听 443 https、80 跳转 443，全部 `--restart=always`）→ 校验 `https://127.0.0.1/` → 打印状态与连接信息。可重复执行。

证书优先下载 `mkcert.exe` 到 `bin/`（受信任，绿锁），拉不到时退回宿主 `openssl` 自签（浏览器提示不受信任，测试无碍），覆盖域名与 `ssl.sh` 一致；已有证书默认不重签，强制重签：`win.bat force`（或 `set FORCE=1` 后重跑 `win.bat`）。`bin/` 与 `etc/nginx/ssl/` 已在 `.gitignore` 里，私钥不进 git。

dnmmp 目录需在 Docker Desktop 的共享盘里（WSL2 后端默认共享所有本地盘），否则容器挂载会失败。

## 服务、端口与目录

四个容器都接在 `xqkeji-net`（`172.0.0.0/24`）上，宿主机统一通过 `127.0.0.1` 访问：

| 服务 | 容器名 | 宿主机端口 | 容器内 IP | 账号 |
| --- | --- | --- | --- | --- |
| nginx | nginx | 80（跳转）、443（https） | 172.0.0.2 | — |
| MySQL | mysql | 3306 | 172.0.0.200 | root / xqkeji.cn |
| MongoDB | mongo | 27017 | 172.0.0.100 | root / xqkeji.cn |
| PHP-FPM | xqkeji | 9000 | 172.0.0.10 | — |

nginx 通过 `fastcgi_pass 172.0.0.10:9000` 把 PHP 请求转给 xqkeji 容器（见 `etc/nginx/conf.d/default.conf`）。

| 目录 | 用途 | 容器内路径 |
| --- | --- | --- |
| `www/default/` | 站点根目录 | `/home/www/default` |
| `code/` | 框架代码 | `/home/code` |
| `data/mysql/`、`data/mongo/` | 数据库数据 | `/var/lib/mysql`、`/data/db` |
| `log/nginx/`、`log/mysql/`、`log/mongo/`、`log/php/` | 各服务日志 | `/home/log`、`/logs` |
| `etc/` | nginx / php / mysql / mongo 配置 | 按服务挂载 |

访问 `https://127.0.0.1/` 应看到 dnmmp 首页（`http://127.0.0.1/` 会 301 跳转到 https），`https://127.0.0.1/phpinfo.php` 可验证 PHP 是否打通。

## HTTPS 本地证书

`localhost`、`127.0.0.1` 这类名字**申请不到公网证书**（Let's Encrypt 等只给可公网验证的域名签），所以这里用的是**本地 CA**，不是公网 ACME。证书由 `ssl.sh` 生成，`install.sh` 部署时会自动调用，也可单独重跑。

- **优先 mkcert（受信任，绿锁）**：`ssl.sh` 若找不到正版 mkcert，会自动从官方 GitHub 下载对应平台的二进制到 `bin/mkcert`（重试 3 次），然后 `mkcert -install` 建立本地根证书并装入系统/浏览器信任库，再签发叶子证书。
- **兜底 openssl 自签**：拉不到 mkcert（离线、受限网络、不支持的平台）时，自动改用 openssl 生成同样域名的自签证书。https 照常可用，只是浏览器会提示「不受信任」，测试无碍。
- **覆盖域名**：`localhost`、`127.0.0.1`、`::1`、`*.xqkeji.dev`、`xqkeji.dev`。
- **80 → 443**：nginx 的 80 端口一律 `301` 跳转到 https（见 `etc/nginx/conf.d/default.conf`）。

证书与私钥输出到 `etc/nginx/ssl/local.pem`、`local-key.pem`，挂载进 nginx 的 `/etc/nginx/ssl/`。该目录与 `bin/` 已加入 `.gitignore`，**私钥不会进 git**。已有证书时默认不重签，强制重签：

```bash
FORCE=1 ./ssl.sh
```

几点说明：

- `*.xqkeji.dev` 是**本地测试占位域名**，不是公网解析。要用它访问，需在宿主机 hosts 里把具体子域指到本机，例如 `127.0.0.1 app.xqkeji.dev`，然后访问 `https://app.xqkeji.dev/`。通配符只匹配一级（`a.b.xqkeji.dev` 不匹配）。
- **WSL2**：`ssl.sh` 在 WSL 里运行，mkcert 装的是 **WSL 内**的信任库；Windows 上的浏览器用的是 Windows 证书库，二者不相通。要让 Windows 浏览器也绿锁，用 `mkcert -CAROOT` 找到 `rootCA.pem`（在 `\\wsl$\<发行版>\home\<用户>\.local\share\mkcert\`），把它导入 Windows 的「受信任的根证书颁发机构」。
- **Firefox** 读 NSS 信任库，Linux 上需装 `libnss3-tools`（提供 `certutil`）mkcert 才能装入；缺失时 mkcert 会提示，系统信任仍可能生效。

## CRM 示例站点（crm.xqkeji.dev）

`etc/nginx/conf.d/crm.conf` 是一个 CRM 虚拟主机**示例配置**（只有 nginx 配置，不含项目代码）：`server_name crm.xqkeji.dev`、443 ssl、站点根 `/home/www/crm/www`、PHP 转发 `172.0.0.10:9000`，结构与默认站一致。

用法：

1. 把 CRM 项目代码放到 `www/crm/www`（容器内 `/home/www/crm/www`，入口 `index.php`）。
2. 证书已由 `ssl.sh` 覆盖 `*.xqkeji.dev`，`crm.xqkeji.dev` 直接匹配，**无需重签**。
3. 宿主机 hosts 加一行 `127.0.0.1 crm.xqkeji.dev`，访问 `https://crm.xqkeji.dev/`。
4. `conf.d` 整目录已挂载进 nginx，新增配置无需改 `install.sh`；已在跑的 nginx 执行 `docker exec nginx nginx -s reload` 即可生效（或重跑 `install.sh`）。

`default.conf` 的 80/443 已显式设为 `default_server`，所以 `localhost`、`127.0.0.1` 及任何未匹配域名仍走默认站，只有 `crm.xqkeji.dev` 命中 CRM——避免 `crm.conf` 按字母序排在前面时抢走默认站。新增其它站点同理：写自己的 `server_name`，不要动 `default_server`。

## 重复执行、停止与启动

`install.sh` 可以重复执行：已存在的四个容器会被删除重建，网络存在且网段一致时直接复用，**`data/` 里的数据库数据不会丢**。

```bash
docker stop nginx mysql mongo xqkeji     # 停止
docker start nginx mysql mongo xqkeji    # 启动
docker ps --filter network=xqkeji-net    # 查看状态
docker logs nginx                        # 查看日志
```

## 常见问题

**镜像拉取失败**：脚本首次安装 Docker 时会写入 `/etc/docker/daemon.json` 配置镜像加速（`https://docker.m.daocloud.io`）；已存在该文件时保留原配置不动。该加速站会代理并缓存 Docker Hub 上游，`xqkeji/xqkeji` 也能经它拉取（已实测：manifest 与全部 blob 均返回 200）。若拉取仍失败，多为网络中断（表现为 `unexpected EOF`），重跑脚本即可；也可换成其它可用的 `registry-mirrors`，改完 `systemctl restart docker` 再重跑。

**提示 `iptables: false` 冲突**：旧版 `ubuntu.sh` / `wsl.sh` 会往 `/etc/docker/daemon.json` 写 `"iptables": false`，它会让 `-p` 端口映射失效。删掉该配置项并 `systemctl restart docker` 后重跑即可。

**端口被占用**：80 / 443 / 3306 / 27017 / 9000 已被本机其它服务（含另一套 WSL 环境）占用时，容器会启动失败。先停掉占用方，或改 `install.sh` 里 `-p` 的宿主机端口。

**浏览器提示证书不受信任**：说明当前用的是 openssl 自签兜底证书（mkcert 没拉下来或没装信任）。要绿锁，装好 mkcert 后 `FORCE=1 ./ssl.sh` 重签；WSL 场景另见「HTTPS 本地证书」一节把根证书导入 Windows。

**`bad interpreter: /bin/bash^M`**：脚本被改成 CRLF 换行了。仓库已用 `.gitattributes` 固定 `*.sh` 为 LF；从 Windows 手工拷贝过的副本执行 `sed -i 's/\r$//' install.sh` 修复。

**Alpine 上提示找不到 bash**：先 `apk add bash`。

## 开源协议

本项目采用 **AGPL-3.0-or-later**（GNU Affero 通用公共许可证第 3 版或更新版本），完整文本见 [LICENSE](LICENSE)。

与普通 GPL 相比，AGPL 额外要求：如果你修改本程序并**通过网络向用户提供服务**，也必须向这些用户提供修改后的完整源码。集成或二次分发时请保留版权与许可声明。