# dnmmp
docker+nginx+mysql+mongodb+php集成开发环境

先下载dnmmp，并解压，并将dnmmp移动到合适的路径，因为数据库数据是保存在data目录里，因此要确保有足够的空间，并尽量避免中文路径。

## 1. Window安装 
### 一、安装Window的Docker Desktop
Docker Desktop是为Windows、Mac和Linux设计的，提供了一个图形界面，使得管理容器变得简单。以下是安装Docker Desktop的步骤：

（1）访问Docker官网：

打开浏览器，访问Docker官网。

（2）下载Docker Desktop：

在官网页面上，点击“Get Docker”按钮，然后选择“Docker Desktop for Windows”。

（3）安装Docker Desktop：

下载完成后，双击安装文件并按照屏幕上的指示进行安装。

（4）启动Docker Desktop：

安装完成后，启动Docker Desktop。首次启动时，它可能会要求你允许一些权限或配置一些设置。

（5）验证安装：

打开命令提示符或PowerShell，输入以下命令来验证Docker是否正确安装：

docker --version

如果显示版本号，则表示Docker已成功安装。

### 二、安装dnmmp服务

进入dnmmp目录，直接执行win.bat文件，执行后会自动拉取nginx、mongodb、mysql、xqkeji（PHP）等镜像，并自动启动名称为
nginx、mongodb、mysql、xqkeji等容器服务：nginx(80)、mysql(3306）、mongodb（27017）、php-fpm(9000)。
服务安装后，docker启动，就自动启动服务。

## 2. Window+WSL2安装
### 一、安装WSL2的Ubuntu应用

（1）检查CPU是否开启虚拟化技术
在Window打开“任务管理器”，然后点击“性能选项卡”，再点击进入“CPU”详细页。 在CPU的信息中，有显示“虚拟化：已启用”说明CPU有开启虚拟化技术。 如果没有开启，需要重启电脑进入主板的BIOS管理程序，启用CPU的虚拟机技术。

（2）开启WSL功能
右键任务栏的“开始”图标，进入“系统信息”选项页，回退到“系统”页，再点击进入“可选功能”页，然后滚动到页面底部，见到“相关设置”后，点击“更多Window功能”。 点击开启“适用于Linux的Windows子系统”选项和“虚拟机平台”再点击“确定”，系统重启后，就开启了WSL的功能。

（3）检查WSL
为了避免不必要的错误，建议使用前先升级wsl,打开一个命令行窗口，并输入命令：

wsl --update
更新完成后，可以查看wsl的状态。

wsl --status
状态中的默认版本号需要为0

默认版本：2
如果默认版本不为2，需要修改默认版本号。

wsl --set-default-version 2
（4）安装ubuntu应用
可以从window“开始”菜单进入“Microsoft Store"，在应用商店中搜索”ubuntu"并安装该应用。 安装完成后可以通过以下命令启动"ubuntu"应用。

wsl -d ubuntu
也可以在“开始”的“应用列表”直接点击“Ubuntu”图标来进入“ubuntu"。
### 二、安装dnmmp服务
进入"ubuntu"应用后，执行命令进入dnmmp的目录：
/mnt/d/为D盘、/mnt/e/为E盘，假设dnmmp的目录在D盘，可以执行：
cd /mnt/d/dnmmp（dnmmp可能还带版本号，根据实际情况定）

然后执行:./wsl.sh，执行后会自动拉取nginx、mongodb、mysql、xqkeji（PHP）等镜像，并自动启动名称为
nginx、mongodb、mysql、xqkeji等容器服务：nginx(80)、mysql(3306）、mongodb（27017）、php-fpm(9000)。
服务安装后，一打开ubuntu应用，就自动开启服务。

## 3. Ubuntu(Linux操作系统)安装
直接进入dnmmp目录，并执行：./ubuntu.sh，执行后会自动拉取nginx、mongodb、mysql、xqkeji（PHP）等镜像，并自动启动名称为
nginx、mongodb、mysql、xqkeji等容器服务：nginx(80)、mysql(3306）、mongodb（27017）、php-fpm(9000)。
服务安装后，一打开ubuntu应用，就自动开启服务。

## 4. MacOS安装
### 一、安装MacOS的Docker Desktop
在Mac上安装Docker，有两种主要的方法：使用Docker Desktop（官方推荐的图形化安装方式）或通过命令行使用Docker Engine。以下是两种方法的详细步骤：

(1)前往Docker官网下载

打开浏览器，访问 Docker官网。

点击“Get Docker”按钮，然后选择适用于Mac的Docker Desktop版本。

(2)安装Docker Desktop

下载完成后，打开下载的.dmg文件。

将Docker拖到“Applications”文件夹中以完成安装。

(3)启动Docker Desktop

打开“Applications”文件夹，双击Docker图标以启动应用。

首次运行可能需要一些时间来设置和下载Docker镜像。

(4)验证安装

打开终端（Terminal），输入以下命令来验证Docker是否正确安装：

docker --version

这将显示已安装的Docker版本。
### 二、安装dnmmp服务

通过终端（Terminal）进入dnmmp目录，直接执行mac.sh文件，执行后会自动拉取nginx、mongodb、mysql、xqkeji（PHP）等镜像，并自动启动名称为
nginx、mongodb、mysql、xqkeji等容器服务：nginx(80)、mysql(3306）、mongodb（27017）、php-fpm(9000)。
服务安装后，docker启动，就自动启动服务。