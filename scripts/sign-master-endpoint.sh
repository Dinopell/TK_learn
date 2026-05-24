#!/bin/bash
# 运维工具：RSA 私钥签名，生成 deploy/master.endpoint.pkg（私钥勿提交 Git、勿放在子台服务器）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRIVATE_KEY="${MASTER_SIGN_PRIVATE_KEY:-$SCRIPT_DIR/keys/master-sign-private.pem}"
OUT_FILE="${1:-$REPO_ROOT/deploy/master.endpoint.pkg}"
# 默认 1 年；10 年请: export MASTER_SIGN_DAYS=3650
DAYS="${MASTER_SIGN_DAYS:-365}"

usage() {
    echo "用法:"
    echo "  export MASTER_PLAIN_URL='https://总台/prod-api'"
    echo "  export MASTER_PLAIN_API_KEY='密钥'"
    echo "  export MASTER_PLAIN_SSL_INSECURE=1   # 可选"
    echo "  bash $0 [输出文件路径]"
    exit 1
}

if [ -z "${MASTER_PLAIN_URL:-}" ] || [ -z "${MASTER_PLAIN_API_KEY:-}" ]; then
    usage
fi

if [ ! -f "$PRIVATE_KEY" ]; then
    echo "缺少私钥: $PRIVATE_KEY"
    echo "首次生成: openssl genrsa -out $PRIVATE_KEY 2048"
    echo "并同步公钥到 ruoyi-common/src/main/resources/certs/master-sign-public.pem"
    exit 1
fi

URL="$MASTER_PLAIN_URL"
while [[ "$URL" == */ ]]; do URL="${URL%/}"; done
SSL="false"
if [ "${MASTER_PLAIN_SSL_INSECURE:-0}" = "1" ]; then
    SSL="true"
fi

EXP=$(($(date +%s) + DAYS * 86400))
# 单行 JSON，与后端验签字节完全一致
JSON=$(printf '{"v":2,"url":"%s","apiKey":"%s","sslInsecure":%s,"exp":%s,"kid":"default"}' \
    "$(printf '%s' "$URL" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$(printf '%s' "$MASTER_PLAIN_API_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
    "$SSL" "$EXP")

TMP_PAYLOAD="$(mktemp)"
TMP_SIG="$(mktemp)"
trap 'rm -f "$TMP_PAYLOAD" "$TMP_SIG"' EXIT

printf '%s' "$JSON" > "$TMP_PAYLOAD"
openssl dgst -sha256 -sign "$PRIVATE_KEY" -binary "$TMP_PAYLOAD" > "$TMP_SIG"

b64url() { openssl base64 -A -in "$1" | tr '+/' '-_' | tr -d '=\n'; }
PAYLOAD_B64=$(b64url "$TMP_PAYLOAD")
SIG_B64=$(b64url "$TMP_SIG")
PKG="v2.${PAYLOAD_B64}.${SIG_B64}"

mkdir -p "$(dirname "$OUT_FILE")"
printf '%s' "$PKG" > "$OUT_FILE"
chmod 600 "$OUT_FILE"
echo "已签发: $OUT_FILE"
if date -r "$EXP" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
    echo "有效期至: $(date -r "$EXP" '+%Y-%m-%d %H:%M:%S')"
elif date -d "@$EXP" '+%Y-%m-%d %H:%M:%S' >/dev/null 2>&1; then
    echo "有效期至: $(date -d "@$EXP" '+%Y-%m-%d %H:%M:%S')"
else
    echo "有效期至 exp=$EXP"
fi
echo "请提交该文件并发布含对应公钥的新版 springboot-app.jar。"
