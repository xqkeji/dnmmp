#!/bin/bash

####################################
# desc: xqkeji 开发环境搭建脚本
# version: 1.0
# author: xqkeji.cn
####################################
chmod -R a+w log
chmod -R a+w data
#设置文件系统默认权限
cp /etc/wsl.conf /etc/wsl.conf.bak
cat > /etc/wsl.conf << EOF
[boot]
systemd=true
[automount]
options = "metadata,fmask=11,case=dir"
[network]
generateResolvConf=false
EOF
cp /etc/resolv.conf /etc/resolv.conf.bak
cat > /etc/resolv.conf << EOF
nameserver 119.29.29.29
EOF
# 备份软件源
cp /etc/apt/sources.list /etc/apt/sources.list.bak
# 更新软件源
cat > /etc/apt/sources.list << EOF
deb http://mirrors.aliyun.com/ubuntu/ focal main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ focal main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ focal-security main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ focal-security main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ focal-updates main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ focal-updates main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ focal-proposed main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ focal-proposed main restricted universe multiverse

deb http://mirrors.aliyun.com/ubuntu/ focal-backports main restricted universe multiverse
deb-src http://mirrors.aliyun.com/ubuntu/ focal-backports main restricted universe multiverse
EOF
# 更新系统
apt update -y
# 更新可升级软件包
apt upgrade -y
apt install iptables-persistent -y
# 安装docker
apt install docker.io -y
# 设置为国内源镜像并禁止操作iptables
cat > /etc/docker/daemon.json << EOF
{
    "iptables":false
}
EOF
# 重启docker服务
service docker restart
# 拉取镜像
docker pull xqkeji/xqkeji
docker pull mysql
docker pull mongo
docker pull nginx
# docker创建子网
docker network create --subnet=172.0.0.0/24 xqkeji-net
iptables -t nat -A POSTROUTING -s 172.0.0.0/24 -j MASQUERADE
iptables-save > /etc/iptables/rules.v4

# 运行nginx容器
CMD="docker run -p 80:80 --restart=always --net=host --name nginx -v $PWD/www:/home/www -v $PWD/log/nginx:/home/log -v $PWD/etc/nginx/nginx.conf:/etc/nginx/nginx.conf -v $PWD/etc/nginx/conf.d:/etc/nginx/conf.d -d nginx"
eval $CMD

# 运行mongo容器
CMD="docker run -p 27017:27017 --restart=always --net xqkeji-net --ip 172.0.0.100 --name mongo -v $PWD/log/mongo:/home/log -v $PWD/etc/mongo:/home/configdb -v $PWD/data/mongo:/data/db -e MONGO_INITDB_ROOT_USERNAME='root' -e MONGO_INITDB_ROOT_PASSWORD='xqkeji.cn' -d mongo --config /home/configdb/mongodb.conf"
eval $CMD

# 运行mysql容器
CMD="docker run -p 3306:3306 --restart=always --net xqkeji-net --ip 172.0.0.200 --name mysql -v $PWD/etc/mysql:/etc/mysql/conf.d -v $PWD/log/mysql:/logs -v $PWD/data/mysql:/var/lib/mysql  -e MYSQL_ROOT_PASSWORD='xqkeji.cn' -d mysql"
eval $CMD

# 运行xqkeji容器
CMD="docker run -p 9000:9000 --restart=always --net xqkeji-net --ip 172.0.0.10 --name xqkeji -v $PWD/code:/home/code -v $PWD/www:/home/www -v $PWD/etc/php/php.ini:/usr/local/etc/php/php.ini -v $PWD/log/php:/home/log -d xqkeji/xqkeji"
eval $CMD
