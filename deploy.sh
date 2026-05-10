#!/bin/bash

# =================================================================
# TK_learn 终极全能部署脚本 (权限全自动修复 + 502 根治版)
# =================================================================
# 【配置区】
REPO_URL="git@github.com:Dinopell/TK_learn.git"
DEPLOY_DIR="/home/ubuntu/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"
MYSQL_PWD="evnYJdkW02W2U!"
# =================================================================

set -e
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 0. 系统内核优化 (防止 Redis 因内存分配策略导致 502)
echo -e "${YELLOW}>>> 优化系统内核...${NC}"
sudo sysctl vm.overcommit_memory=1 || true

echo -e "${YELLOW}>>> 正在初始化部署环境...${NC}"
# 预先创建目录，防止 Docker 用 root 身份自动创建空目录
mkdir -p $DEPLOY_DIR/{html/sub-app,conf/ssl,mysql_data,redis_data,init,packages}

# 1. 拉取/更新代码
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次克隆仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 更新已有源码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull || true
cd $DEPLOY_DIR

# 2. 数据库 SQL 处理 (强制同步 tk-master)
echo -e "${BLUE}>>> 处理 SQL 脚本...${NC}"
rm -f $DEPLOY_DIR/init/*.sql
[ -d "$REPO_DIR/sql" ] && cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/
INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;" > $INIT_SQL_FILE
for f in $DEPLOY_DIR/init/*.sql; do
    if [[ "$(basename "$f")" != "00_create_databases.sql" ]]; then
        if ! grep -iq "USE " "$f"; then
             sed -i "1i USE \`tk-master\`;" "$f"
        fi
    fi
done

# 3. 生成 Nginx 配置 (解决 403, 500, 502 及 CSP 问题)
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

        # 解决 alicdn 字体等外部资源加载失败的 CSP 策略
        # add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval' *; font-src 'self' data: https://at.alicdn.com;";

        location /sub-app {
            alias /usr/share/nginx/html/sub-app/;
            index index.html;
            try_files \$uri \$uri/ /sub-app/index.html;
        }

        location /deploy/ {
            alias $DEPLOY_DIR/packages/;
            autoindex on;
        }

        # 接口转发：去掉 rewrite 保证路径透传
        location /prod-api/ {
            proxy_pass http://backend:8099/;
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

# 4. 生成 Docker Compose (含 Redis 稳定性修复)
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
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_PWD}"]
      interval: 5s
      timeout: 5s
      retries: 20
    restart: always

  redis:
    image: redis:7.0-alpine
    # 核心修复：防止 Redis 持久化失败导致后端 502
    command: redis-server --stop-writes-on-bgsave-error no
    volumes:
      - ./redis_data:/data
    restart: always

  backend:
    image: eclipse-temurin:17-jdk-alpine
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./repo_source/springboot-app.jar:/app.jar
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    command: >
      /bin/sh -c "
      until nc -z mysql 3306; do echo 'Waiting for MySQL...'; sleep 3; done;
      exec java -Xms512m -Xmx1024m -Dserver.port=8099 -jar /app.jar
      "
    restart: always

  frontend:
    image: nginx:stable-alpine
    ports: ["80:80", "443:443"]
    depends_on:
      - backend
    volumes:
      - ./html:/usr/share/nginx/html
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/ssl:/etc/nginx/ssl:ro
    restart: always
EOF

# 5. 证书处理
[ ! -f "conf/ssl/server.crt" ] && openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout conf/ssl/server.key -out conf/ssl/server.crt -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

# 6. 前端解压与平铺路径
if [ -f "$REPO_DIR/dist.zip" ]; then
    echo -e "${BLUE}>>> 处理前端静态资源...${NC}"
    rm -rf $DEPLOY_DIR/html/*
    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/
    if [ -d "$DEPLOY_DIR/html/dist" ]; then
        mv $DEPLOY_DIR/html/dist/* $DEPLOY_DIR/html/ 2>/dev/null || true
        rm -rf $DEPLOY_DIR/html/dist
    fi
fi

# 7. 启动
echo -e "${YELLOW}>>> 启动 Docker 容器...${NC}"
docker compose up -d

# 8. 数据库同步
echo -e "${BLUE}>>> 同步 SQL 变更...${NC}"
docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" -e "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;"
for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do
    docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" tk-master < "$sql" || echo "Skip $sql"
done

# 9. 权限全自动化修复 (核心新增)
echo -e "${YELLOW}>>> 正在修复目录权限...${NC}"
# a. 将整个部署目录设为 ubuntu 所有，方便 scp 上传
chown -R ubuntu:ubuntu $DEPLOY_DIR
# b. 特别修正 Redis 数据目录权限，防止持久化 502 错误
chmod -R 777 $DEPLOY_DIR/redis_data
# c. 特别修正 Nginx 目录权限（Nginx 镜像默认用户 UID 为 101）
chown -R 101:101 $DEPLOY_DIR/html
chmod -R 755 $DEPLOY_DIR/html

echo -e "${GREEN}>>> ====================================================${NC}"
echo -e "${GREEN}>>> 部署成功！权限已自动修正。${NC}"
echo -e "${GREEN}>>> 现在你可以直接使用 ubuntu 用户进行 scp 上传了。${NC}"
echo -e "${GREEN}>>> ====================================================${NC}"