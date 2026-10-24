#!/bin/zsh
#
# 构建签名 HAP。需要先用 setup-signing.sh 生成 build-profile.json5。
# 环境变量 JAVA_HOME / DEVECO_SDK_HOME / HVIGORW 都可覆盖，默认指向 DevEco Studio 内置版本。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"

: "${JAVA_HOME:=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home}"
: "${DEVECO_SDK_HOME:=/Applications/DevEco-Studio.app/Contents/sdk}"
: "${HVIGORW:=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw}"

if [[ ! -f "$APP_DIR/build-profile.json5" ]]; then
  echo "缺少 $APP_DIR/build-profile.json5" >&2
  echo "先跑：$ROOT/scripts/setup-signing.sh" >&2
  exit 1
fi

export JAVA_HOME DEVECO_SDK_HOME
export PATH="$JAVA_HOME/bin:$PATH"

cd "$APP_DIR"

# macOS 的 com.apple.provenance 扩展属性会让 restool 删不掉 build/ 里的中间产物
# （报 Failed to delete ... Operation not permitted）。删扩展属性，删不掉就算了，
# 真正要命的是上一次的 build/ 残留 —— 那部分下面会先整个清掉。
if xattr -r -d com.apple.provenance "$APP_DIR" 2>/dev/null; then
  :
else
  echo "提示：部分文件的 com.apple.provenance 属性无法清除，若构建报 delete 失败请执行 rm -rf app/entry/build app/.hvigor"
fi

# hvigor 缓存残留旧绝对路径 / 上次失败的中间产物，都会让构建莫名其妙失败
rm -rf "$APP_DIR/entry/build" "$APP_DIR/.hvigor"

"$HVIGORW" assembleHap --mode module -p product=default --no-daemon

# 产物校验：必须是 signed，拿不到就当失败（unsigned 装不上真机，只能自己重签）
HAP="$(find "$APP_DIR/entry/build" -name 'entry-default-signed.hap' | head -1)"
if [[ -z "$HAP" ]]; then
  echo "未找到签名产物 entry-default-signed.hap" >&2
  exit 1
fi
UNSIGNED="$(find "$APP_DIR/entry/build" -name 'entry-default-unsigned.hap' | head -1)"

human() { du -h "$1" | cut -f1 | tr -d ' '; }
echo "构建成功："
echo "  signed  : $HAP（$(human "$HAP")）"
if [[ -n "$UNSIGNED" ]]; then
  echo "  unsigned: $UNSIGNED（$(human "$UNSIGNED")）"
else
  echo "  unsigned: 未找到（发版时会少一个未签名资产，不影响签名版）"
fi
