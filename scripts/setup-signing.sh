#!/bin/zsh
#
# 从 ~/.hapstore-signing.env 渲染出 app/build-profile.json5。
# 真实签名配置含明文口令 + 本机绝对路径，绝不能进 git；仓库里只有 build-profile.example.json5。
#
# 用 python 做占位符替换而不是 sed：CERT_ID 含 '='、路径含 '/'、口令含各种字符，
# sed 的转义规则在这种场景下极易出错。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${HAPSTORE_SIGN_ENV:-$HOME/.hapstore-signing.env}"
SRC="$ROOT/app/build-profile.example.json5"
DST="$ROOT/app/build-profile.json5"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "缺少 $ENV_FILE" >&2
  echo "按下面格式创建（chmod 600）：" >&2
  echo "  CERT_DIR=\"/Users/你/.ohos/config\"" >&2
  echo "  CERT_BASENAME='default_HapStore_随机ID'" >&2
  echo "  KEY_ALIAS='debugKey'" >&2
  echo "  KEY_PASSWORD='…'" >&2
  echo "  STORE_PASSWORD='…'" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for v in CERT_DIR CERT_BASENAME KEY_ALIAS KEY_PASSWORD STORE_PASSWORD; do
  if [[ -z "${(P)v}" ]]; then
    echo "$v 未在 $ENV_FILE 中设置" >&2
    exit 1
  fi
done

CERT_DIR="$CERT_DIR" CERT_BASENAME="$CERT_BASENAME" KEY_ALIAS="$KEY_ALIAS" \
KEY_PASSWORD="$KEY_PASSWORD" STORE_PASSWORD="$STORE_PASSWORD" \
python3 - "$SRC" "$DST" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
rep = {
    '__CERT_DIR__': os.environ['CERT_DIR'],
    '__CERT_BASENAME__': os.environ['CERT_BASENAME'],
    '__KEY_ALIAS__': os.environ['KEY_ALIAS'],
    '__KEY_PASSWORD__': os.environ['KEY_PASSWORD'],
    '__STORE_PASSWORD__': os.environ['STORE_PASSWORD'],
}
s = open(src, encoding='utf-8').read()
for k, v in rep.items():
    s = s.replace(k, v)
open(dst, 'w', encoding='utf-8').write(s)
PY

chmod 600 "$DST"
echo "已生成 $DST（权限 600，已在 .gitignore 中）"
