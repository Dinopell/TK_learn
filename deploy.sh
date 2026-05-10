#!/bin/bash

# =================================================================
# TK_learn 生产稳定版 (Ubuntu 用户 & 数据持久化 & 多项目版)
# =================================================================
# 【配置区】
REPO_URL="git@github.com:Dinopell/TK_learn.git"
# 1. 建议使用 ubuntu 用户家目录，避免 /root 权限限制
DEPLOY_DIR="/home/ubuntu/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"
MYSQL_PWD="evnYJdkW02W2U!"
# =================================================================

set -e
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 1. 环境准备 (不再删除 mysql_data)
echo -e "${YELLOW}>>> 正在准备环境...${NC}"
mkdir -p $DEPLOY_DIR/{html/sub-app,conf/ssl,mysql_data,redis_data,init,packages}

# 2. 拉取代码
if [ ! -d "$REPO_DIR" ]; then
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 更新源码...${NC}"
    cd $REPO_DIR && git pull origin main
fi
cd $REPO_DIR && git lfs pull || true
cd $DEPLOY_DIR

# 3. 数据库 SQL 处理 (支持变更的核心逻辑)
echo -e "${BLUE}>>> 处理 SQL 脚本...${NC}"
# 注意：docker-compose-init 仅在首次启动时自动执行。
# 对于后续的 SQL 变更，建议你在 SQL 文件中使用 "CREATE TABLE IF NOT EXISTS"
# 或者手动执行增量更新脚本。这里我们将 SQL 拷贝到 init 备用。
cp $REPO_DIR/sql/*.sql $DEPLOY_DIR/init/ 2>/dev/null || true

# 4. 生成 Nginx 配置 (支持多项目共存)
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

        # 子台小页面项目 (独立子目录)
        location /sub-app {
            alias /usr/share/nginx/html/sub-app/;
            index index.html;
            try_files \$uri \$uri/ /sub-app/index.html;
        }

        # 总台暴露分发包的路径 (供子台通过 HTTP 拉取)
        location /deploy/ {
            alias $DEPLOY_DIR/packages/;
            autoindex on;
        }

        location ~ ^/(api|prod-api)/ {
            rewrite ^/(api|prod-api)/(.*)\$ /\$2 break;
            proxy_pass http://backend:8099;
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

# 5. 生成 Docker Compose (移除 down -v 的威胁)
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
      interval: 10s
      timeout: 5s
      retries: 10
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
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/tk-master?useSSL=false&serverTimezone=Asia/Shanghai
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    command: >
      /bin/sh -c "
      until nc -z mysql 3306; do echo 'Waiting for MySQL...'; sleep 3; done;
      exec java -Xms512m -Xmx1024m -jar /app.jar --spring.datasource.url='jdbc:mysql://mysql:3306/tk-master?useSSL=false' --server.port=8099
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

# 6. 证书处理
[ ! -f "conf/ssl/server.crt" ] && openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout conf/ssl/server.key -out conf/ssl/server.crt -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

# 7. 前端静态资源 (更新逻辑)
if [ -f "$REPO_DIR/dist.zip" ]; then
    echo -e "${BLUE}>>> 更新前端资源...${NC}"
    # 如果是更新子目录项目，解压到 html/sub-app
    unzip -o $REPO_DIR/dist.zip -d $DEPLOY_DIR/html/
    # 这里根据你的 dist.zip 结构调整移动逻辑
    # cp -r $DEPLOY_DIR/html/dist/* $DEPLOY_DIR/html/sub-app/ 2>/dev/null || true
fi
chmod -R 755 $DEPLOY_DIR/html

# 8. 启动 (使用普通的 restart 而不是全部重置)
echo -e "${YELLOW}>>> 正在重启服务...${NC}"
docker compose up -d

# 9. 处理 SQL 变更 (进阶：如果 MySQL 已运行，手动执行 SQL)
# 这一步会自动对比并运行新的 SQL 变更（如果你的脚本支持幂等）
echo -e "${BLUE}>>> 尝试同步 SQL 变更...${NC}"
for sql in $DEPLOY_DIR/init/*.sql; do
    echo "执行 SQL: $sql"
    docker exec -i app-deploy-mysql-1 mysql -uroot -p"${MYSQL_PWD}" < "$sql" 2>/dev/null || echo "SQL 运行跳过或已存在变更"
done

echo -e "${GREEN}>>> 部署完成！${NC}"