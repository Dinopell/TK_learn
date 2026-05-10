#!/bin/bash

# =================================================================
# TK_learn 生产稳定版 (修复 SQL 自动建库 & Nginx 启动版)
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

echo -e "${YELLOW}>>> 正在准备环境...${NC}"
mkdir -p $DEPLOY_DIR/{html/sub-app,conf/ssl,mysql_data,redis_data,init,packages}

# 1. 拉取代码
if [ ! -d "$REPO_DIR" ]; then
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 更新源码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull || true
cd $DEPLOY_DIR

# 2. 数据库 SQL 处理 (核心修复：确保创建数据库)
echo -e "${BLUE}>>> 处理 SQL 脚本并确保数据库存在...${NC}"
rm -rf $DEPLOY_DIR/init/*.sql
[ -d "$REPO_DIR/sql" ] && cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/

# 强制生成建库脚本
INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "-- Auto-generated Database Creation" > $INIT_SQL_FILE
# 显式创建你需要的数据库
echo "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;" >> $INIT_SQL_FILE

for f in $DEPLOY_DIR/init/*.sql; do
    fname=$(basename "$f")
    if [[ "$fname" != "00_create_databases.sql" ]]; then
        # 自动识别文件名作为数据库名（可选，如果你的 SQL 没写 USE）
        DB_NAME="${fname%.*}"
        if ! grep -iq "USE " "$f"; then
             sed -i "1i USE \`tk-master\`;" "$f"
        fi
    fi
done

# 3. 生成 Nginx 配置 (核心修复：防止后端未启动导致 Nginx 崩溃)
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

        location /sub-app {
            alias /usr/share/nginx/html/sub-app/;
            index index.html;
            try_files \$uri \$uri/ /sub-app/index.html;
        }

        location /deploy/ {
            alias $DEPLOY_DIR/packages/;
            autoindex on;
        }

        location ~ ^/(api|prod-api)/ {
            rewrite ^/(api|prod-api)/(.*)\$ /\$2 break;
            # 修复：动态解析 backend，防止 Nginx 启动时找不到主机名报错
            resolver 127.0.0.11 valid=30s;
            set \$upstream_backend backend;
            proxy_pass http://\$upstream_backend:8099;
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

# 4. 生成 Docker Compose
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
    volumes:
      - ./redis_data:/data
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
      - ./html:/app/frontend_dist
      - ./packages:/app/packages
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai&allowPublicKeyRetrieval=true
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    command: >
      /bin/sh -c "
      until nc -z mysql 3306; do echo 'Waiting for MySQL...'; sleep 3; done;
      exec java -Xms512m -Xmx1024m -jar /app.jar --server.port=8099
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

# 5. 证书与前端资源
[ ! -f "conf/ssl/server.crt" ] && openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout conf/ssl/server.key -out conf/ssl/server.crt -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/
fi
chmod -R 755 $DEPLOY_DIR/html

# 6. 启动
echo -e "${YELLOW}>>> 正在启动/更新服务...${NC}"
docker compose up -d

# 7. 核心修复：强制执行 SQL 同步（包含创建数据库）
echo -e "${BLUE}>>> 正在同步数据库变更到 tk-master...${NC}"
# 先确保数据库本身存在
docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" -e "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;"

# 循环执行所有 SQL 脚本
for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do
    echo "正在应用脚本: $(basename $sql)"
    # 使用 -D 指定数据库，强制注入
    docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" tk-master < "$sql" || echo "警告: $sql 执行中部分语句跳过"
done

echo -e "${GREEN}>>> 部署成功！后端与前端现已全部就绪。${NC}"