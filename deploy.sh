#!/bin/bash

# =================================================================
# TK_learn 终极全能部署脚本 (针对 502 与 CSP 路径修复版)
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

echo -e "${YELLOW}>>> 正在初始化部署环境...${NC}"
mkdir -p $DEPLOY_DIR/{html/sub-app,conf/ssl,mysql_data,redis_data,init,packages}

# 1. 拉取/更新代码
if [ ! -d "$REPO_DIR" ]; then
    git clone $REPO_URL $REPO_DIR
else
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull || true
cd $DEPLOY_DIR

# 2. 数据库 SQL 处理
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

# 3. 生成 Nginx 配置 (核心修复：移除强制 rewrite，增加超时，优化 CSP)
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

        # 解决 alicdn 字体等外部资源加载失败的 403 报错 (CSP 优化)
        add_header Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval' *; font-src 'self' data: https://at.alicdn.com;";

        location /sub-app {
            alias /usr/share/nginx/html/sub-app/;
            index index.html;
            try_files \$uri \$uri/ /sub-app/index.html;
        }

        location /deploy/ {
            alias $DEPLOY_DIR/packages/;
            autoindex on;
        }

        # 核心修复：接口转发
        location /prod-api/ {
            # 停止 rewrite，直接透传路径。Spring Boot 后端通过配置 server.context-path 或 Controller 路径识别
            proxy_pass http://backend:8099;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

            # 增加超时保护，防止 502
            proxy_connect_timeout 60s;
            proxy_read_timeout 60s;
            proxy_send_timeout 60s;
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
      exec java -Xms512m -Xmx1024m -jar /app.jar --server.port=8099
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

# 6. 前端解压与权限修复
if [ -f "$REPO_DIR/dist.zip" ]; then
    rm -rf $DEPLOY_DIR/html/*
    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/
    if [ -d "$DEPLOY_DIR/html/dist" ]; then
        mv $DEPLOY_DIR/html/dist/* $DEPLOY_DIR/html/ 2>/dev/null || true
        rm -rf $DEPLOY_DIR/html/dist
    fi
fi
chmod -R 755 $DEPLOY_DIR/html
chown -R 101:101 $DEPLOY_DIR/html

# 7. 启动
docker compose up -d

# 8. SQL 同步
docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" -e "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;"
for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do
    docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" tk-master < "$sql" || echo "Skip $sql"
done

echo -e "${GREEN}>>> 部署修正完成！请刷新页面测试接口。${NC}"