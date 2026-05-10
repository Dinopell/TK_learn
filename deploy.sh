#!/bin/bash

# =================================================================
# TK_learn 多库全能部署脚本 (终极路径对齐 + 权限修正版)
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
# 先停止容器，防止文件占用
docker compose -f $DEPLOY_DIR/docker-compose.yml down 2>/dev/null || true
rm -rf $DEPLOY_DIR/mysql_data/*
mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}

# 重要：修正宿主机目录权限，允许 Docker 容器访问 /root 路径
chmod 755 /root
chmod 755 $DEPLOY_DIR

# 2. 生成本次部署的唯一 ID (提前生成，用于 Nginx 配置注入)
DEPLOY_ID="proj_$(date +%s | tail -c 6)"
TARGET_DIR="$DEPLOY_DIR/html/$DEPLOY_ID"

# 3. 拉取代码
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次部署，克隆仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 正在更新代码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 4. 同步 SQL 并自动生成建库脚本
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

# 5. 生成自签名 SSL 证书
if [ ! -f "conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 6. 生成 Nginx 配置 (核心修改：将 $DEPLOY_ID 注入 root)
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
        
        # 修正：将全局 root 指向当前部署的子目录
        # 这样请求 /static/... 时会直接去 /usr/share/nginx/html/$DEPLOY_ID/static 寻找
        root /usr/share/nginx/html/$DEPLOY_ID;
        index index.html;

        # 处理绝对路径加载的静态资源
        location /static/ {
            root /usr/share/nginx/html/$DEPLOY_ID;
            autoindex off;
        }

        # 处理 Favicon
        location /favicon.ico {
            root /usr/share/nginx/html/$DEPLOY_ID;
        }

	# 针对 API 请求的转发
        location /api/ {
            # 解决 405 错误的关键：如果后端报错 405，强制转换错误处理（可选但有效）
            error_page 405 =200 @405_to_backend;
            
            # 去掉末尾斜杠的技巧：
            # 如果前端请求 /api/login，转发给 backend:8080/login
            proxy_pass http://backend:8080/; 
            
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            # 这里的超时设置稍微加长，防止后端处理大 SQL 时断开
            proxy_connect_timeout 60s;
            proxy_read_timeout 60s;
            proxy_send_timeout 60s;
        }

        # 针对静态文件的处理，确保不拦截 API
        location /static/ {
            root /usr/share/nginx/html/$DEPLOY_ID;
        }

        # 保持对带 ID 路径访问的支持
        location ~ ^/$DEPLOY_ID/(.*)$ {
            alias /usr/share/nginx/html/$DEPLOY_ID/\$1;
            try_files "" =404;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 7. 生成 Docker Compose
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

# 8. 前端资源处理与平铺优化
echo -e "${BLUE}>>> 处理前端静态资源并修正目录结构...${NC}"
mkdir -p $TARGET_DIR

if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d $TARGET_DIR/
    # 关键修正：如果解压出来有 dist 文件夹，将其内容移动到 TARGET_DIR 根部
    if [ -d "$TARGET_DIR/dist" ]; then
        cp -r $TARGET_DIR/dist/* $TARGET_DIR/
    fi
fi

# 移除可能引起 500 的压缩文件
find $TARGET_DIR -name "*.gz" -delete

# 关键：递归设置权限，确保容器 UID 101 (nginx) 可读
chmod -R 755 $DEPLOY_DIR/html
chown -R 101:101 $DEPLOY_DIR/html

# 9. 启动容器
echo -e "${BLUE}>>> 正在启动容器...${NC}"
docker compose up -d --build

echo -e "${GREEN}>>> 部署成功！${NC}"
echo -e "${YELLOW}当前部署 ID: $DEPLOY_ID${NC}"
echo -e "${YELLOW}访问路径: https://服务器IP/$DEPLOY_ID/ 或直接访问 https://服务器IP/${NC}"