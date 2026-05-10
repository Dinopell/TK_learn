#!/bin/bash

# =================================================================
# TK_learn 终极全能部署脚本 (显式端口暴露 & 若依 8099 适配版)
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
echo -e "${YELLOW}>>> 正在清理并初始化部署目录...${NC}"
docker compose -f $DEPLOY_DIR/docker-compose.yml down 2>/dev/null || true
mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}
chmod 755 /root $DEPLOY_DIR

# 2. 拉取代码
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 克隆仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 更新代码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 3. 数据库 SQL 处理
echo -e "${BLUE}>>> 准备数据库脚本...${NC}"
rm -rf $DEPLOY_DIR/init/*.sql
[ -d "$REPO_DIR/sql" ] && cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/

INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "-- Auto-generated database creation" > $INIT_SQL_FILE
for f in $DEPLOY_DIR/init/*.sql; do
    fname=$(basename "$f")
    if [[ "$fname" != "00_create_databases.sql" ]]; then
        DB_NAME="${fname%.*}"
        echo "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4;" >> $INIT_SQL_FILE
        sed -i "1i USE \`$DB_NAME\`;" "$f"
    fi
done

# 4. 生成 Nginx 配置 (对齐 8099)
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

        # 匹配 prod-api 和 api 路径
        location ~ ^/(api|prod-api)/ {
            rewrite ^/(api|prod-api)/(.*)\$ /\$2 break;
            # 关键：转发到容器名 backend 的 8099 端口
            proxy_pass http://backend:8099;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 5. 生成 Docker Compose (显式暴露 8099 端口)
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
    # 显式映射端口，解决 docker ps 为空的问题
    ports:
      - "8099:8099"
    deploy:
      resources:
        limits:
          memory: 1024M
    depends_on:
      mysql: { condition: service_healthy }
    volumes:
      - ./repo_source/springboot-app.jar:/app.jar
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai&autoReconnect=true
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
      # 显式环境变量覆盖
      - SERVER_PORT=8099
    command: >
      /bin/sh -c "
      until nc -z mysql 3306; do
        echo 'Waiting for MySQL port 3306...';
        sleep 3;
      done;
      echo 'MySQL is Ready. Starting Java App on port 8099...';
      java -Xms512m -Xmx1024m -jar /app.jar --server.port=8099
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

# 6. 生成证书并处理前端文件
if [ ! -f "conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

echo -e "${BLUE}>>> 部署前端资源...${NC}"
if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d html/
    # 兼容解压后带 dist 目录或直接平铺的情况
    if [ -d "html/dist" ]; then
        cp -r html/dist/* html/
    fi
fi
chmod -R 755 html && chown -R 101:101 html

# 7. 启动容器
echo -e "${YELLOW}>>> 执行 Docker Compose Up...${NC}"
docker compose up -d --build

echo -e "${GREEN}>>> 部署指令已发出！${NC}"
echo -e "${BLUE}>>> 关键检查项：${NC}"
echo -e "1. 运行 'docker ps' 确保 backend 容器显示 8099->8099"
echo -e "2. 运行 'docker logs -f app-deploy-backend-1' 查看启动日志"
echo -e "3. 如果看到 'Tomcat started on port(s): 8099'，说明 502/504 会立即消失。"