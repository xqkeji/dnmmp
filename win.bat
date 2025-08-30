:: ###################################
::  desc: xqkeji 服务器环境搭建脚本
::  version: 1.0
::  author: xqkeji.cn
:: ###################################

# 拉取镜像
docker pull xqkeji/xqkeji
docker pull mysql
docker pull mongo
docker pull nginx
# docker创建子网
docker network create --subnet=172.0.0.0/24 xqkeji-net

# 运行nginx容器
CMD="docker run -p 80:80 --restart=always --net=host --name nginx -v $PWD/web:/home/web -v $PWD/log/nginx:/home/log -v $PWD/etc/nginx/nginx.conf:/etc/nginx/nginx.conf -v $PWD/etc/nginx/conf.d:/etc/nginx/conf.d -d nginx"
call %CMD%

# 运行mongo容器
CMD="docker run -p 27017:27017 --restart=always --net xqkeji-net --ip 172.0.0.100 --name mongo -v $PWD/log/mongo:/home/log -v $PWD/etc/mongo:/home/configdb -v $PWD/data/mongo:/data/db -e MONGO_INITDB_ROOT_USERNAME='root' -e MONGO_INITDB_ROOT_PASSWORD='xqkeji.cn' -d mongo --config /home/configdb/mongodb.conf"
call %CMD%

# 运行mysql容器
CMD="docker run -p 3306:3306 --restart=always --net xqkeji-net --ip 172.0.0.200 --name mysql -v $PWD/etc/mysql:/etc/mysql/conf.d -v $PWD/log/mysql:/logs -v $PWD/data/mysql:/var/lib/mysql  -e MYSQL_ROOT_PASSWORD='xqkeji.cn' -d mysql"
call %CMD%

# 运行xqkeji容器
CMD="docker run -p 9000:9000 --restart=always --net xqkeji-net --ip 172.0.0.10 --name xqkeji -v $PWD/code:/home/code -v $PWD/www:/home/www -v $PWD/etc/php/php.ini:/usr/local/etc/php/php.ini -v $PWD/log/php:/home/log -d xqkeji/xqkeji"
call %CMD%


