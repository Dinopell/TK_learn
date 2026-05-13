#!/bin/bash

# =================================================================
# TK_learn 最终稳定版部署脚本
# 修复内容：
# 1. SpringBoot 接口 pending / 403
# 2. Nginx proxy_pass rewrite 坑
# 3. Docker 容器路径问题
# 4. /deploy 文件下载 404
# 5. Redis 持久化异常
# 6. 权限问题
# 7. HTTPS 支持
# =================================================================

# 在脚本开头的依赖检查部分加入：
if ! command -v docker &> /dev/null; then
    echo -e "${BLUE}>>> 正在自动安装 Docker...${NC}"
    curl -fsSL https://get.docker.com | bash -s docker
    sudo systemctl start docker
    sudo systemctl enable docker
fi

# ========================= 配置区 =========================
REPO_URL="https://github.com/Dinopell/TK_learn.git"

DEPLOY_DIR="/home/ubuntu/app-deploy"

REPO_DIR="$DEPLOY_DIR/repo_source"

MYSQL_PWD="evnYJdkW02W2U!"
# =========================================================

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}>>> 开始部署 TK_learn...${NC}"

# =========================================================
# 0. 系统优化
# =========================================================
echo -e "${YELLOW}>>> 优化系统内核...${NC}"

sudo sysctl vm.overcommit_memory=1 || true

# =========================================================
# 1. 初始化目录
# =========================================================
echo -e "${YELLOW}>>> 初始化目录...${NC}"

mkdir -p \
$DEPLOY_DIR/html \
$DEPLOY_DIR/html/sub-app \
$DEPLOY_DIR/conf/ssl \
$DEPLOY_DIR/mysql_data \
$DEPLOY_DIR/redis_data \
$DEPLOY_DIR/init \
$DEPLOY_DIR/packages

# =========================================================
# 2. 拉取代码
# =========================================================
echo -e "${YELLOW}>>> 拉取代码...${NC}"

# 0. 环境依赖检查与安装 (核心修复)
echo -e "${YELLOW}>>> 检查环境依赖...${NC}"
if ! command -v git-lfs &> /dev/null; then
    echo -e "${BLUE}>>> 正在安装 git-lfs...${NC}"
    sudo apt-get update && sudo apt-get install git-lfs -y
    git lfs install
fi

# 1. 拉取/更新代码
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次克隆仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 更新已有源码...${NC}"
    cd $REPO_DIR && git fetch --all && git reset --hard origin/main
fi

# 核心修正：强制初始化并拉取 LFS
echo -e "${BLUE}>>> 正在同步 Git LFS 大文件...${NC}"
cd $REPO_DIR
git lfs install --local
git lfs pull
cd $DEPLOY_DIR

# =========================================================
# 3. SQL 初始化
# =========================================================
echo -e "${YELLOW}>>> 初始化 SQL...${NC}"

rm -f $DEPLOY_DIR/init/*.sql || true

if [ -d "$REPO_DIR/sql" ]; then
    cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/
fi

INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"

echo "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;" > $INIT_SQL_FILE

for f in $DEPLOY_DIR/init/*.sql; do

    if [[ "$(basename "$f")" != "00_create_databases.sql" ]]; then

        if ! grep -iq "USE " "$f"; then
            sed -i "1i USE \`tk-master\`;" "$f"
        fi

    fi

done

# =========================================================
# 4. 生成 Nginx 配置
# =========================================================
echo -e "${YELLOW}>>> 生成 Nginx 配置...${NC}"

cat <<EOF > $DEPLOY_DIR/conf/nginx.conf
user nginx;

worker_processes auto;

events {
    worker_connections 1024;
}

http {

    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile on;

    client_max_body_size 500m;

    server {

        listen 80;

        return 301 https://\$host\$request_uri;
    }

    server {

        listen 443 ssl http2;

        ssl_certificate     /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;

        root /usr/share/nginx/html;

        index index.html;

        # =====================================================
        # 前端
        # =====================================================

        location / {

            try_files \$uri \$uri/ /index.html;
        }

        # =====================================================
        # 子应用
        # =====================================================

        location /sub-app {

            alias /usr/share/nginx/html/sub-app/;

            index index.html;

            try_files \$uri \$uri/ /sub-app/index.html;
        }

        # =====================================================
        # 文件下载
        # =====================================================

        location /deploy/ {

            alias /packages/;

            autoindex on;
        }

        # =====================================================
        # SpringBoot 接口代理
        # 重要：
        # 1. 不要 rewrite
        # 2. proxy_pass 后必须带 /
        # =====================================================

        location /prod-api/ {

            proxy_pass http://backend:8099/;

            proxy_http_version 1.1;

            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;

            proxy_connect_timeout 60s;
            proxy_read_timeout 60s;
        }
    }
}
EOF

# =========================================================
# 5. 生成 Docker Compose
# =========================================================
echo -e "${YELLOW}>>> 生成 Docker Compose...${NC}"

cat <<EOF > $DEPLOY_DIR/docker-compose.yml

services:

  mysql:

    image: mysql:8.0

    container_name: app-deploy-mysql-1

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

    container_name: app-deploy-redis-1

    command: redis-server --stop-writes-on-bgsave-error no

    volumes:
      - ./redis_data:/data

    restart: always

  backend:

    image: eclipse-temurin:17-jdk-alpine

    container_name: app-deploy-backend-1

    depends_on:
      mysql:
        condition: service_healthy

      redis:
        condition: service_started

    working_dir: /

    volumes:
      - ./repo_source/springboot-app.jar:/app.jar

    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true
      - SPRING_DATASOURCE_USERNAME=root
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis

    command: >
      java
      -Xms512m
      -Xmx1024m
      -Dserver.port=8099
      -jar
      /app.jar

    restart: always

  frontend:

    image: nginx:stable-alpine

    container_name: app-deploy-frontend-1

    depends_on:
      - backend

    ports:
      - "80:80"
      - "443:443"

    volumes:
      - ./html:/usr/share/nginx/html
      - ./packages:/packages
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/ssl:/etc/nginx/ssl:ro

    restart: always

EOF

# =========================================================
# 6. HTTPS 证书
# =========================================================
echo -e "${YELLOW}>>> 检查 HTTPS 证书...${NC}"

if [ ! -f "$DEPLOY_DIR/conf/ssl/server.crt" ]; then

    openssl req \
    -x509 \
    -nodes \
    -days 3650 \
    -newkey rsa:2048 \
    -keyout $DEPLOY_DIR/conf/ssl/server.key \
    -out $DEPLOY_DIR/conf/ssl/server.crt \
    -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

fi

# =========================================================
# 7. 前端部署
# =========================================================
echo -e "${YELLOW}>>> 部署前端...${NC}"

if [ -f "$REPO_DIR/dist.zip" ]; then

    rm -rf $DEPLOY_DIR/html/*

    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/

    if [ -d "$DEPLOY_DIR/html/dist" ]; then

        mv $DEPLOY_DIR/html/dist/* $DEPLOY_DIR/html/ 2>/dev/null || true

        rm -rf $DEPLOY_DIR/html/dist

    fi
fi

# =========================================================
# 8. 权限修复
# =========================================================
echo -e "${YELLOW}>>> 修复权限...${NC}"

chown -R ubuntu:ubuntu $DEPLOY_DIR

chmod -R 777 $DEPLOY_DIR/redis_data

chmod -R 755 $DEPLOY_DIR/html

chmod -R 755 $DEPLOY_DIR/packages

# =========================================================
# 9. 启动 Docker
# =========================================================
echo -e "${YELLOW}>>> 启动 Docker 容器...${NC}"

cd $DEPLOY_DIR

docker compose down || true

docker compose up -d

# =========================================================
# 10. 等待 MySQL
# =========================================================
echo -e "${YELLOW}>>> 等待 MySQL 启动...${NC}"

sleep 15

# =========================================================
# 11. 执行 SQL
# =========================================================
echo -e "${YELLOW}>>> 导入 SQL...${NC}"

docker exec -i app-deploy-mysql-1 \
mysql -uroot -p"${MYSQL_PWD}" \
-e "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;"

for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do

    echo -e "${BLUE}>>> 执行: $sql${NC}"

    docker exec -i app-deploy-mysql-1 \
    mysql -uroot -p"${MYSQL_PWD}" tk-master < "$sql" || true

done

# =========================================================
# 12. 检查服务
# =========================================================
echo -e "${YELLOW}>>> 检查服务状态...${NC}"

docker ps

# =========================================================
# 13. 完成
# =========================================================
echo -e "${GREEN}"
echo "===================================================="
echo "部署完成！"
echo ""
echo "前端："
echo "https://43.165.185.39"
echo ""
echo ""
echo "文件下载："
echo "https://43.165.185.39/deploy/"
echo "===================================================="
echo -e "${NC}"