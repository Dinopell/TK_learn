#!/bin/bash

# =================================================================
# TK 子台最终部署脚本（动态项目版）
# =================================================================

# ========================= 配置区 =========================

REPO_URL="git@github.com:Dinopell/TK_learn.git"

DEPLOY_DIR="/home/ubuntu/app-deploy"

REPO_DIR="$DEPLOY_DIR/repo_source"

MYSQL_PWD="MAmLvxD#uGD1UbSR"

# -----------------------------------------------------------------
# 总台（主站）连接 — 仅子台后端会直接访问总台；前端只访问本机 /prod-api，
# 经 Gateway（/api/v1/gateway）等由后端再转发到总台。
#
# 对应 Spring 配置：
#   - ruoyi.master.url  ← 环境变量 MASTER_URL（InternalApiService / 网关转发等）
#   - ruoyi.master.apiKey ← MASTER_API_KEY
#   - master.server.url（LicenseAspect 激活校验）← MASTER_SERVER_URL
#
# 部署前可改默认值，或导出环境变量后执行本脚本，例如：
#   export MASTER_URL="https://总台域名/prod-api"
#   export MASTER_API_KEY="你的密钥"
#   ./deploy-repo.sh
# -----------------------------------------------------------------
MASTER_URL="${MASTER_URL:-https://43.165.185.39/prod-api}"
MASTER_API_KEY="${MASTER_API_KEY:-ruoyi-master-key}"
MASTER_SERVER_URL="${MASTER_SERVER_URL:-$MASTER_URL}"
# 总台为自签证书时 true；生产为正规 CA 证书时请改为 false
MASTER_SSL_INSECURE="${MASTER_SSL_INSECURE:-true}"

# 动态项目目录（核心）
PROJECTS_DIR="$DEPLOY_DIR/dynamic-projects"

# =========================================================

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}>>> 开始部署 TK 子台系统...${NC}"

# =========================================================
# 0. 系统优化
# =========================================================

echo -e "${YELLOW}>>> 优化系统参数...${NC}"

sudo sysctl vm.overcommit_memory=1 || true

# =========================================================
# 1. 初始化目录
# =========================================================

echo -e "${YELLOW}>>> 初始化目录...${NC}"

mkdir -p \
$DEPLOY_DIR/html \
$DEPLOY_DIR/conf/ssl \
$DEPLOY_DIR/mysql_data \
$DEPLOY_DIR/redis_data \
$DEPLOY_DIR/init \
$PROJECTS_DIR

# =========================================================
# 2. 拉取代码
# =========================================================

echo -e "${YELLOW}>>> 拉取代码...${NC}"

if [ ! -d "$REPO_DIR" ]; then

    git clone $REPO_URL $REPO_DIR

else

    cd $REPO_DIR

    git pull origin main

fi

cd $REPO_DIR

git lfs pull || true

cd $DEPLOY_DIR

# =========================================================
# 3. SQL 初始化
# =========================================================

echo -e "${YELLOW}>>> 初始化数据库...${NC}"

rm -f $DEPLOY_DIR/init/*.sql || true

if [ -d "$REPO_DIR/sql" ]; then

    cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/

fi

INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"

echo "CREATE DATABASE IF NOT EXISTS \`tk-admin\` DEFAULT CHARACTER SET utf8mb4;" > $INIT_SQL_FILE

for f in $DEPLOY_DIR/init/*.sql; do

    if [[ "$(basename "$f")" != "00_create_databases.sql" ]]; then

        if ! grep -iq "USE " "$f"; then

            sed -i "1i USE \`tk-admin\`;" "$f"

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

    include /etc/nginx/mime.types;

    default_type application/octet-stream;

    sendfile on;

    client_max_body_size 500m;

    server {

        listen 80;

        return 301 https://\$host\$request_uri;
    }

    server {

        listen 443 ssl http2;

        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;

        root /usr/share/nginx/html;

        index index.html;

        # =====================================================
        # 管理后台
        # =====================================================

        location / {

            try_files \$uri \$uri/ /index.html;
        }

        # =====================================================
        # SpringBoot API
        # =====================================================

        location /prod-api/ {

            proxy_pass http://backend:8080/;

            proxy_http_version 1.1;

            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;

            proxy_connect_timeout 60s;
            proxy_read_timeout 60s;
        }

        # =====================================================
        # 动态项目（核心）
        #
        # 示例：
        # /ajk23h1/
        # /x8asd92/
        #
        # 实际映射：
        # /dynamic-projects/ajk23h1/
        # /dynamic-projects/x8asd92/
        #
        # 支持：
        # Vue Router History 模式
        # SPA 刷新不 404
        # =====================================================

        location ~ ^/([^/]+)(/.*)?$ {

            # 排除 prod-api
            if (\$1 = "prod-api") {
                return 404;
            }

            # 动态项目根目录
            root /dynamic-projects;

            index index.html;

            # SPA 支持
            try_files \$uri \$uri/ /\$1/index.html;

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
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-admin?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true
      - SPRING_DATASOURCE_USERNAME=root
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
      - MASTER_URL=${MASTER_URL}
      - MASTER_API_KEY=${MASTER_API_KEY}
      - MASTER_SERVER_URL=${MASTER_SERVER_URL}
      - MASTER_SSL_INSECURE=${MASTER_SSL_INSECURE}

    command: >
      java
      -Xms512m
      -Xmx1024m
      -Dserver.port=8080
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
      - ./dynamic-projects:/dynamic-projects
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
# 7. 部署管理后台前端
# =========================================================

echo -e "${YELLOW}>>> 部署管理后台前端...${NC}"

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

chmod -R 755 $PROJECTS_DIR

# =========================================================
# 9. 启动 Docker
# =========================================================

echo -e "${YELLOW}>>> 启动 Docker 服务...${NC}"

cd $DEPLOY_DIR

docker compose down || true

docker compose up -d

# =========================================================
# 10. 等待 MySQL
# =========================================================

echo -e "${YELLOW}>>> 等待 MySQL 启动...${NC}"

sleep 20

# =========================================================
# 11. 导入 SQL
# =========================================================

echo -e "${YELLOW}>>> 导入 SQL...${NC}"

docker exec -i app-deploy-mysql-1 \
mysql -uroot -p"${MYSQL_PWD}" \
-e "CREATE DATABASE IF NOT EXISTS \`tk-admin\` DEFAULT CHARACTER SET utf8mb4;"

for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do

    echo -e "${BLUE}>>> 执行: $sql${NC}"

    docker exec -i app-deploy-mysql-1 \
    mysql -uroot -p"${MYSQL_PWD}" tk-admin < "$sql" || true

done

# =========================================================
# 12. 检查状态
# =========================================================

echo -e "${YELLOW}>>> 检查 Docker 状态...${NC}"

docker ps

# =========================================================
# 13. 完成
# =========================================================

echo -e "${GREEN}"

echo "===================================================="
echo "TK 子台部署完成"
echo ""
echo "总台后端地址（容器内环境）："
echo "  MASTER_URL=${MASTER_URL}"
echo "  MASTER_SERVER_URL=${MASTER_SERVER_URL}"
echo "  MASTER_SSL_INSECURE=${MASTER_SSL_INSECURE}"
echo ""
echo "管理后台："
echo "https://你的IP/"
echo ""
echo "动态项目目录："
echo "$PROJECTS_DIR"
echo ""
echo "动态项目访问方式："
echo "https://你的IP/随机字符串/"
echo ""
echo "示例："
echo "https://你的IP/ajk23h1/"
echo "===================================================="

echo -e "${NC}"