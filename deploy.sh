#!/bin/bash

# =================================================================
# TK_learn 私有仓库 + Git LFS + Docker 兼容版部署脚本
# =================================================================
# 【配置区】
REPO_URL="git@github.com:Dinopell/TK_learn.git"
DEPLOY_DIR="/opt/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"
MYSQL_PWD="evnYJdkW02W2U!" 
# =================================================================

set -e
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- 核心更新：权限预检逻辑 ---
USE_SUDO=""
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}当前以非 root 账户 ($USER) 运行，将尝试使用 sudo 执行特权操作...${NC}"
    USE_SUDO="sudo"
    # 检查是否有 sudo 权限
    if ! $USE_SUDO -v &> /dev/null; then
        echo -e "${BLUE}错误：当前用户没有 sudo 权限，无法执行部署。${NC}"
        exit 1
    fi
fi

# 1. 安装基础依赖
echo -e "${BLUE}>>> 正在安装依赖环境...${NC}"
if command -v apt-get &> /dev/null; then
    $USE_SUDO apt-get update && $USE_SUDO apt-get install -y git git-lfs curl unzip openssl docker.io docker-compose-v2
elif command -v yum &> /dev/null; then
    $USE_SUDO yum install -y git git-lfs curl unzip openssl docker
    $USE_SUDO systemctl start docker && $USE_SUDO systemctl enable docker
fi

# 初始化 Git LFS
git lfs install

# 2. 目录初始化与权限分配
# 关键：先用 sudo 创建 /opt 下的目录，然后把所有权给当前用户
echo -e "${BLUE}>>> 初始化部署目录并分配权限...${NC}"
$USE_SUDO mkdir -p $DEPLOY_DIR/{html,conf/ssl,mysql_data,redis_data,init}
$USE_SUDO chown -R $USER:$USER $DEPLOY_DIR

cd $DEPLOY_DIR

# 3. 拉取私有仓库代码
if [ ! -d "$REPO_DIR" ]; then
    echo -e "${BLUE}>>> 首次部署，克隆私有仓库...${NC}"
    git clone $REPO_URL $REPO_DIR
else
    echo -e "${BLUE}>>> 正在更新仓库代码...${NC}"
    cd $REPO_DIR && git pull origin main
fi

# 确保拉取 LFS 大文件
cd $REPO_DIR && git lfs pull
cd $DEPLOY_DIR

# 4. 自动生成自签名 SSL 证书
if [ ! -f "conf/ssl/server.crt" ]; then
    echo -e "${BLUE}>>> 生成自签名证书...${NC}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 5. 生成 Nginx 配置 (修正 MIME)
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
        ssl_certificate      /etc/nginx/ssl/server.crt;
        ssl_certificate_key  /etc/nginx/ssl/server.key;

        root /usr/share/nginx/html;

        # 修正 MIME 类型
        location ~* \.js$ {
            types { application/javascript js; }
            default_type application/javascript;
        }

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

# 7. 处理前端资源
echo -e "${BLUE}>>> 处理前端静态资源...${NC}"
DEPLOY_ID="proj_$(date +%s | tail -c 6)"
mkdir -p html/$DEPLOY_ID

if [ -f "$REPO_DIR/dist.zip" ]; then
    unzip -o $REPO_DIR/dist.zip -d html/$DEPLOY_ID/
    # 兼容处理：将 dist 目录下的文件移出到随机 ID 根目录
    mv html/$DEPLOY_ID/dist/* html/$DEPLOY_ID/ 2>/dev/null || true
fi

# 8. 启动容器
# 注意：如果当前用户不在 docker 组，docker 命令也需要 sudo
echo -e "${BLUE}>>> 正在启动 Docker 容器...${NC}"
$USE_SUDO docker compose up -d --build

echo -e "${GREEN}>>> 部署成功！项目路径: https://服务器IP/$DEPLOY_ID/${NC}"