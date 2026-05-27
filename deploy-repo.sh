#!/bin/bash

# =================================================================
# TK 子台最终稳定版部署脚本 (子台 HTTP:80 + 小页面 HTTPS:443 + Feature 分支)
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
# 10. /static、/assets 回退映射到子台目录（修复 publicPath=/ 时 CSS/JS chunk 404）
# 11. 小页面持久化在宿主机 dynamic-projects（bind mount，docker restart 不丢失）
# 12. SQL：sql/*.sql 仅新库 init（已部署且存在 sys_user 则跳过）；sql/migrations/*.sql 按 schema_migration 增量执行
# 13. 默认静默部署：终端仅显示错误与完成摘要；详细日志见 deploy.log（DEPLOY_VERBOSE=1 可全开）
# 14. 总台地址仅通过 deploy/master.endpoint.pkg（RSA 签名）下发，后端验签后注入（禁止 MASTER_URL 等明文环境变量）
# 15. 增量 migration：校验库表是否生效；登记与实物不一致时自动补跑；部署结束在终端打印 SQL 摘要
#     FORCE_MIGRATIONS=1 可强制重跑全部 migration（须为幂等 SQL，见 sql/migrations/）
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

# 4. 总台对接：仅允许 RSA 签名包 MASTER_ENDPOINT_PKG（禁止部署用户设置 MASTER_URL 等明文变量）
DEPLOY_SCRIPT_VER="20260527-migration-auto-repair"
FORCE_MIGRATIONS="${FORCE_MIGRATIONS:-0}"
# =========================================================

set -e

# 宿主机若单独装了 Nginx 且配置了 return 301 https，会抢在 Docker 前把 HTTP 变 HTTPS
fix_host_nginx_https_redirect() {
    if ! command -v nginx &>/dev/null; then
        return 0
    fi
    if ! sudo grep -rq 'return 301 https' /etc/nginx/ 2>/dev/null; then
        return 0
    fi
    deploy_msg "${YELLOW}>>> 宿主机 Nginx 含「return 301 https」（常见原因：HTTP 自动变 HTTPS）${NC}"
    sudo grep -rn 'return 301 https' /etc/nginx/ 2>/dev/null | head -5 || true
    if [ "${FIX_HOST_NGINX:-0}" != "1" ]; then
        deploy_err "${RED}>>> 请带环境变量重新执行: FIX_HOST_NGINX=1 bash deploy-repo.sh${NC}"
        exit 1
    fi
    deploy_msg "${BLUE}>>> FIX_HOST_NGINX=1：注释宿主机 HTTPS 强制跳转并 reload...${NC}"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        sudo cp -a "$f" "${f}.bak.http-deploy"
        sudo sed -i 's/^\([[:space:]]*return 301 https\)/# \1 # disabled by deploy-repo.sh/' "$f"
    done < <(sudo grep -rl 'return 301 https' /etc/nginx/ 2>/dev/null || true)
    sudo nginx -t
    sudo systemctl reload nginx 2>/dev/null || sudo nginx -s reload
    deploy_msg "${GREEN}>>> 宿主机 Nginx 已 reload${NC}"
}

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# 默认静默：过程写入 deploy.log；需调试时 DEPLOY_VERBOSE=1 bash deploy-repo.sh
DEPLOY_VERBOSE="${DEPLOY_VERBOSE:-0}"
DEPLOY_LOG="${DEPLOY_LOG:-$DEPLOY_DIR/deploy.log}"

deploy_log() {
    mkdir -p "$(dirname "$DEPLOY_LOG")" 2>/dev/null || true
    echo -e "$@" >> "$DEPLOY_LOG" 2>/dev/null || true
}

deploy_msg() {
    if [ "$DEPLOY_VERBOSE" = "1" ]; then
        echo -e "$@"
    else
        deploy_log "$@"
    fi
}

deploy_err() {
    echo -e "$@" >&2
}

deploy_user() {
    echo -e "$@"
}

# MySQL 辅助（第 7 步容器启动后调用）
mysql_cli() {
    docker exec -i app-deploy-mysql-1 \
        mysql -uroot -p"${MYSQL_PWD}" --default-character-set=utf8mb4 "$@"
}

mysql_apply_sql_file() {
    local db="$1"
    local file="$2"
    docker exec -i app-deploy-mysql-1 \
        mysql -uroot -p"${MYSQL_PWD}" --default-character-set=utf8mb4 "$db" < "$file"
}

tk_admin_is_initialized() {
    local cnt
    cnt=$(mysql_cli -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='tk-admin' AND table_name='sys_user';" \
        2>/dev/null || echo "0")
    [[ "${cnt:-0}" -ge 1 ]]
}

ensure_schema_migration_table() {
    mysql_cli -e "
CREATE DATABASE IF NOT EXISTS \`tk-admin\` DEFAULT CHARACTER SET utf8mb4;
USE \`tk-admin\`;
CREATE TABLE IF NOT EXISTS \`schema_migration\` (
  \`version\` varchar(255) NOT NULL,
  \`applied_at\` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (\`version\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='部署 SQL 增量版本';
"
}

migration_is_applied() {
    local version="$1"
    local esc="${version//\'/\'\'}"
    local cnt
    cnt=$(mysql_cli -N -e \
        "SELECT COUNT(*) FROM \`tk-admin\`.\`schema_migration\` WHERE \`version\`='${esc}';" \
        2>/dev/null || echo "0")
    [[ "${cnt:-0}" -ge 1 ]]
}

record_migration_applied() {
    local version="$1"
    local esc="${version//\'/\'\'}"
    mysql_cli -e \
        "INSERT IGNORE INTO \`tk-admin\`.\`schema_migration\` (\`version\`) VALUES ('${esc}');"
}

clear_migration_record() {
    local version="$1"
    local esc="${version//\'/\'\'}"
    mysql_cli -e \
        "DELETE FROM \`tk-admin\`.\`schema_migration\` WHERE \`version\`='${esc}';"
}

mysql_column_exists() {
    local db="$1"
    local table="$2"
    local column="$3"
    local esc_db="${db//\'/\'\'}"
    local esc_table="${table//\'/\'\'}"
    local esc_column="${column//\'/\'\'}"
    local cnt
    cnt=$(mysql_cli -N -e \
        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE table_schema='${esc_db}' AND table_name='${esc_table}' AND column_name='${esc_column}';" \
        2>/dev/null || echo "0")
    [[ "${cnt:-0}" -ge 1 ]]
}

migration_has_effect_verifier() {
    case "$1" in
        001_add_entry_join_mode_column.sql) return 0 ;;
        *) return 1 ;;
    esac
}

migration_effect_ok() {
    case "$1" in
        001_add_entry_join_mode_column.sql)
            mysql_column_exists tk-admin user_assets entry_join_mode
            ;;
        *)
            return 0
            ;;
    esac
}

# 返回 0 表示需要执行 migration；若因「已登记未生效」补跑，置 _last_mig_repair=1
migration_should_run() {
    local base="$1"
    _last_mig_repair=0
    if [ "$FORCE_MIGRATIONS" = "1" ]; then
        return 0
    fi
    if ! migration_is_applied "$base"; then
        return 0
    fi
    if ! migration_has_effect_verifier "$base"; then
        return 1
    fi
    if migration_effect_ok "$base"; then
        return 1
    fi
    deploy_user "${YELLOW}>>> [migrate] ${base} 已在 schema_migration 登记但库表未生效，自动补跑${NC}"
    clear_migration_record "$base"
    _last_mig_repair=1
    return 0
}

mysql_wait_ready() {
    local i max=60
    for i in $(seq 1 "$max"); do
        if docker exec app-deploy-mysql-1 \
            mysqladmin ping -h localhost -uroot -p"${MYSQL_PWD}" --silent 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    deploy_err "${RED}>>> MySQL 在 $((max * 2)) 秒内未就绪，请检查容器日志${NC}"
    exit 1
}

run_quiet() {
    if [ "$DEPLOY_VERBOSE" = "1" ]; then
        "$@"
    elif ! "$@" >>"$DEPLOY_LOG" 2>&1; then
        deploy_err "${RED}>>> 命令执行失败: $*（详见 $DEPLOY_LOG）${NC}"
        return 1
    fi
}

deploy_msg "${YELLOW}>>> 开始部署 TK 子台系统 [脚本: $DEPLOY_SCRIPT_VER] [分支: $REPO_BRANCH]...${NC}"

# =========================================================
# 0. 环境依赖检查与系统优化
# =========================================================
deploy_msg "${YELLOW}>>> 检查环境依赖...${NC}"

# 自动安装 Docker
if ! command -v docker &> /dev/null; then
    deploy_msg "${BLUE}>>> 正在自动安装 Docker...${NC}"
    curl -fsSL https://get.docker.com | bash -s docker
    sudo systemctl start docker
    sudo systemctl enable docker
fi

# 自动安装 Git LFS
if ! command -v git-lfs &> /dev/null; then
    deploy_msg "${BLUE}>>> 正在安装 git-lfs...${NC}"
    sudo apt-get update && sudo apt-get install git-lfs -y
    git lfs install
fi

# 系统内核优化
sudo sysctl vm.overcommit_memory=1 || true

# =========================================================
# 1. 初始化目录
# =========================================================
deploy_msg "${YELLOW}>>> 初始化目录...${NC}"

# 确保父目录存在
mkdir -p "$DEPLOY_DIR"

# 一次性创建子目录
for sub_dir in html conf/ssl mysql_data redis_data init migrations dynamic-projects backend-data certbot-www letsencrypt; do
    mkdir -p "$DEPLOY_DIR/$sub_dir"
done
mkdir -p "$DEPLOY_DIR/backend-data/uploadPath" "$DEPLOY_DIR/backend-data/license"
mkdir -p "$PROJECTS_DIR"

# letsencrypt 由 certbot 管理；勿预建 live/tk-substation（会与 certbot 冲突）
# 标记持久化目录（部署脚本不会清空 dynamic-projects）
touch "$PROJECTS_DIR/.persistent_on_host"
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
    deploy_err "${RED}>>> 无效的 ADMIN_ENTRY: $ADMIN_ENTRY${NC}"
    exit 1
fi
deploy_msg "${GREEN}>>> 子台管理端入口路径: /${ADMIN_ENTRY}/${NC}"

# =========================================================
# 2. 拉取代码 (HTTPS + Branch 逻辑)
# =========================================================
deploy_msg "${YELLOW}>>> 准备源码仓库...${NC}"

# 修复 Git 目录权限问题
if [ -d "$REPO_DIR" ]; then
    deploy_msg "${BLUE}>>> 修复存储库所有权并标记为安全目录...${NC}"
    sudo chown -R $(whoami):$(whoami) "$REPO_DIR"
    git config --global --add safe.directory "$REPO_DIR"
fi

# 拉取或更新
if [ ! -d "$REPO_DIR" ]; then
    deploy_msg "${BLUE}>>> 首次克隆分支: $REPO_BRANCH ...${NC}"
    git clone -b $REPO_BRANCH $REPO_URL $REPO_DIR
else
    deploy_msg "${BLUE}>>> 强制同步分支: $REPO_BRANCH ...${NC}"
    cd $REPO_DIR
    git fetch --all
    # 强制切换并重置到指定的分支
    git checkout $REPO_BRANCH || git checkout -b $REPO_BRANCH origin/$REPO_BRANCH
    git reset --hard origin/$REPO_BRANCH
fi

# 核心修正：强制同步 Git LFS 大文件（防止 JAR 文件只是文本指针）
deploy_msg "${BLUE}>>> 正在同步 Git LFS 大文件...${NC}"
cd $REPO_DIR
git lfs install --local
git lfs pull
cd $DEPLOY_DIR

JAR_FILE="$REPO_DIR/springboot-app.jar"
if [ ! -f "$JAR_FILE" ]; then
    deploy_err "${RED}>>> 缺少 $JAR_FILE，请确认仓库已包含该文件且 git lfs pull 成功${NC}"
    exit 1
fi
if ! file "$JAR_FILE" | grep -qE 'Java archive|Zip archive'; then
    deploy_err "${RED}>>> springboot-app.jar 不是有效 JAR（可能仍是 LFS 指针），请执行: cd $REPO_DIR && git lfs pull${NC}"
    exit 1
fi

# 总台对接：禁止部署用户通过环境变量指定明文总台；仅使用仓库内密文包
for _forbidden in MASTER_URL MASTER_API_KEY MASTER_SERVER_URL MASTER_SSL_INSECURE; do
    if [ -n "${!_forbidden:-}" ]; then
        deploy_err "${RED}>>> 禁止设置 $_forbidden，总台地址由运维加密包统一下发${NC}"
        exit 1
    fi
done
MASTER_PKG_FILE="$REPO_DIR/deploy/master.endpoint.pkg"
if [ ! -f "$MASTER_PKG_FILE" ]; then
    deploy_err "${RED}>>> 缺少总台签名包 $MASTER_PKG_FILE，请使用最新 feature 分支或联系运维${NC}"
    exit 1
fi
MASTER_ENDPOINT_PKG="$(tr -d '\n\r\t ' < "$MASTER_PKG_FILE")"
case "$MASTER_ENDPOINT_PKG" in
    v2.*.*) ;;
    *)
        deploy_err "${RED}>>> 总台签名包格式无效（期望 v2.<payload>.<signature>）: $MASTER_PKG_FILE${NC}"
        exit 1
        ;;
esac
if [ -z "$MASTER_ENDPOINT_PKG" ]; then
    deploy_err "${RED}>>> 总台签名包为空: $MASTER_PKG_FILE${NC}"
    exit 1
fi
deploy_msg "${GREEN}>>> 已加载总台 RSA 签名配置包${NC}"

# =========================================================
# 3. SQL 脚本 staging（init / migrations）
# =========================================================
deploy_msg "${YELLOW}>>> 准备 SQL 脚本（init / migrations）...${NC}"

rm -f "$DEPLOY_DIR/init"/*.sql "$DEPLOY_DIR/migrations"/*.sql 2>/dev/null || true
mkdir -p "$DEPLOY_DIR/init" "$DEPLOY_DIR/migrations"

if [ -d "$REPO_DIR/sql" ]; then
    for f in "$REPO_DIR/sql"/*.sql; do
        [ -f "$f" ] || continue
        cp "$f" "$DEPLOY_DIR/init/"
    done
    if [ -d "$REPO_DIR/sql/migrations" ]; then
        cp "$REPO_DIR/sql/migrations"/*.sql "$DEPLOY_DIR/migrations/" 2>/dev/null || true
    fi
elif [ -d "$REPO_DIR/BS/sql" ]; then
    for f in "$REPO_DIR/BS/sql"/*.sql; do
        [ -f "$f" ] || continue
        cp "$f" "$DEPLOY_DIR/init/"
    done
    if [ -d "$REPO_DIR/BS/sql/migrations" ]; then
        cp "$REPO_DIR/BS/sql/migrations"/*.sql "$DEPLOY_DIR/migrations/" 2>/dev/null || true
    fi
fi

INIT_SQL_FILE="$DEPLOY_DIR/init/00_create_databases.sql"
echo "CREATE DATABASE IF NOT EXISTS \`tk-admin\` DEFAULT CHARACTER SET utf8mb4;" > "$INIT_SQL_FILE"

for f in "$DEPLOY_DIR/init"/*.sql; do
    [ -f "$f" ] || continue
    if [[ "$(basename "$f")" != "00_create_databases.sql" ]]; then
        if ! grep -iq "USE " "$f"; then
            sed -i "1i USE \`tk-admin\`;" "$f"
        fi
    fi
done

for f in "$DEPLOY_DIR/migrations"/*.sql; do
    [ -f "$f" ] || continue
    if ! grep -iq "USE " "$f"; then
        sed -i "1i USE \`tk-admin\`;" "$f"
    fi
done

REPO_MIG_DIR=""
if [ -d "$REPO_DIR/sql/migrations" ]; then
    REPO_MIG_DIR="$REPO_DIR/sql/migrations"
elif [ -d "$REPO_DIR/BS/sql/migrations" ]; then
    REPO_MIG_DIR="$REPO_DIR/BS/sql/migrations"
fi
if [ -n "$REPO_MIG_DIR" ] && compgen -G "$REPO_MIG_DIR"/*.sql >/dev/null; then
    if ! compgen -G "$DEPLOY_DIR/migrations"/*.sql >/dev/null; then
        deploy_err "${RED}>>> 仓库含 sql/migrations 但复制到 $DEPLOY_DIR/migrations 失败，请检查磁盘权限${NC}"
        exit 1
    fi
fi

# =========================================================
# 4. 生成 Nginx 配置
# =========================================================
deploy_msg "${YELLOW}>>> 生成 Nginx 配置...${NC}"

# SSL：须证书文件真实存在（仅有 renewal 配置但无 live 文件会导致 Nginx 无法启动）
NGINX_SSL_CERT="/etc/nginx/ssl/server.crt"
NGINX_SSL_KEY="/etc/nginx/ssl/server.key"
if [ -f "$DEPLOY_DIR/letsencrypt/live/tk-substation/fullchain.pem" ] \
    && [ -f "$DEPLOY_DIR/letsencrypt/live/tk-substation/privkey.pem" ]; then
    NGINX_SSL_CERT="/etc/letsencrypt/live/tk-substation/fullchain.pem"
    NGINX_SSL_KEY="/etc/letsencrypt/live/tk-substation/privkey.pem"
fi

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

    # SockJS / STOMP WebSocket 升级（缺此项时 ws://.../websocket 失败，仅能 xhr 轮询）
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    # 由子台后端 AssetRouteNginxService 写入（map/locations：域名+随机后缀 → /dynamic-projects/{后缀}）
    include /etc/nginx/nginx-dynamic/asset-routes-map.conf;

    # ---------- 80：子台管理端 HTTP（勿对小页面整站跳 HTTPS，避免管理端被带上）----------
    server {
        listen 80;

        # Let's Encrypt HTTP-01 验证
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        location = / {
            return 404;
        }
        location = /index.html {
            return 404;
        }

        location ^~ /static/ {
            alias /usr/share/nginx/html/${ADMIN_ENTRY}/static/;
            expires 7d;
            add_header Cache-Control "public";
        }
        location ^~ /assets/ {
            alias /usr/share/nginx/html/${ADMIN_ENTRY}/assets/;
            expires 7d;
            add_header Cache-Control "public";
        }

        location ^~ /prod-api/ {
            proxy_pass http://backend:8080/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_buffering off;
            proxy_connect_timeout 60s;
            proxy_send_timeout 3600s;
            proxy_read_timeout 3600s;
        }

        location = /index {
            return 302 /${ADMIN_ENTRY}/index;
        }
        location = /login {
            return 302 /${ADMIN_ENTRY}/login;
        }

        location = /${ADMIN_ENTRY} {
            return 301 /${ADMIN_ENTRY}/;
        }
        location ^~ /${ADMIN_ENTRY}/ {
            root /usr/share/nginx/html;
            index index.html;
            try_files \$uri \$uri/ /${ADMIN_ENTRY}/index.html;
        }

        # 小页面仅 HTTPS：HTTP 访问 /项目名/ 时跳到 443
        location ~ ^/(?!${ADMIN_ENTRY}\$)(?!${ADMIN_ENTRY}/)([a-zA-Z0-9_-]+)\$ {
            return 301 https://\$host\$uri/;
        }
        location ~ ^/(?!${ADMIN_ENTRY}\$)(?!${ADMIN_ENTRY}/)([a-zA-Z0-9_-]+)(/.*)?\$ {
            return 301 https://\$host\$request_uri;
        }
    }

    # ---------- 443：用户小页面 HTTPS + 同源 /prod-api（SockJS/WSS）----------
    server {
        listen 443 ssl;
        http2 on;
        ssl_certificate ${NGINX_SSL_CERT};
        ssl_certificate_key ${NGINX_SSL_KEY};

        # Let's Encrypt HTTP-01 验证（HTTPS 也保留，防止验证器重定向）
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        # 路径模式（域名/后缀，由后端生成 asset-routes-locations.conf）
        include /etc/nginx/nginx-dynamic/asset-routes-locations.conf;

        # 兜底：IP 或未匹配域名时，/dynamic-projects/{随机后缀}/（用 root+try_files，避免 alias 导致配置失败）
        location ~ ^/(?!${ADMIN_ENTRY}\$)(?!${ADMIN_ENTRY}/)([a-zA-Z0-9_-]\{2,32\})\$ {
            return 301 \$uri/;
        }
        location ~ ^/(?!${ADMIN_ENTRY}\$)(?!${ADMIN_ENTRY}/)([a-zA-Z0-9_-]\{2,32\})(/.*)?\$ {
            root /dynamic-projects;
            try_files /\$1\$2 /\$1\$2/ /\$1/index.html =404;
        }

        # 点号模式（如 entry.domain.com/）：map 命中后从 /dynamic-projects/{后缀}/ 取站
        location / {
            if (\$dynamic_asset_root = "") {
                return 404;
            }
            root \$dynamic_asset_root;
            index index.html;
            try_files \$uri \$uri/ /index.html =404;
        }

        location ^~ /prod-api/ {
            proxy_pass http://backend:8080/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_buffering off;
            proxy_connect_timeout 60s;
            proxy_send_timeout 3600s;
            proxy_read_timeout 3600s;
        }

        # 管理端只用 HTTP，HTTPS 误访时跳回 80
        location = /${ADMIN_ENTRY} {
            return 302 http://\$host/${ADMIN_ENTRY}/;
        }
        location ^~ /${ADMIN_ENTRY}/ {
            return 302 http://\$host\$request_uri;
        }
        location ^~ /static/ {
            return 302 http://\$host\$request_uri;
        }
        location ^~ /assets/ {
            return 302 http://\$host\$request_uri;
        }
    }
}
EOF

# =========================================================
# 5. 构建带 certbot 的 backend 镜像（容器内申请证书需要）
# =========================================================
deploy_msg "${YELLOW}>>> 构建后端镜像（含 certbot + docker-cli）...${NC}"

cat > "$DEPLOY_DIR/backend.Dockerfile" <<'BEOF'
FROM eclipse-temurin:17-jdk-alpine
RUN apk add --no-cache certbot docker-cli
BEOF
if ! docker build -t app-deploy-backend:latest -f "$DEPLOY_DIR/backend.Dockerfile" "$DEPLOY_DIR" >>"$DEPLOY_LOG" 2>&1; then
    deploy_err "${RED}>>> 后端镜像构建失败（详见 $DEPLOY_LOG）${NC}"
    exit 1
fi

# =========================================================
# 6. 生成 Docker Compose
# =========================================================
deploy_msg "${YELLOW}>>> 生成 Docker Compose...${NC}"

cat <<EOF > $DEPLOY_DIR/docker-compose.yml
services:
  mysql:
    image: mysql:8.0
    container_name: app-deploy-mysql-1
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_PWD}
    volumes:
      - ./mysql_data:/var/lib/mysql
      # 不挂载 init 到 entrypoint：避免与第 7 步脚本 init/migrations 重复执行或竞态
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
    image: app-deploy-backend:latest
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
      - ./certbot-www:/var/www/certbot
      - ./letsencrypt:/etc/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - DEPLOY_ROOT=${CONTAINER_PROJECTS_DIR}
      - NGINX_RELOAD_CMD=docker exec app-deploy-frontend-1 nginx -s reload
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
      - MASTER_ENDPOINT_PKG=${MASTER_ENDPOINT_PKG}
    command:
      - java
      - -Xms512m
      - -Xmx1024m
      - -Dserver.port=8080
      - -Druoyi.profile=/app/data/uploadPath
      - -Druoyi.fingerprintFile=/app/data/license/device.id
      - -Ddeploy.root=${CONTAINER_PROJECTS_DIR}
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
      - ./backend-data/nginx-dynamic:/etc/nginx/nginx-dynamic:ro
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/ssl:/etc/nginx/ssl:ro
      - ./certbot-www:/var/www/certbot
      - ./letsencrypt:/etc/letsencrypt
    restart: always
EOF

mkdir -p "$DEPLOY_DIR/backend-data/nginx-dynamic"
# 占位 map，避免首次部署因 include 缺失导致 nginx -t 失败
if [ ! -f "$DEPLOY_DIR/backend-data/nginx-dynamic/asset-routes-map.conf" ]; then
    cat > "$DEPLOY_DIR/backend-data/nginx-dynamic/asset-routes-map.conf" <<'MAP_EOF'
# placeholder until backend refreshAssetRoutes()
map "$host|$uri" $dynamic_asset_root {
    default "";
}
MAP_EOF
fi
if [ ! -f "$DEPLOY_DIR/backend-data/nginx-dynamic/asset-routes-locations.conf" ]; then
    cat > "$DEPLOY_DIR/backend-data/nginx-dynamic/asset-routes-locations.conf" <<'LOC_EOF'
# placeholder until backend refreshAssetRoutes()
LOC_EOF
fi

# =========================================================
# 6. 小页面 HTTPS 证书与前端资源（子台解压到随机入口目录）
# =========================================================
deploy_msg "${YELLOW}>>> 处理 SSL 证书与前端静态资源...${NC}"

if [ ! -f "$DEPLOY_DIR/conf/ssl/server.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout $DEPLOY_DIR/conf/ssl/server.key \
    -out $DEPLOY_DIR/conf/ssl/server.crt \
    -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"
fi

# 勿将自签名证书写入 /etc/letsencrypt/live/tk-substation（会导致 certbot: live directory exists）
# 443 在未签发 LE 前使用 /etc/nginx/ssl；签发后 renewal 存在，下次生成 nginx 会自动切到 letsencrypt 路径
if [ ! -f "$DEPLOY_DIR/letsencrypt/renewal/tk-substation.conf" ]; then
    if [ -d "$DEPLOY_DIR/letsencrypt/live/tk-substation" ] \
        && [ ! -L "$DEPLOY_DIR/letsencrypt/live/tk-substation/cert.pem" ] 2>/dev/null; then
        deploy_msg "${BLUE}>>> 清理历史占位证书目录 letsencrypt/live/tk-substation（非 certbot 签发）${NC}"
        rm -rf "$DEPLOY_DIR/letsencrypt/live/tk-substation" "$DEPLOY_DIR/letsencrypt/archive/tk-substation" 2>/dev/null || true
    fi
fi

# 将 publicPath=/ 构建产物改为 /${ADMIN_ENTRY}/ 子路径（兼容仓库内预编译 dist.zip）
patch_admin_dist_for_entry() {
    local dir="$1"
    local base="/${ADMIN_ENTRY}"
    local base_slash="${base}/"

    # 1) index.html：最先注入 publicPath（修复懒加载 JS/CSS chunk 仍走 /static/...）
    if [ -f "$dir/index.html" ]; then
        if ! grep -q '<base href=' "$dir/index.html"; then
            sed -i "s|<head>|<head><base href=\"${base_slash}\">|" "$dir/index.html"
        fi
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
            -e "s|base:\"/\"|base:\"${base_slash}\"|g" \
            -e "s|base:'/'|base:'${base_slash}'|g" \
            -e "s|mode:\"history\",scrollBehavior|mode:\"history\",base:\"${base_slash}\",scrollBehavior|g" \
            -e "s|mode:'history',scrollBehavior|mode:'history',base:'${base_slash}',scrollBehavior|g" \
            -e "s|location\\.href=\"/index\"|location.href=\"${base}/index\"|g" \
            -e "s|location\\.href='/index'|location.href='${base}/index'|g" \
            -e "s|location\\.href=\"/login\"|location.href=\"${base}/login\"|g" \
            -e "s|location\\.href='/login'|location.href='${base}/login'|g" \
            -e "s|concat(t,\"logo-tktk.png\")|\"${base}/logo-tktk.png\"|g" \
            -e "s|concat(t,'logo-tktk.png')|'${base}/logo-tktk.png'|g" \
            -e "s|\"/logo-tktk.png\"|\"${base}/logo-tktk.png\"|g" \
            -e "s|'/logo-tktk.png'|'${base}/logo-tktk.png'|g" \
            "$f" || true
    done

    # 4) 校验：不应再出现根路径 /static/js|css（排除已带入口前缀）
    if grep -rq '"/static/js/' "$dir" 2>/dev/null || grep -rq '"/static/css/' "$dir" 2>/dev/null; then
        deploy_msg "${YELLOW}>>> 警告: 仍有文件引用根路径 /static/，建议按入口路径重新打包 dist.zip${NC}"
        grep -rl '"/static/js/' "$dir" 2>/dev/null | head -3 || true
        grep -rl '"/static/css/' "$dir" 2>/dev/null | head -3 || true
    fi
}

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
        deploy_err "${RED}>>> dist.zip 解压后未找到 index.html，请检查前端打包${NC}"
        exit 1
    fi
    patch_admin_dist_for_entry "$ADMIN_HTML_DIR"
    # 清理历史根目录泄露（旧版直接解压到 html/）
    find "$DEPLOY_DIR/html" -mindepth 1 -maxdepth 1 ! -name "$ADMIN_ENTRY" -exec rm -rf {} + 2>/dev/null || true
    rm -f "$DEPLOY_DIR/html/index.html" 2>/dev/null || true
    deploy_msg "${GREEN}>>> 子台前端已部署到 html/${ADMIN_ENTRY}/${NC}"
else
    deploy_msg "${YELLOW}>>> 警告: 未找到 $REPO_DIR/dist.zip${NC}"
    if [ ! -f "$ADMIN_HTML_DIR/index.html" ]; then
        deploy_err "${RED}>>> html/${ADMIN_ENTRY}/index.html 不存在，页面将无法正常访问${NC}"
        exit 1
    fi
    patch_admin_dist_for_entry "$ADMIN_HTML_DIR"
fi

# 启动前用临时容器校验 Nginx（避免 frontend 起不来后无法 exec）
validate_nginx_config_before_up() {
    deploy_msg "${YELLOW}>>> 预检 Nginx 配置（启动容器前）...${NC}"
    if docker run --rm \
        -v "$DEPLOY_DIR/conf/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$DEPLOY_DIR/html:/usr/share/nginx/html:ro" \
        -v "$DEPLOY_DIR/dynamic-projects:/dynamic-projects:ro" \
        -v "$DEPLOY_DIR/backend-data/nginx-dynamic:/etc/nginx/nginx-dynamic:ro" \
        -v "$DEPLOY_DIR/conf/ssl:/etc/nginx/ssl:ro" \
        -v "$DEPLOY_DIR/certbot-www:/var/www/certbot:ro" \
        -v "$DEPLOY_DIR/letsencrypt:/etc/letsencrypt:ro" \
        nginx:stable-alpine nginx -t >>"$DEPLOY_LOG" 2>&1; then
        deploy_msg "${GREEN}>>> Nginx 配置预检通过${NC}"
        return 0
    fi
    deploy_err "${RED}>>> Nginx 配置无效，frontend 无法启动。最近输出：${NC}"
    tail -30 "$DEPLOY_LOG" >&2 || true
    deploy_err "${RED}>>> 常见原因：SSL 证书路径不存在、include 的动态路由文件语法错误${NC}"
    return 1
}

# =========================================================
# 7. 启动服务与数据库导入
# =========================================================
deploy_msg "${YELLOW}>>> 修复权限并启动服务...${NC}"

chown -R ubuntu:ubuntu $DEPLOY_DIR
chmod -R 777 $DEPLOY_DIR/redis_data
chmod -R 755 $DEPLOY_DIR/html
chmod -R 755 $PROJECTS_DIR
chmod -R 755 "$DEPLOY_DIR/backend-data"

cd $DEPLOY_DIR

deploy_msg "${YELLOW}>>> 检查 80 端口与宿主机 Nginx...${NC}"
if [ "$DEPLOY_VERBOSE" = "1" ]; then
    (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep ':80 ' || true
else
    { (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep ':80 ' || true; } >>"$DEPLOY_LOG" 2>&1
fi
fix_host_nginx_https_redirect

if ! validate_nginx_config_before_up; then
    exit 1
fi

# 仅停止容器，不删除宿主机 bind mount 数据（勿用 docker compose down -v）
run_quiet docker compose down || true
run_quiet docker compose up -d --force-recreate

# 旧版 JAR 可能写入容器内 /opt/homebrew/var/www，合并到持久化目录（不覆盖已有文件）
deploy_msg "${YELLOW}>>> 检查并迁移小页面到持久化目录 ${PROJECTS_DIR} ...${NC}"
if [ "$DEPLOY_VERBOSE" = "1" ]; then
    docker exec app-deploy-backend-1 sh -c '
      for legacy in /opt/homebrew/var/www /var/www/html; do
        if [ -d "$legacy" ] && [ -n "$(ls -A "$legacy" 2>/dev/null)" ]; then
          cp -an "$legacy"/. /dynamic-projects/ 2>/dev/null || true
        fi
      done
    ' 2>/dev/null || deploy_msg "${YELLOW}>>> 后端尚未就绪，跳过迁移${NC}"
else
    docker exec app-deploy-backend-1 sh -c '
      for legacy in /opt/homebrew/var/www /var/www/html; do
        if [ -d "$legacy" ] && [ -n "$(ls -A "$legacy" 2>/dev/null)" ]; then
          cp -an "$legacy"/. /dynamic-projects/ 2>/dev/null || true
        fi
      done
    ' >>"$DEPLOY_LOG" 2>&1 || deploy_msg "${YELLOW}>>> 后端尚未就绪，跳过迁移${NC}"
fi

deploy_msg "${YELLOW}>>> 校验 Nginx 配置...${NC}"
sleep 3

# 若 nginx 容器因配置错误已停止，先打印日志以便排查
if ! docker ps --format '{{.Names}}' | grep -q '^app-deploy-frontend-1$'; then
    deploy_err "${RED}>>> Nginx 容器已停止，最近日志如下：${NC}"
    docker logs --tail 30 app-deploy-frontend-1 2>&1 || true
    deploy_err "${RED}>>> 请检查上方日志修复配置后重新执行${NC}"
    exit 1
fi

if ! docker exec app-deploy-frontend-1 nginx -t >>"$DEPLOY_LOG" 2>&1; then
    deploy_err "${RED}>>> 运行中 Nginx 配置校验失败，容器日志：${NC}"
    docker logs --tail 40 app-deploy-frontend-1 2>&1 | tee -a "$DEPLOY_LOG" >&2 || true
    exit 1
fi

deploy_msg "${YELLOW}>>> 等待 MySQL 就绪并导入 SQL...${NC}"
mysql_wait_ready

ensure_schema_migration_table

if tk_admin_is_initialized; then
    deploy_msg "${GREEN}>>> 已部署库（存在 sys_user），跳过 sql/*.sql 全量 init${NC}"
else
    deploy_msg "${YELLOW}>>> 新库：执行 sql/*.sql 初始化...${NC}"
    for sql in $(ls "$DEPLOY_DIR/init"/*.sql 2>/dev/null | sort); do
        base=$(basename "$sql")
        deploy_msg "${BLUE}>>> [init] $base${NC}"
        if [[ "$base" == "00_create_databases.sql" ]]; then
            if ! docker exec -i app-deploy-mysql-1 \
                mysql -uroot -p"${MYSQL_PWD}" --default-character-set=utf8mb4 < "$sql"; then
                deploy_err "${RED}>>> init 失败: $base${NC}"
                exit 1
            fi
        elif ! mysql_apply_sql_file tk-admin "$sql"; then
            deploy_err "${RED}>>> init 失败: $base${NC}"
            exit 1
        fi
    done
    deploy_msg "${GREEN}>>> 初始化 SQL 完成${NC}"
fi

MIG_APPLIED=0
MIG_SKIPPED=0
MIG_REPAIRED=0
MIG_SUMMARY="无增量 SQL 文件"
if compgen -G "$DEPLOY_DIR/migrations"/*.sql >/dev/null; then
    for sql in $(ls "$DEPLOY_DIR/migrations"/*.sql 2>/dev/null | sort); do
        base=$(basename "$sql")
        if ! migration_should_run "$base"; then
            deploy_msg "${BLUE}>>> [migrate] 已应用，跳过: $base${NC}"
            MIG_SKIPPED=$((MIG_SKIPPED + 1))
            continue
        fi
        if [ "${_last_mig_repair:-0}" = "1" ]; then
            MIG_REPAIRED=$((MIG_REPAIRED + 1))
        fi
        deploy_msg "${BLUE}>>> [migrate] 执行: $base${NC}"
        deploy_user "${BLUE}>>> [migrate] 执行: $base${NC}"
        if ! mysql_apply_sql_file tk-admin "$sql"; then
            deploy_err "${RED}>>> migration 失败: $base（未写入 schema_migration，可修复后重跑）${NC}"
            exit 1
        fi
        if ! migration_effect_ok "$base"; then
            deploy_err "${RED}>>> migration 执行后校验未通过: $base（请检查 SQL 或表结构）${NC}"
            exit 1
        fi
        record_migration_applied "$base"
        MIG_APPLIED=$((MIG_APPLIED + 1))
    done
    if [ "$MIG_APPLIED" -eq 0 ]; then
        MIG_SUMMARY="增量 SQL：${MIG_SKIPPED} 个均已是最新"
        deploy_msg "${GREEN}>>> ${MIG_SUMMARY}${NC}"
    else
        MIG_SUMMARY="增量 SQL：本次执行 ${MIG_APPLIED} 个，跳过 ${MIG_SKIPPED} 个"
        if [ "$MIG_REPAIRED" -gt 0 ]; then
            MIG_SUMMARY="${MIG_SUMMARY}（含 ${MIG_REPAIRED} 个自动补跑）"
        fi
        deploy_msg "${GREEN}>>> ${MIG_SUMMARY}${NC}"
    fi
else
    deploy_msg "${BLUE}>>> 无 sql/migrations 增量脚本${NC}"
    if [ -n "$REPO_MIG_DIR" ] && compgen -G "$REPO_MIG_DIR"/*.sql >/dev/null; then
        deploy_err "${RED}>>> 仓库有 migration 但未复制到部署目录，请检查第 3 步日志${NC}"
        exit 1
    fi
fi

deploy_msg "${YELLOW}>>> 重载 Nginx（应用资产域名 map）...${NC}"
if docker exec app-deploy-frontend-1 nginx -t >>"$DEPLOY_LOG" 2>&1; then
    run_quiet docker exec app-deploy-frontend-1 nginx -s reload
    deploy_msg "${GREEN}>>> Nginx 已 reload${NC}"
else
    deploy_err "${YELLOW}>>> Nginx 配置校验失败，请检查 backend-data/nginx-dynamic/asset-routes-map.conf${NC}"
fi

# =========================================================
# 8. 健康检查
# =========================================================
deploy_msg "${YELLOW}>>> 健康检查...${NC}"

ROOT_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ || echo "000")
ADMIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1/${ADMIN_ENTRY}/" || echo "000")
if [ "$ROOT_CODE" = "404" ]; then
    deploy_msg "${GREEN}>>> 根路径 HTTP 已禁止访问 (404)${NC}"
else
    deploy_msg "${YELLOW}>>> 根路径 HTTP 返回 $ROOT_CODE（期望 404）${NC}"
fi
if [ "$ADMIN_CODE" = "200" ]; then
    deploy_msg "${GREEN}>>> 子台管理端 HTTP /${ADMIN_ENTRY}/ 返回 200 OK${NC}"
else
    deploy_msg "${YELLOW}>>> 子台入口返回 $ADMIN_CODE（若刚启动可稍等: curl -I http://127.0.0.1/${ADMIN_ENTRY}/）${NC}"
fi

SAMPLE_PROJECT=$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | head -1)
if [ -n "$SAMPLE_PROJECT" ]; then
    SAMPLE_NAME=$(basename "$SAMPLE_PROJECT")
    HTTP_PAGE_LOC=$(curl -sI "http://127.0.0.1/${SAMPLE_NAME}/" 2>/dev/null | tr -d '\r' | grep -i '^Location:' | head -1 || true)
    HTTPS_PAGE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1/${SAMPLE_NAME}/" 2>/dev/null || echo "000")
    if echo "$HTTP_PAGE_LOC" | grep -qi 'https://'; then
        deploy_msg "${GREEN}>>> 小页面 HTTP→HTTPS 跳转正常: /${SAMPLE_NAME}/ → $HTTP_PAGE_LOC${NC}"
    else
        deploy_msg "${YELLOW}>>> 小页面 HTTP 未跳 HTTPS（期望 301）: $HTTP_PAGE_LOC${NC}"
    fi
    if [ "$HTTPS_PAGE_CODE" = "200" ]; then
        deploy_msg "${GREEN}>>> 小页面 HTTPS /${SAMPLE_NAME}/ 返回 200 OK${NC}"
    else
        deploy_msg "${YELLOW}>>> 小页面 HTTPS 返回 $HTTPS_PAGE_CODE（可稍后: curl -k -I https://127.0.0.1/${SAMPLE_NAME}/）${NC}"
    fi
fi

if docker logs app-deploy-backend-1 2>&1 | tail -50 | grep -q "若依启动成功"; then
    deploy_msg "${GREEN}>>> 后端若依已启动${NC}"
else
    deploy_msg "${YELLOW}>>> 后端可能仍在启动，查看日志: docker logs -f app-deploy-backend-1${NC}"
fi

if [ -f "$DEPLOY_DIR/backend-data/license/device.id" ]; then
    deploy_msg "${GREEN}>>> 设备指纹已持久化: backend-data/license/device.id${NC}"
else
    deploy_msg "${YELLOW}>>> 首次部署尚未生成 device.id，激活后将写入 backend-data/license/${NC}"
fi

# =========================================================
# 9. 完成（仅向用户展示必要信息）
# =========================================================
deploy_user "${GREEN}TK 子台部署完成！${NC}"
deploy_user ""
deploy_user "${MIG_SUMMARY:-增量 SQL：未执行检查}"
deploy_user ""
deploy_user "子台管理端（HTTP，请妥善保存入口）:"
deploy_user "  http://你的服务器IP/${ADMIN_ENTRY}/"
deploy_user ""
deploy_user "默认登录账号: admin"
deploy_user "默认登录密码: admin123"
deploy_user "${YELLOW}>>> 请登录后立即修改默认密码！${NC}"