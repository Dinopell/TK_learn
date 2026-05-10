#!/bin/bash

# =================================================================
# TK_learn 多库全能部署脚本 (MySQL 3306/Redis 6379 开放版)
# =================================================================
# 【配置区】
REPO_URL="git@github.com:Dinopell/TK_learn.git"
DEPLOY_DIR="/root/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"
MYSQL_PWD="evnYJdkW02W2U!" 
# =================================================================

set -e
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 0. 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${BLUE}请使用 root 权限运行此脚本 (sudo ./deploy.sh)${NC}"
    exit 1
fi

# 1. 环境清理 (推倒重来模式)
echo -e "${YELLOW}>>> 正在深度清理旧环境...${NC}"
docker compose -f $DEPLOY_DIR/docker-compose.yml down 2>/dev/null || true
# 注意：这会删除所有数据库数据，确保你已将最新的 SQL 放入 init 目录
rm -rf $DEPLOY_DIR/mysql_data/* # 2. 安装基础依赖
echo -e "${BLUE}>>> 正在安装依赖环境...${NC}"
apt-get update && apt-get install -y git git-lfs curl unzip openssl docker.io docker-compose-v2
git lfs install

# 3. 目录初始化
echo -e "${BLUE}>>> 初始化部署目录...${NC}"
mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}

# 4. 拉取代码
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次部署，克隆私有仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 正在更新仓库代码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 5. 【自动化核心】从仓库同步 SQL 并生成建库脚本
echo -e "${BLUE}>>> 正在从仓库同步 SQL 资源...${NC}"

# 清空旧的初始化脚本，确保干净
rm -rf $DEPLOY_DIR/init/*.sql

# 从拉取下来的代码仓中拷贝 SQL 文件到 init 目录
if [ -d "$REPO_DIR/sql" ]; then
    cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/
    echo -e "${GREEN}>>> 已同步 $(ls $REPO_DIR/sql | wc -l) 个 SQL 文件${NC}"
else
    echo -e "${YELLOW}警告：仓库中未找到 sql 文件夹，请检查路径！${NC}"
fi

# 自动生成建库语句
INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "-- 自动生成的建库脚本" > $INIT_SQL_FILE

# 遍历 init 目录下所有的业务 SQL（排除掉刚创建的 00 脚本本身）
for f in $DEPLOY_DIR/init/*.sql; do
    fname=$(basename "$f")
    if [[ "$fname" != "00_create_databases.sql" ]]; then
        # 以文件名为库名（如 quartz.sql -> 库名 quartz）
        DB_NAME="${fname%.*}"
        echo "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" >> $INIT_SQL_FILE
        # 在每个 SQL 文件第一行插入 USE 语句，确保数据导对地方
        sed -i "1i USE \`$DB_NAME\`;" "$f"
    fi
done

# 6. 生成自签名 SSL 证书
if [ ! -f "conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 7. 生成 Nginx 配置
cat <<EOF > conf/nginx.conf
user  nginx;
worker_processes  auto;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    server {
        listen 80;
        return 301 https://\$host\$request_uri;
    }
    server {
        listen 443 ssl;
        ssl_certificate      /etc/nginx/ssl/server.crt;
        ssl_certificate_key  /etc/nginx/ssl/server.key;
        root /usr/share/nginx/html;
        location ~ ^/([^/]+)/assets/(.*)$ {
            alias /usr/share/nginx/html/\$1/assets/\$2;
        }
        location /api/ {
            proxy_pass http://backend:8080/;
            proxy_set_header Host \$host;
        }
        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 8. 生成 Docker Compose (放开端口版)
cat <<EOF > docker-compose.yml
version: '3.8'
services:
  mysql:
    image: mysql:8.0
    ports:
      - "3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_PWD}
    volumes:
      - ./mysql_data:/var/lib/mysql
      - ./init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_PWD}"]
      interval: 5s
      retries: 10
    restart: always

  redis:
    image: redis:7.0-alpine
    ports:
      - "6379:6379"
    restart: always

  backend:
    image: eclipse-temurin:17-jdk-alpine
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./repo_source/springboot-app.jar:/app.jar
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Shanghai
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    command: ["/bin/sh", "-c", "sleep 20 && java -jar /app.jar"]
    restart: always

  frontend:
    image: nginx:stable-alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./html:/usr/share/nginx/html
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/ssl:/etc/nginx/ssl:ro
    restart: always
EOF

# 9. 前端资源处理
echo -e "${BLUE}>>> 处理前端静态资源...${NC}"
DEPLOY_ID="proj_$(date +%s | tail -c 6)"
mkdir -p html/$DEPLOY_ID
if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d html/$DEPLOY_ID/
    mv html/$DEPLOY_ID/dist/* html/$DEPLOY_ID/ 2>/dev/null || true
fi

# 10. 启动容器
echo -e "${BLUE}>>> 正在启动 Docker 容器...${NC}"
docker compose up -d --build

echo -e "${GREEN}>>> 部署成功！项目路径: https://服务器IP/$DEPLOY_ID/${NC}"