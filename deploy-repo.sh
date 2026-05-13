#!/bin/bash

# =================================================================
# TK 子台最终稳定版部署脚本 (HTTPS + Feature 分支)
# 修复内容：
# 1. 自动安装 Docker/Git-LFS 依赖
# 2. 修复 Git 仓库所有权与安全目录问题 (Dubious ownership)
# 3. 强制同步 Git LFS 大文件（解决 Jar 包损坏/缺失问题）
# 4. 适配 HTTPS 克隆与 feature 分支切换
# 5. 优化动态项目与 prod-api 的 Nginx 匹配逻辑
# =================================================================

# ========================= 配置区 =========================
# 1. 仓库与分支
REPO_URL="https://github.com/Dinopell/TK_learn.git"
REPO_BRANCH="feature"

# 2. 部署路径
DEPLOY_DIR="/home/ubuntu/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"
PROJECTS_DIR="$DEPLOY_DIR/dynamic-projects"

# 3. 数据库密码
MYSQL_PWD="MAmLvxD#uGD1UbSR"

# 4. 总台（主站）对接配置
MASTER_URL="${MASTER_URL:-https://43.165.185.39/prod-api}"
MASTER_API_KEY="${MASTER_API_KEY:-ruoyi-master-key}"
MASTER_SERVER_URL="${MASTER_SERVER_URL:-$MASTER_URL}"
MASTER_SSL_INSECURE="${MASTER_SSL_INSECURE:-true}"
# =========================================================

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}>>> 开始部署 TK 子台系统 [分支: $REPO_BRANCH]...${NC}"

# =========================================================
# 0. 环境依赖检查与系统优化
# =========================================================
echo -e "${YELLOW}>>> 检查环境依赖...${NC}"

# 自动安装 Docker
if ! command -v docker &> /dev/null; then
    echo -e "${BLUE}>>> 正在自动安装 Docker...${NC}"
    curl -fsSL https://get.docker.com | bash -s docker
    sudo systemctl start docker
    sudo systemctl enable docker
fi

# 自动安装 Git LFS
if ! command -v git-lfs &> /dev/null; then
    echo -e "${BLUE}>>> 正在安装 git-lfs...${NC}"
    sudo apt-get update && sudo apt-get install git-lfs -y
    git lfs install
fi

# 系统内核优化
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
# 2. 拉取代码 (HTTPS + Branch 逻辑)
# =========================================================
echo -e "${YELLOW}>>> 准备源码仓库...${NC}"

# 修复 Git 目录权限问题
if [ -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 修复存储库所有权并标记为安全目录...${NC}"
    sudo chown -R $(whoami):$(whoami) "$REPO_DIR"
    git config --global --add safe.directory "$REPO_DIR"
fi

# 拉取或更新
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次克隆分支: $REPO_BRANCH ...${NC}"
    git clone -b $REPO_BRANCH $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 强制同步分支: $REPO_BRANCH ...${NC}"
    cd $REPO_DIR
    git fetch --all
    # 强制切换并重置到指定的分支
    git checkout $REPO_BRANCH || git checkout -b $REPO_BRANCH origin/$REPO_BRANCH
    git reset --hard origin/$REPO_BRANCH
fi

# 核心修正：强制同步 Git LFS 大文件（防止 JAR 文件只是文本指针）
echo -e "${BLUE}>>> 正在同步 Git LFS 大文件...${NC}"
cd $REPO_DIR
git lfs install --local
git lfs pull
cd $DEPLOY_DIR

# =========================================================
# 3. SQL 初始化
# =========================================================
echo -e "${YELLOW}>>> 准备 SQL 脚本...${NC}"

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
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;

        root /usr/share/nginx/html;
        index index.html;

        # 管理后台
        location / {
            try_files \$uri \$uri/ /index.html;
        }

        # SpringBoot API 代理
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

        # 动态项目匹配规则 (SPA 支持)
        location ~ ^/([^/]+)(/.*)?$ {
            # 排除 API 和静态 favicon
            if (\$1 ~* ^(prod-api|favicon\.ico|static)) {
                break;
            }
            root /dynamic-projects;
            index index.html;
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
      java -Xms512m -Xmx1024m -Dserver.port=8080 -jar /app.jar
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
# 6. HTTPS 证书与前端资源
# =========================================================
echo -e "${YELLOW}>>> 处理证书与前端静态资源...${NC}"

if [ ! -f "$DEPLOY_DIR/conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout $DEPLOY_DIR/conf/ssl/server.key \
    -out $DEPLOY_DIR/conf/ssl/server.crt \
    -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

if [ -f "$REPO_DIR/dist.zip" ]; then
    rm -rf $DEPLOY_DIR/html/*
    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/
    if [ -d "$DEPLOY_DIR/html/dist" ]; then
        mv $DEPLOY_DIR/html/dist/* $DEPLOY_DIR/html/ 2>/dev/null || true
        rm -rf $DEPLOY_DIR/html/dist
    fi
fi

# =========================================================
# 7. 启动服务与数据库导入
# =========================================================
echo -e "${YELLOW}>>> 修复权限并启动服务...${NC}"

chown -R ubuntu:ubuntu $DEPLOY_DIR
chmod -R 777 $DEPLOY_DIR/redis_data
chmod -R 755 $DEPLOY_DIR/html
chmod -R 755 $PROJECTS_DIR

cd $DEPLOY_DIR
docker compose down || true
docker compose up -d

echo -e "${YELLOW}>>> 等待 MySQL 启动并导入 SQL...${NC}"
sleep 20

docker exec -i app-deploy-mysql-1 \
mysql -uroot -p"${MYSQL_PWD}" \
-e "CREATE DATABASE IF NOT EXISTS \`tk-admin\` DEFAULT CHARACTER SET utf8mb4;"

for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do
    echo -e "${BLUE}>>> 执行: $sql${NC}"
    docker exec -i app-deploy-mysql-1 \
    mysql -uroot -p"${MYSQL_PWD}" tk-admin < "$sql" || true
done

# =========================================================
# 8. 完成
# =========================================================
echo -e "${GREEN}"
echo "===================================================="
echo "TK 子台部署完成！"
echo "分支: $REPO_BRANCH"
echo "总台对接: $MASTER_URL"
echo ""
echo "管理后台: https://你的IP/"
echo "动态项目访问: https://你的IP/随机路径/"
echo "===================================================="
echo -e "${NC}"
docker ps