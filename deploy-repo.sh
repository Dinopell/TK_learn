#!/bin/bash

# =================================================================
# TK 子台最终稳定版部署脚本 (HTTPS + Feature 分支)
# 修复内容：
# 1. 自动安装 Docker/Git-LFS 依赖
# 2. 修复 Git 仓库所有权与安全目录问题 (Dubious ownership)
# 3. 强制同步 Git LFS 大文件（解决 Jar 包损坏/缺失问题）
# 4. 适配 HTTPS 克隆与 feature 分支切换
# 5. 后端使用 DB_HOST/DB_PASSWORD（若依 Druid 不读 SPRING_DATASOURCE_*）
# 6. Nginx 修复首页 500（/index.html 内部跳转不再误入动态项目 location）
# 7. 部署后自动 nginx -t 与基础健康检查
# 8. 持久化设备指纹 device.id（重启容器后激活状态不丢失）
# 9. 子台管理端随机入口路径（禁止 IP 根路径直接访问）
# =================================================================

# ========================= 配置区 =========================
# 1. 仓库与分支
REPO_URL="https://github.com/Dinopell/TK_learn.git"
REPO_BRANCH="feature"

# 2. 部署路径
DEPLOY_DIR="/home/ubuntu/app-deploy"
REPO_DIR="$DEPLOY_DIR/repo_source"
PROJECTS_DIR="$DEPLOY_DIR/dynamic-projects"
# 容器内动态项目目录（须与 docker-compose 挂载一致）
CONTAINER_PROJECTS_DIR="/dynamic-projects"

# 3. 数据库密码
MYSQL_PWD="MAmLvxD#uGD1UbSR"

# 4. 总台（主站）对接配置
MASTER_URL="${MASTER_URL:-https://43.165.173.66/prod-api}"
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

# 确保父目录存在
mkdir -p "$DEPLOY_DIR"

# 一次性创建子目录
for sub_dir in html conf/ssl mysql_data redis_data init dynamic-projects backend-data; do
    mkdir -p "$DEPLOY_DIR/$sub_dir"
done
mkdir -p "$DEPLOY_DIR/backend-data/uploadPath" "$DEPLOY_DIR/backend-data/license"
mkdir -p "$DEPLOY_DIR/conf"

# 子台管理端随机入口（首次生成并持久化；REGENERATE_ADMIN_ENTRY=1 可强制换新）
ADMIN_ENTRY_FILE="$DEPLOY_DIR/conf/admin-entry.txt"
if [ "${REGENERATE_ADMIN_ENTRY:-0}" = "1" ]; then
    rm -f "$ADMIN_ENTRY_FILE"
fi
if [ -n "${ADMIN_ENTRY:-}" ]; then
    ADMIN_ENTRY="$(echo "$ADMIN_ENTRY" | tr -cd 'a-zA-Z0-9_-')"
    echo "$ADMIN_ENTRY" > "$ADMIN_ENTRY_FILE"
elif [ -f "$ADMIN_ENTRY_FILE" ]; then
    ADMIN_ENTRY="$(tr -d '[:space:]' < "$ADMIN_ENTRY_FILE")"
else
    ADMIN_ENTRY="$(openssl rand -hex 8)"
    echo "$ADMIN_ENTRY" > "$ADMIN_ENTRY_FILE"
fi
if ! [[ "$ADMIN_ENTRY" =~ ^[a-zA-Z0-9_-]{8,32}$ ]]; then
    echo -e "${RED}>>> 无效的 ADMIN_ENTRY: $ADMIN_ENTRY${NC}"
    exit 1
fi
echo -e "${GREEN}>>> 子台管理端入口路径: /${ADMIN_ENTRY}/${NC}"

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

JAR_FILE="$REPO_DIR/springboot-app.jar"
if [ ! -f "$JAR_FILE" ]; then
    echo -e "${RED}>>> 缺少 $JAR_FILE，请确认仓库已包含该文件且 git lfs pull 成功${NC}"
    exit 1
fi
if ! file "$JAR_FILE" | grep -qE 'Java archive|Zip archive'; then
    echo -e "${RED}>>> springboot-app.jar 不是有效 JAR（可能仍是 LFS 指针），请执行: cd $REPO_DIR && git lfs pull${NC}"
    exit 1
fi

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

cat <<EOF > "$DEPLOY_DIR/conf/nginx.conf"
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
        listen 443 ssl;
        http2 on;
        ssl_certificate /etc/nginx/ssl/server.crt;
        ssl_certificate_key /etc/nginx/ssl/server.key;

        # 禁止通过 IP/ 根路径直接进入子台管理端
        location = / {
            return 404;
        }
        location = /index.html {
            return 404;
        }
        location ^~ /static/ {
            return 404;
        }
        location ^~ /assets/ {
            return 404;
        }

        location ^~ /prod-api/ {
            proxy_pass http://backend:8080/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_read_timeout 60s;
        }

        # 子台管理端：仅允许 /${ADMIN_ENTRY}/ 访问
        location = /${ADMIN_ENTRY} {
            return 301 /${ADMIN_ENTRY}/;
        }
        location ^~ /${ADMIN_ENTRY}/ {
            root /usr/share/nginx/html;
            index index.html;
            try_files \$uri \$uri/ /${ADMIN_ENTRY}/index.html;
        }

        # 用户小页面（dynamic-projects），排除子台入口名
        location ~ ^/(?!${ADMIN_ENTRY}\$)(?!${ADMIN_ENTRY}/)([a-zA-Z0-9_-]+)\$ {
            return 301 \$uri/;
        }
        location ~ ^/(?!${ADMIN_ENTRY}\$)(?!${ADMIN_ENTRY}/)([a-zA-Z0-9_-]+)/ {
            set \$project_name \$1;
            root /dynamic-projects;
            index index.html;
            try_files \$uri \$uri/ /\$project_name/index.html;
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
      - ./dynamic-projects:${CONTAINER_PROJECTS_DIR}
      - ./backend-data:/app/data
    environment:
      - DEPLOY_ROOT=${CONTAINER_PROJECTS_DIR}
      - RUOYI_PROFILE=/app/data/uploadPath
      - RUOYI_FINGERPRINT_FILE=/app/data/license/device.id
      # 若依使用 spring.datasource.druid.master，不读取 SPRING_DATASOURCE_*，须用 DB_* / REDIS_*
      - DB_HOST=mysql
      - DB_PORT=3306
      - DB_NAME=tk-admin
      - DB_USERNAME=root
      - DB_PASSWORD=${MYSQL_PWD}
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - MASTER_URL=${MASTER_URL}
      - MASTER_API_KEY=${MASTER_API_KEY}
      - MASTER_SERVER_URL=${MASTER_SERVER_URL}
      - MASTER_SSL_INSECURE=${MASTER_SSL_INSECURE}
    command:
      - java
      - -Xms512m
      - -Xmx1024m
      - -Dserver.port=8080
      - -Druoyi.profile=/app/data/uploadPath
      - -Druoyi.fingerprintFile=/app/data/license/device.id
      - -jar
      - /app.jar
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
# 6. HTTPS 证书与前端资源（子台解压到随机入口目录）
# =========================================================
echo -e "${YELLOW}>>> 处理证书与前端静态资源...${NC}"

# 将 publicPath=/ 构建产物改为 /${ADMIN_ENTRY}/ 子路径（兼容仓库内预编译 dist.zip）
patch_admin_dist_for_entry() {
    local dir="$1"
    local base="/${ADMIN_ENTRY}"
    local base_slash="${base}/"

    # 1) index.html：最先注入 publicPath（修复懒加载 JS/CSS chunk 仍走 /static/...）
    if [ -f "$dir/index.html" ]; then
        if ! grep -q '__webpack_public_path__' "$dir/index.html"; then
            sed -i "s|<head>|<head><script>__webpack_public_path__='${base_slash}';</script>|" "$dir/index.html"
        fi
        sed -i \
            -e "s|href=/static/|href=${base}/static/|g" \
            -e "s|src=/static/|src=${base}/static/|g" \
            -e "s|href=/assets/|href=${base}/assets/|g" \
            -e "s|src=/assets/|src=${base}/assets/|g" \
            -e "s|\"/static/|\"${base}/static/|g" \
            -e "s|'/static/|'${base}/static/|g" \
            "$dir/index.html"
    fi

    # 2) 已编译 CSS 文件内的 url(/static/...)
    find "$dir" -type f -name '*.css' -print0 | while IFS= read -r -d '' f; do
        sed -i \
            -e "s|url(/static/|url(${base}/static/|g" \
            -e "s|url(/assets/|url(${base}/assets/|g" \
            -e "s|\"/static/|\"${base}/static/|g" \
            -e "s|'/static/|'${base}/static/|g" \
            "$f"
    done

    # 3) JS：webpack publicPath + 硬编码的 /static/js/、/static/css/（CSS chunk 懒加载同因）
    find "$dir" -type f -name '*.js' -print0 | while IFS= read -r -d '' f; do
        sed -i \
            -e "s|__webpack_require__\\.p=\"/\"|__webpack_require__.p=\"${base_slash}\"|g" \
            -e "s|__webpack_require__\\.p='/'|__webpack_require__.p='${base_slash}'|g" \
            -e "s|\\.p=\"/\"|.p=\"${base_slash}\"|g" \
            -e "s|\\.p='/'|.p='${base_slash}'|g" \
            -e "s|\\.p=\"/\",|.p=\"${base_slash}\",|g" \
            -e "s|p:\"/\"|p:\"${base_slash}\"|g" \
            -e "s|p:'/'|p:'${base_slash}'|g" \
            -e "s|publicPath:\"/\"|publicPath:\"${base_slash}\"|g" \
            -e "s|publicPath:'/'|publicPath:'${base_slash}'|g" \
            -e "s|\"/static/|\"${base}/static/|g" \
            -e "s|'/static/|'${base}/static/|g" \
            -e "s|+\"/static/|+\"${base}/static/|g" \
            -e "s|+'/static/'|+'${base}/static/'|g" \
            -e "s|mode:\"history\",scrollBehavior|mode:\"history\",base:\"${base_slash}\",scrollBehavior|g" \
            -e "s|mode:'history',scrollBehavior|mode:'history',base:'${base_slash}',scrollBehavior|g" \
            "$f" || true
    done

    # 4) 校验：不应再出现根路径 /static/js|css（排除已带入口前缀）
    if grep -rq '"/static/js/' "$dir" 2>/dev/null || grep -rq '"/static/css/' "$dir" 2>/dev/null; then
        echo -e "${YELLOW}>>> 警告: 仍有文件引用根路径 /static/，建议按入口路径重新打包 dist.zip${NC}"
        grep -rl '"/static/js/' "$dir" 2>/dev/null | head -3 || true
        grep -rl '"/static/css/' "$dir" 2>/dev/null | head -3 || true
    fi
}

if [ ! -f "$DEPLOY_DIR/conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout $DEPLOY_DIR/conf/ssl/server.key \
    -out $DEPLOY_DIR/conf/ssl/server.crt \
    -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

ADMIN_HTML_DIR="$DEPLOY_DIR/html/$ADMIN_ENTRY"
rm -rf "$ADMIN_HTML_DIR"
mkdir -p "$ADMIN_HTML_DIR"

if [ -f "$REPO_DIR/dist.zip" ]; then
    TMP_UNZIP="$(mktemp -d)"
    unzip -o -q "$REPO_DIR/dist.zip" -d "$TMP_UNZIP"
    if [ -d "$TMP_UNZIP/dist" ]; then
        cp -a "$TMP_UNZIP/dist/." "$ADMIN_HTML_DIR/"
    else
        cp -a "$TMP_UNZIP/." "$ADMIN_HTML_DIR/"
    fi
    rm -rf "$TMP_UNZIP"
    if [ ! -f "$ADMIN_HTML_DIR/index.html" ]; then
        echo -e "${RED}>>> dist.zip 解压后未找到 index.html，请检查前端打包${NC}"
        exit 1
    fi
    patch_admin_dist_for_entry "$ADMIN_HTML_DIR"
    # 清理历史根目录泄露（旧版直接解压到 html/）
    find "$DEPLOY_DIR/html" -mindepth 1 -maxdepth 1 ! -name "$ADMIN_ENTRY" -exec rm -rf {} + 2>/dev/null || true
    rm -f "$DEPLOY_DIR/html/index.html" 2>/dev/null || true
    echo -e "${GREEN}>>> 子台前端已部署到 html/${ADMIN_ENTRY}/${NC}"
else
    echo -e "${YELLOW}>>> 警告: 未找到 $REPO_DIR/dist.zip${NC}"
    if [ ! -f "$ADMIN_HTML_DIR/index.html" ]; then
        echo -e "${RED}>>> html/${ADMIN_ENTRY}/index.html 不存在，页面将无法正常访问${NC}"
        exit 1
    fi
    patch_admin_dist_for_entry "$ADMIN_HTML_DIR"
fi

# =========================================================
# 7. 启动服务与数据库导入
# =========================================================
echo -e "${YELLOW}>>> 修复权限并启动服务...${NC}"

chown -R ubuntu:ubuntu $DEPLOY_DIR
chmod -R 777 $DEPLOY_DIR/redis_data
chmod -R 755 $DEPLOY_DIR/html
chmod -R 755 $PROJECTS_DIR
chmod -R 755 "$DEPLOY_DIR/backend-data"

cd $DEPLOY_DIR
docker compose down || true
docker compose up -d --force-recreate

echo -e "${YELLOW}>>> 校验 Nginx 配置...${NC}"
sleep 3
docker exec app-deploy-frontend-1 nginx -t

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
# 8. 健康检查
# =========================================================
echo -e "${YELLOW}>>> 健康检查...${NC}"

ROOT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1/ || echo "000")
ADMIN_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1/${ADMIN_ENTRY}/" || echo "000")
if [ "$ROOT_CODE" = "404" ]; then
    echo -e "${GREEN}>>> 根路径已禁止访问 (404)${NC}"
else
    echo -e "${YELLOW}>>> 根路径返回 $ROOT_CODE（期望 404）${NC}"
fi
if [ "$ADMIN_CODE" = "200" ]; then
    echo -e "${GREEN}>>> 子台入口 /${ADMIN_ENTRY}/ 返回 200 OK${NC}"
else
    echo -e "${YELLOW}>>> 子台入口返回 $ADMIN_CODE（若刚启动可稍等: curl -k -I https://127.0.0.1/${ADMIN_ENTRY}/）${NC}"
fi

if docker logs app-deploy-backend-1 2>&1 | tail -50 | grep -q "若依启动成功"; then
    echo -e "${GREEN}>>> 后端若依已启动${NC}"
else
    echo -e "${YELLOW}>>> 后端可能仍在启动，查看日志: docker logs -f app-deploy-backend-1${NC}"
fi

if [ -f "$DEPLOY_DIR/backend-data/license/device.id" ]; then
    echo -e "${GREEN}>>> 设备指纹已持久化: backend-data/license/device.id${NC}"
else
    echo -e "${YELLOW}>>> 首次部署尚未生成 device.id，激活后将写入 backend-data/license/${NC}"
fi

# =========================================================
# 9. 完成
# =========================================================
echo -e "${GREEN}"
echo "===================================================="
echo "TK 子台部署完成！"
echo "分支: $REPO_BRANCH"
echo "总台对接: $MASTER_URL"
echo ""
echo "子台管理端（请妥善保存，勿公开根路径）:"
echo "  https://你的服务器IP/${ADMIN_ENTRY}/"
echo "  入口记录: $ADMIN_ENTRY_FILE"
echo "动态项目: https://你的服务器IP/项目名/"
echo ""
echo "更换随机入口: REGENERATE_ADMIN_ENTRY=1 bash deploy-repo.sh"
echo ""
echo "激活指纹（重启后须保留）:"
echo "  $DEPLOY_DIR/backend-data/license/device.id"
echo ""
echo "常用命令:"
echo "  docker ps"
echo "  docker logs -f app-deploy-backend-1"
echo "  docker logs -f app-deploy-frontend-1"
echo "===================================================="
echo -e "${NC}"
docker ps