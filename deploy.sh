#!/bin/bash

# =================================================================
# TK_learn 终极全能部署脚本 (生产环境全修复稳定版)
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
# 确保所有必要的物理目录存在
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

# 2. 数据库 SQL 处理 (确保创建数据库并支持变更)
echo -e "${BLUE}>>> 处理 SQL 初始化脚本...${NC}"
# 清理旧的 init 脚本，同步仓库中最新的 SQL
rm -f $DEPLOY_DIR/init/*.sql
[ -d "$REPO_DIR/sql" ] && cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/

# 强制生成建库脚本，确保 tk-master 库一定存在
INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "-- Auto-generated Database Creation" > $INIT_SQL_FILE
echo "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;" >> $INIT_SQL_FILE

# 批量处理 SQL 脚本，确保每个脚本都能定位到 tk-master
for f in $DEPLOY_DIR/init/*.sql; do
    if [[ "$(basename "$f")" != "00_create_databases.sql" ]]; then
        if ! grep -iq "USE " "$f"; then
             sed -i "1i USE \`tk-master\`;" "$f"
        fi
    fi
done

# 3. 生成 Nginx 配置文件 (解决前端 403、500 以及后端启动顺序问题)
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
        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;
        root /usr/share/nginx/html;
        index index.html;

        # 1. 子台小页面项目 (独立路径)
        location /sub-app {
            alias /usr/share/nginx/html/sub-app/;
            index index.html;
            try_files \$uri \$uri/ /sub-app/index.html;
        }

        # 2. 总台暴露包路径 (供子台拉取)
        location /deploy/ {
            alias $DEPLOY_DIR/packages/;
            autoindex on;
        }

        # 3. 反向代理后端接口 (解决启动时 backend 主机名无法解析报错)
        location ~ ^/(api|prod-api)/ {
            rewrite ^/(api|prod-api)/(.*)\$ /\$2 break;
            resolver 127.0.0.11 valid=30s;
            set \$upstream_backend backend;
            proxy_pass http://\$upstream_backend:8099;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        # 4. 根目录前端项目 (解决 500 循环重定向问题)
        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 4. 生成 Docker Compose (数据持久化版)
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

# 5. 生成 SSL 证书
[ ! -f "conf/ssl/server.crt" ] && openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout conf/ssl/server.key -out conf/ssl/server.crt -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

# 6. 处理前端 dist.zip (核心修复：解决解压后的目录嵌套问题)
if [ -f "$REPO_DIR/dist.zip" ]; then
    echo -e "${BLUE}>>> 正在处理前端 dist 包...${NC}"
    # 清理旧静态文件
    rm -rf $DEPLOY_DIR/html/*
    # 解压到 html 目录
    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/
    # 如果解压出来多了个 dist 目录，自动平铺到根目录
    if [ -d "$DEPLOY_DIR/html/dist" ]; then
        mv $DEPLOY_DIR/html/dist/* $DEPLOY_DIR/html/ 2>/dev/null || true
        rm -rf $DEPLOY_DIR/html/dist
    fi
fi
# 修复目录所有权为 Nginx 容器用户 (101)
chmod -R 755 $DEPLOY_DIR/html
chown -R 101:101 $DEPLOY_DIR/html

# 7. 启动容器
echo -e "${YELLOW}>>> 正在启动 Docker 容器...${NC}"
docker compose up -d

# 8. 同步数据库变更 (核心修复：即使容器已运行，也强制推送 SQL 变更)
echo -e "${BLUE}>>> 正在强制同步数据库 SQL 到 tk-master...${NC}"
# 确保 tk-master 库存在
docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" -e "CREATE DATABASE IF NOT EXISTS \`tk-master\` DEFAULT CHARACTER SET utf8mb4;"

# 循环执行所有 SQL
for sql in $(ls $DEPLOY_DIR/init/*.sql | sort); do
    echo "执行 SQL: $(basename $sql)"
    docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" tk-master < "$sql" || echo "跳过执行: $sql"
done

echo -e "${GREEN}>>> ====================================================${NC}"
echo -e "${GREEN}>>> 部署成功！${NC}"
echo -e "${GREEN}>>> 前端访问: https://43.165.185.39/${NC}"
echo -e "${GREEN}>>> 备选路径: https://43.165.185.39/sub-app/${NC}"
echo -e "${GREEN}>>> 下载地址: http://43.165.185.39/deploy/dist.zip${NC}"
echo -e "${GREEN}>>> ====================================================${NC}"