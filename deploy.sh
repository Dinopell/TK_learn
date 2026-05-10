#!/bin/bash

# =================================================================
# TK_learn 终极全能部署脚本 (适配若依 8099 端口 & 数据库链路修复)
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

# 1. 环境初始化
echo -e "${YELLOW}>>> 清理旧环境并初始化目录...${NC}"
docker compose -f $DEPLOY_DIR/docker-compose.yml down 2>/dev/null || true
mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}
chmod 755 /root $DEPLOY_DIR

# 2. 拉取代码
[ ! -d "$REPO_DIR" ] && git clone $REPO_URL $REPO_DIR || (cd $REPO_DIR && git pull origin main)
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 3. 数据库初始化 (自动建库)
echo -e "${BLUE}>>> 准备 SQL 脚本...${NC}"
rm -rf $DEPLOY_DIR/init/*.sql
[ -d "$REPO_DIR/sql" ] && cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/

INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "-- Auto-gen" > $INIT_SQL_FILE
for f in $DEPLOY_DIR/init/*.sql; do
    fname=$(basename "$f")
    if [[ "$fname" != "00_create_databases.sql" ]]; then
        DB_NAME="${fname%.*}"
        echo "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4;" >> $INIT_SQL_FILE
        sed -i "1i USE \`$DB_NAME\`;" "$f"
    fi
done

# 4. 生成 Nginx 配置 (修正端口为 8099)
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
            proxy_pass http://backend:8099; # 关键：与后端端口对齐
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

# 5. 生成 Docker Compose (关键修复：MySQL 连接与 8099 端口)
cat <<EOF > docker-compose.yml
version: '3.8'
services:
  mysql:
    image: mysql:8.0
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
    restart: always

  backend:
    image: eclipse-temurin:17-jdk-alpine
    depends_on:
      mysql: { condition: service_healthy }
    volumes:
      - ./repo_source/springboot-app.jar:/app.jar
    environment:
      # 1. 确保使用 mysql 容器名 2. 增加连接参数防止链路失败
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai&autoReconnect=true
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    # 使用 sh -c 等待 MySQL 3306 真正开放再运行 Java
    command: >
      /bin/sh -c "
      until nc -z mysql 3306; do echo 'Waiting for MySQL...'; sleep 3; done;
      java -jar /app.jar --server.port=8099
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

# 6. 生成证书并处理前端资源
[ ! -f "conf/ssl/server.crt" ] && openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout conf/ssl/server.key -out conf/ssl/server.crt -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

mkdir -p html/dist
if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d html/
    [ -d "html/dist" ] && mv html/dist/* html/ 2>/dev/null || true
fi
chmod -R 755 html && chown -R 101:101 html

# 7. 启动
docker compose up -d --build

echo -e "${GREEN}>>> 部署完毕！请等待 30 秒后端初始化...${NC}"