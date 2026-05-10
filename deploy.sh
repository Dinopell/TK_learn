#!/bin/bash

# =================================================================
# SpringBoot + Vue + MySQL + Redis 一键 HTTPS 安全部署脚本
# =================================================================
# 【配置区】
BACKEND_URL="http://your-server.com/app.jar"
FRONTEND_URL="http://your-server.com/dist.zip"
DEPLOY_DIR="/opt/app-deploy"
MYSQL_PWD="evnYJdkW02W2U!" 
# =================================================================

set -e
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 0. 环境预检
if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else exit 1; fi
USE_SUDO=""
[ "$EUID" -ne 0 ] && USE_SUDO="sudo"

# 1. 安装依赖 (增加 openssl 用于生成证书)
echo -e "${BLUE}>>> 正在安装依赖环境...${NC}"
case "$OS" in
    ubuntu|debian) $USE_SUDO apt-get update && $USE_SUDO apt-get install -y curl unzip openssl docker.io docker-compose-v2 ;;
    centos|rhel|rocky|alios) 
        $USE_SUDO yum install -y curl unzip openssl docker
        $USE_SUDO curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/bin/docker-compose
        $USE_SUDO chmod +x /usr/bin/docker-compose
        ;;
esac
$USE_SUDO systemctl start docker && $USE_SUDO systemctl enable docker

# 2. 创建目录
# 【注意】增加了 conf/ssl 目录用于存放证书
$USE_SUDO mkdir -p $DEPLOY_DIR/{html,temp,conf/ssl,mysql_data,redis_data,init}
$USE_SUDO chown -R $USER:$USER $DEPLOY_DIR
cd $DEPLOY_DIR

# 3. 【新增】自动生成自签名 SSL 证书
# 如果你已经有正式证书，直接把文件命名为 server.crt/server.key 放到 conf/ssl 即可
if [ ! -f "conf/ssl/server.crt" ]; then
    echo -e "${BLUE}>>> 正在生成自签名 SSL 证书...${NC}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout conf/ssl/server.key -out conf/ssl/server.crt \
        -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 4. 生成 Nginx 配置
echo -e "${BLUE}>>> 生成 Nginx HTTPS 配置文件...${NC}"
cat <<EOF > conf/nginx.conf
user  nginx;
worker_processes  auto;
events { worker_connections 1024; }

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    # HTTP 强制跳转 HTTPS
    server {
        listen 80;
        server_name _;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 443 ssl;
        server_name _;
        charset utf-8;

        # 【注意】证书路径对应容器内的映射路径
        ssl_certificate      /etc/nginx/ssl/server.crt;
        ssl_certificate_key  /etc/nginx/ssl/server.key;

        root /usr/share/nginx/html;
        index index.html index.htm;

        # 保持你的特殊目录匹配逻辑
        location ~ ^/([^/]+)$ { rewrite ^/(.*)$ /\$1/ permanent; }

        location ~ ^/([^/]+)/$ {
            root /usr/share/nginx/html;
            try_files /\$1/index.html /\$1.html /index.html;
        }

        location ~ ^/([^/]+)/assets/(.*)$ {
            root /usr/share/nginx/html;
            try_files /\$1/assets/\$2 =404;
        }

        location /api/ {
            proxy_pass http://backend:8080/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 5. 生成 Docker Compose
# 【注意】前端容器增加了 443 端口映射和 ssl 目录挂载
cat <<EOF > docker-compose.yml
version: '3.8'
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_PWD}
      MYSQL_DATABASE: my_app_db
      TZ: Asia/Shanghai
    volumes:
      - ./mysql_data:/var/lib/mysql
      - ./init:/docker-entrypoint-initdb.d
    restart: always

  redis:
    image: redis:7.0-alpine
    environment: [TZ=Asia/Shanghai]
    volumes: [./redis_data:/data]
    restart: always

  backend:
    image: openjdk:17-jdk-slim
    depends_on: [mysql, redis]
    ports: ["8080:8080"]
    volumes: ["./backend.jar:/app.jar"]
    environment:
      - SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/my_app_db?useSSL=false
      - SPRING_DATASOURCE_PASSWORD=${MYSQL_PWD}
      - SPRING_REDIS_HOST=redis
      - TZ=Asia/Shanghai
    command: ["java", "-Xmx512m", "-jar", "/app.jar"]
    restart: always

  frontend:
    image: nginx:stable-alpine
    ports:
      - "80:80"
      - "443:443" # ✅ 开启 HTTPS 端口
    environment: [TZ=Asia/Shanghai]
    volumes:
      - ./html:/usr/share/nginx/html
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/ssl:/etc/nginx/ssl:ro # ✅ 挂载证书目录
    depends_on: [backend]
    restart: always
EOF

# 6. 下载处理资源
curl -L $BACKEND_URL -o backend.jar
curl -L $FRONTEND_URL -o temp/dist.zip
unzip -o temp/dist.zip -d temp/
DIST_PATH=\$(find temp -name "index.html" | head -n 1 | xargs dirname)
cp -r "\$DIST_PATH"/* html/
chmod -R 755 html/
rm -rf temp

# 7. 启动并配置防火墙
$USE_SUDO docker compose up -d
echo -e "${BLUE}>>> 配置防火墙开放 80, 443, 8080...${NC}"
if command -v ufw &> /dev/null; then
    $USE_SUDO ufw allow 80,443,8080/tcp && $USE_SUDO ufw --force enable
elif command -v firewall-cmd &> /dev/null; then
    $USE_SUDO firewall-cmd --zone=public --add-port=80/tcp --add-port=443/tcp --add-port=8080/tcp --permanent
    $USE_SUDO firewall-cmd --reload
fi

echo -e "${GREEN}部署完成！HTTPS 已启用。${NC}"
echo -e "${YELLOW}由于使用的是自签名证书，浏览器访问时请点击“高级”->“继续访问”。${NC}"