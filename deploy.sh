#!/bin/bash

# =================================================================
# TK_learn 多库全能部署脚本 (优化权限与路径版)
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

# 1. 环境清理与目录初始化
echo -e "${YELLOW}>>> 正在清理并初始化环境...${NC}"
docker compose -f $DEPLOY_DIR/docker-compose.yml down 2>/dev/null || true
rm -rf $DEPLOY_DIR/mysql_data/*
mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}

# 重要：修正宿主机目录权限，允许 Docker 容器访问 /root 路径
chmod 755 /root
chmod 755 $DEPLOY_DIR

# 2. 拉取代码
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次部署，克隆仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 正在更新代码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 3. 同步 SQL 并自动生成建库脚本
echo -e "${BLUE}>>> 自动配置多数据库初始化...${NC}"
rm -rf $DEPLOY_DIR/init/*.sql
if [ -d "$REPO_DIR/sql" ]; then
    cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/
fi

INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "-- Auto-generated" > $INIT_SQL_FILE
for f in $DEPLOY_DIR/init/*.sql; do
    fname=$(basename "$f")
    if [[ "$fname" != "00_create_databases.sql" ]]; then
        DB_NAME="${fname%.*}"
        echo "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4;" >> $INIT_SQL_FILE
        sed -i "1i USE \`$DB_NAME\`;" "$f"
    fi
done

# 4. 生成自签名 SSL 证书
if [ ! -f "conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 5. 生成 Nginx 配置 (针对 static 目录优化)
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
        
        # 核心修复：将 root 直接指向你的项目文件夹
        # 这样浏览器请求 /static/... 时，Nginx 会去这个目录下找
        root /usr/share/nginx/html/$DEPLOY_ID;
        index index.html;

        # 1. 优先匹配带 ID 的路径（为了兼容你现有的访问习惯）
        location ~ ^/proj_([0-9]+)/(.*)$ {
            alias /usr/share/nginx/html/proj_\$1/\$2;
        }

        # 2. 修复：处理浏览器直接请求根路径的静态资源
        location /static/ {
            root /usr/share/nginx/html/$DEPLOY_ID;
            autoindex off;
        }

        location /api/ {
            proxy_pass http://backend:8080/;
            proxy_set_header Host \$host;
        }

        # 3. 兜底处理
        location / {
            root /usr/share/nginx/html/$DEPLOY_ID;
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 6. 生成 Docker Compose
cat <<EOF > docker-compose.yml
version: '3.8'
services:
  mysql:
    image: mysql:8.0
    ports: ["3306:3306"]
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
    ports: ["6379:6379"]
    restart: always

  backend:
    image: eclipse-temurin:17-jdk-alpine
    depends_on:
      mysql: { condition: service_healthy }
    volumes:
      - ./repo_source/springboot-app.jar:/app.jar
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    command: ["/bin/sh", "-c", "sleep 20 && java -jar /app.jar"]
    restart: always

  frontend:
    image: nginx:stable-alpine
    ports: ["80:80", "443:443"]
    volumes:
      - ./html:/usr/share/nginx/html
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/ssl:/etc/nginx/ssl:ro
    restart: always
EOF

# 7. 前端资源处理与权限修复
echo -e "${BLUE}>>> 处理前端静态资源...${NC}"
DEPLOY_ID="proj_$(date +%s | tail -c 6)"
TARGET_DIR="html/$DEPLOY_ID"
mkdir -p $TARGET_DIR

if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d $TARGET_DIR/
    # 兼容性：如果解压出来有一层 dist 目录，将其内容移动到根部
    if [ -d "$TARGET_DIR/dist" ]; then
        mv $TARGET_DIR/dist/* $TARGET_DIR/ 2>/dev/null || true
    fi
fi

# 清理可能干扰 Nginx 的压缩文件
find $TARGET_DIR -name "*.gz" -delete

# 关键：递归设置权限，确保 Nginx 容器(UID 101)可读
chmod -R 755 $DEPLOY_DIR/html
chown -R 101:101 $DEPLOY_DIR/html

# 8. 启动容器
echo -e "${BLUE}>>> 正在启动容器...${NC}"
docker compose up -d --build

echo -e "${GREEN}>>> 部署成功！${NC}"
echo -e "${YELLOW}访问路径: https://服务器IP/$DEPLOY_ID/${NC}"