#!/bin/bash

# =================================================================
# TK_learn 私有仓库 + Git LFS + Docker 一键部署脚本
# =================================================================
# 【配置区】
REPO_URL="git@github.com:Dinopell/TK_learn.git"
DEPLOY_DIR="/opt/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"  # 源码存放地
MYSQL_PWD="evnYJdkW02W2U!" 
# =================================================================

set -e
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 0. 环境预检与 sudo 判定
USE_SUDO=""
[ "$EUID" -ne 0 ] && USE_SUDO="sudo"

# 1. 安装基础依赖与 Git LFS
echo -e "${BLUE}>>> 正在安装 Git LFS 与 Docker 环境...${NC}"
# 简单判定 OS 并安装
if command -v apt-get &> /dev/null; then
    $USE_SUDO apt-get update && $USE_SUDO apt-get install -y git git-lfs curl unzip openssl docker.io docker-compose-v2
elif command -v yum &> /dev/null; then
    $USE_SUDO yum install -y git git-lfs curl unzip openssl docker
fi

# 初始化 Git LFS (全局)
git lfs install

# 2. 目录初始化
$USE_SUDO mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}
$USE_SUDO chown -R $USER:$USER $DEPLOY_DIR
cd $DEPLOY_DIR

# 3. 拉取私有仓库代码 (核心更新)
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次部署，正在克隆私有仓库...${NC}"
    # 确保你已经把服务器公钥加到了 GitHub Deploy Keys
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 正在更新仓库代码...${NC}"
    cd $REPO_DIR && git pull origin main
fi

# 确保拉取 LFS 大文件 (处理那 7.7G 的加密包)
echo -e "${BLUE}>>> 正在同步 Git LFS 资源...${NC}"
git lfs pull

# 4. 自动生成自签名 SSL 证书
if [ ! -f "conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 5. 生成 Nginx 配置 (修正了 MIME 和随机文件夹匹配)
echo -e "${BLUE}>>> 生成 Nginx 配置文件...${NC}"
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
        ssl_certificate      /etc/nginx/ssl/server.crt;
        ssl_certificate_key  /etc/nginx/ssl/server.key;

        root /usr/share/nginx/html;

        # 针对 .js 模块的强制 MIME 修正 (解决之前的报错)
        location ~* \.js$ {
            types { application/javascript js; }
            default_type application/javascript;
        }

        # 匹配随机字符串项目文件夹
        location ~ ^/([^/]+)/assets/(.*)$ {
            alias /usr/share/nginx/html/\$1/assets/\$2;
            try_files "" =404;
        }

        location ~ ^/([^/]+)(/.*)?$ {
            try_files \$uri \$uri/ /\$1/index.html /index.html;
        }

        location /api/ {
            proxy_pass http://backend:8080/;
            proxy_set_header Host \$host;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 6. 生成 Docker Compose
cat <<EOF > docker-compose.yml
version: '3.8'
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_PWD}
      MYSQL_DATABASE: my_app_db
    volumes:
      - ./mysql_data:/var/lib/mysql
    restart: always

  redis:
    image: redis:7.0-alpine
    restart: always

  backend:
    image: openjdk:17-jdk-slim
    volumes:
      - ./repo_source/springboot-app.jar:/app.jar
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/my_app_db
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
    command: ["java", "-jar", "/app.jar"]
    restart: always

  frontend:
    image: nginx:stable-alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./html:/usr/share/nginx/html
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/ssl:/etc/nginx/ssl:ro
    restart: always
EOF

# 7. 处理前端资源 (解压项目中的 dist.zip 到随机文件夹)
echo -e "${BLUE}>>> 部署前端静态资源...${NC}"
# 生成随机文件夹名 (类似你提到的项目结构)
DEPLOY_ID="proj_$(date +%s | tail -c 6)"
mkdir -p html/$DEPLOY_ID

if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d html/$DEPLOY_ID/
    # 移动内部文件确保 index.html 在 $DEPLOY_ID 根下
    mv html/$DEPLOY_ID/dist/* html/$DEPLOY_ID/ 2>/dev/null || true
fi

# 8. 启动容器
$USE_SUDO docker compose up -d --build

echo -e "${GREEN}>>> 部署成功！${NC}"
echo -e "${YELLOW}项目随机路径: https://localhost/$DEPLOY_ID/${NC}"