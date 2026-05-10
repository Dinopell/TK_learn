#!/bin/bash

# =================================================================
# TK_learn 多库全能部署脚本 (生产级路径适配版)
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
echo -e "${YELLOW}>>> 正在清理旧环境...${NC}"
docker compose -f $DEPLOY_DIR/docker-compose.yml down 2>/dev/null || true
rm -rf $DEPLOY_DIR/mysql_data/*
mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}

# 修正宿主机路径权限 (Docker 穿透)
chmod 755 /root
chmod 755 $DEPLOY_DIR

# 2. 生成部署唯一 ID
DEPLOY_ID="proj_$(date +%s | tail -c 6)"
TARGET_DIR="$DEPLOY_DIR/html/$DEPLOY_ID"

# 3. 拉取代码与资源
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次部署，克隆仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 正在更新代码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 4. 数据库初始化脚本同步
echo -e "${BLUE}>>> 自动配置数据库...${NC}"
rm -rf $DEPLOY_DIR/init/*.sql
[ -d "$REPO_DIR/sql" ] && cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/

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

# 5. 生成 SSL 证书
if [ ! -f "conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 6. 生成 Nginx 配置 (注意：\$ 用于转义，防止 Shell 误解析)
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
        server_name _;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 443 ssl;
        ssl_certificate      /etc/nginx/ssl/server.crt;
        ssl_certificate_key  /etc/nginx/ssl/server.key;

        root /usr/share/nginx/html/$DEPLOY_ID;
        index index.html;

        # 修复 405 错误：适配多种 API 前缀并转发
        location ~ ^/(api|prod-api)/ {
            rewrite ^/(api|prod-api)/(.*)\$ /\$2 break;
            proxy_pass http://backend:8099;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;

            # 允许后端处理耗时请求
            proxy_read_timeout 120s;
        }

        location /static/ {
            root /usr/share/nginx/html/$DEPLOY_ID;
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

# 8. 处理前端静态资源
echo -e "${BLUE}>>> 部署前端资源 ID: $DEPLOY_ID ...${NC}"
mkdir -p $TARGET_DIR
if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d $TARGET_DIR/
    if [ -d "$TARGET_DIR/dist" ]; then
        cp -r $TARGET_DIR/dist/* $TARGET_DIR/
    fi
fi

# 清理干扰文件并设置权限
find $TARGET_DIR -name "*.gz" -delete
chmod -R 755 $DEPLOY_DIR/html
chown -R 101:101 $DEPLOY_DIR/html

# 9. 启动服务
echo -e "${BLUE}>>> 启动 Docker 容器...${NC}"
docker compose up -d --build

echo -e "${GREEN}>>> 部署成功！${NC}"
echo -e "${YELLOW}API 匹配规则: /api/* 和 /prod-api/* 均已指向后端${NC}"
echo -e "${YELLOW}访问地址: https://43.165.185.39/ (或带 ID: /$DEPLOY_ID/)${NC}"