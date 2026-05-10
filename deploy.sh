#!/bin/bash

# =================================================================
# TK_learn 终极全能部署脚本 (SQL 强制更新 & 内存优化版)
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

# 1. 环境清理 (强制清理数据以确保 SQL 更新生效)
echo -e "${YELLOW}>>> 正在深度清理旧环境 (包括数据卷)...${NC}"
docker compose -f $DEPLOY_DIR/docker-compose.yml down -v 2>/dev/null || true
# 物理删除 MySQL 数据目录，强制触发重新初始化
rm -rf $DEPLOY_DIR/mysql_data
mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}
chmod 755 /root $DEPLOY_DIR

# 2. 拉取代码
if [ ! -d "$REPO_DIR" ]; then
    git clone $REPO_URL $REPO_DIR
else
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 3. 数据库 SQL 处理
echo -e "${BLUE}>>> 准备数据库脚本...${NC}"
rm -rf $DEPLOY_DIR/init/*.sql
[ -d "$REPO_DIR/sql" ] && cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/

INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "-- Auto-generated" > $INIT_SQL_FILE
for f in $DEPLOY_DIR/init/*.sql; do
    fname=$(basename "$f")
    if [[ "$fname" != "00_create_databases.sql" ]]; then
        DB_NAME="${fname%.*}"
        echo "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4;" >> $INIT_SQL_FILE
        # 仅在文件开头没有 USE 时添加，防止重复
        if ! grep -q "USE \`$DB_NAME\`" "$f"; then
            sed -i "1i USE \`$DB_NAME\`;" "$f"
        fi
    fi
done

# 4. 生成 Nginx 配置
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
        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        root /usr/share/nginx/html;
        index index.html;
        location ~ ^/(api|prod-api)/ {
            rewrite ^/(api|prod-api)/(.*)\$ /\$2 break;
            proxy_pass http://backend:8099;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 5. 生成 Docker Compose (移除过时的 version，优化健康检查)
cat <<EOF > docker-compose.yml
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_PWD}
    volumes:
      - ./mysql_data:/var/lib/mysql
      - ./init:/docker-entrypoint-initdb.d
    healthcheck:
      # 适当增加超时和重试，给大型 SQL 导入留出时间
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_PWD}"]
      interval: 10s
      timeout: 10s
      retries: 15
    restart: always

  redis:
    image: redis:7.0-alpine
    restart: always

  backend:
    image: eclipse-temurin:17-jdk-alpine
    ports:
      - "8099:8099"
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./repo_source/springboot-app.jar:/app.jar
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai&autoReconnect=true
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    # 增加内存分配解决 OOM 问题
    command: >
      /bin/sh -c "
      until nc -z mysql 3306; do echo 'Waiting for MySQL...'; sleep 3; done;
      java -Xms1024m -Xmx2048m -jar /app.jar --server.port=8099
      "
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

# 6. 证书与前端资源
[ ! -f "conf/ssl/server.crt" ] && openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout conf/ssl/server.key -out conf/ssl/server.crt -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

if [ -f "$REPO_DIR/dist.zip" ]; then
    rm -rf html/*
    unzip -o $REPO_DIR/dist.zip -d html/
    [ -d "html/dist" ] && mv html/dist/* html/ 2>/dev/null || true
fi
chmod -R 755 html && chown -R 101:101 html

# 7. 启动
echo -e "${YELLOW}>>> 正在启动容器 (SQL 较多时可能需要 1-2 分钟)...${NC}"
docker compose up -d --build

echo -e "${GREEN}>>> 部署指令已发出！${NC}"