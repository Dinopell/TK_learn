#!/bin/bash

# =========================================================
# 颜色定义 (移至顶部确保全局可用)
# =========================================================
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# ========================= 配置区 =========================
REPO_URL="git@github.com:Dinopell/TK_learn.git"
DEPLOY_DIR="/home/ubuntu/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"
MYSQL_PWD="evnYJdkW02W2U!"

# SSH 部署私钥 (Base64) - 确保此字符串末尾没有多余的 % 符号
SSH_KEY_CONTENT="LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQkc1dmJtVUFBQUFFYm05dVpRQUFBQUFBQUFBQkFBQUFNd0FBQUF0emMyZ3RaVwpReU5TVXhPUUFBQUNENkFQdTdNa1JrU3FsT0FXRm1IcWVtTHRKNjllcWhHZnNUcFA3K1pmL1Avd0FBQUppKzRaVVd2dUdWCkZnQUFBQXR6YzJndFpXUXlOVFV4T1FBQUFDRDZBUHU3TWtSa1NxbE9BV0ZtSHFlbUx0SjY5ZXFoR2ZzVHBQNytaZi9QL3cKQUFBRUJLZ0RqSTZ1U1AvcGRFQ0lSUDNsOEo2LzVxMldIMi91b0Q5TlFoQmhwVE8vb0ErN3N5UkdSS3FVNEJZV1llcDZZdQowbnIxNnFFWit4T2svdjVsLzgvL0FBQUFGWHA2YWpNeE9UWTJOVGt6T1RoQU1UWXpMbU52YlE9PQotLS0tLUVORCBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K"
# =========================================================

set -e

# =========================================================
# 0. SSH 自动配置 (实现无人值守拉取代码)
# =========================================================
echo -e "${YELLOW}>>> 正在配置 SSH 认证...${NC}"

mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 清理可能存在的旧私钥并重新写入
rm -f ~/.ssh/id_ed25519
echo "$SSH_KEY_CONTENT" | base64 -d > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519

# 预先扫描 GitHub 指纹，防止 git clone 时卡住
if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
fi

echo -e "${GREEN}>>> SSH 配置完成${NC}"

# =========================================================
# 1. 系统优化
# =========================================================
echo -e "${YELLOW}>>> 优化系统内核参数...${NC}"
sudo sysctl vm.overcommit_memory=1 || true

# =========================================================
# 2. 初始化目录结构
# =========================================================
echo -e "${YELLOW}>>> 初始化部署目录: $DEPLOY_DIR${NC}"
mkdir -p \
$DEPLOY_DIR/html/sub-app \
$DEPLOY_DIR/conf/ssl \
$DEPLOY_DIR/mysql_data \
$DEPLOY_DIR/redis_data \
$DEPLOY_DIR/init \
$DEPLOY_DIR/packages

# =========================================================
# 3. 拉取项目源码
# =========================================================
echo -e "${YELLOW}>>> 正在从 GitHub 同步代码...${NC}"

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
# 4. 数据库初始化文件准备
# =========================================================
echo -e "${YELLOW}>>> 准备 SQL 初始化脚本...${NC}"
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
# 5. 生成 Nginx 配置文件
# =========================================================
echo -e "${YELLOW}>>> 正在生成 Nginx 配置...${NC}"
cat <<EOF > $DEPLOY_DIR/conf/nginx.conf
user nginx;
worker_processes auto;
events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile on;
    client_max_body_size 500m;

    server {
        listen 80;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        ssl_certificate     /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }

        location /sub-app {
            alias /usr/share/nginx/html/sub-app/;
            index index.html;
            try_files \$uri \$uri/ /sub-app/index.html;
        }

        location /deploy/ {
            alias /packages/;
            autoindex on;
        }

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
# 6. 生成 Docker Compose 文件
# =========================================================
echo -e "${YELLOW}>>> 正在生成 Docker Compose...${NC}"
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
    command: java -Xms512m -Xmx1024m -Dserver.port=8099 -jar /app.jar
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
# 7. HTTPS 证书自签名 (如果不存在)
# =========================================================
echo -e "${YELLOW}>>> 检查 SSL 证书...${NC}"
if [ ! -f "$DEPLOY_DIR/conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout $DEPLOY_DIR/conf/ssl/server.key \
    -out $DEPLOY_DIR/conf/ssl/server.crt \
    -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# =========================================================
# 8. 前端静态资源部署
# =========================================================
echo -e "${YELLOW}>>> 解压前端资源...${NC}"
if [ -f "$REPO_DIR/dist.zip" ]; then
    rm -rf $DEPLOY_DIR/html/*
    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/
    if [ -d "$DEPLOY_DIR/html/dist" ]; then
        mv $DEPLOY_DIR/html/dist/* $DEPLOY_DIR/html/ 2>/dev/null || true
        rm -rf $DEPLOY_DIR/html/dist
    fi
fi

# =========================================================
# 9. 权限与所有权修复
# =========================================================
echo -e "${YELLOW}>>> 修复文件系统权限...${NC}"
chown -R ubuntu:ubuntu $DEPLOY_DIR || true
chmod -R 777 $DEPLOY_DIR/redis_data
chmod -R 755 $DEPLOY_DIR/html
chmod -R 755 $DEPLOY_DIR/packages

# =========================================================
# 10. 启动容器集群
# =========================================================
echo -e "${YELLOW}>>> 正在启动 Docker 容器...${NC}"
cd $DEPLOY_DIR
docker compose down || true
docker compose up -d

# =========================================================
# 11. 数据库数据导入 (二次确认)
# =========================================================
echo -e "${YELLOW}>>> 等待数据库就绪并同步 SQL...${NC}"
sleep 15
docker exec -i app-deploy-mysql-1 \
mysql -uroot -p"${MYSQL_PWD}" -e "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;"

for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do
    echo -e "${BLUE}>>> 正在执行: $(basename $sql)${NC}"
    docker exec -i app-deploy-mysql-1 \
    mysql -uroot -p"${MYSQL_PWD}" tk-master < "$sql" || true
done

# =========================================================
# 12. 部署总结
# =========================================================
echo -e "${GREEN}===================================================="
echo "TK_learn 部署任务已完成！"
echo ""
echo "访问地址: https://43.165.185.39"
echo "软件包下载: https://43.165.185.39/deploy/"
echo "====================================================${NC}"
docker ps