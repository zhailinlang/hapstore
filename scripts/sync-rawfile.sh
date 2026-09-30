#!/bin/zsh
#
# 把 data/apps.json 同步进 App 的 rawfile，作为「出厂内置快照」打进 HAP。
#
# 内置快照决定了用户第一次打开 App（还没联网）时看到什么，所以每次跑完
# sync.py 拿到新快照后、准备发版前，都要跑一次这个脚本。
#
# 用法：
#   ./scripts/sync-rawfile.sh              # 只搬运现有的 data/apps.json
#   ./scripts/sync-rawfile.sh --regen      # 先本地重跑一遍 sync.py，再搬运
#
# 环境变量：PYTHON 可指定解释器（sync.py 需要 PyYAML + Pillow）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/data/apps.json"
DST="$ROOT/app/entry/src/main/resources/rawfile/apps.json"
RAWFILE_DIR="$(dirname "$DST")"

if [[ "${1:-}" == "--regen" ]]; then
  : "${PYTHON:=python3}"
  echo "重新生成快照…"
  "$PYTHON" "$ROOT/sync/sync.py" --mode api --out "$SRC"
fi

if [[ ! -f "$SRC" ]]; then
  echo "缺少 $SRC" >&2
  echo "先跑 ./scripts/sync-rawfile.sh --regen，或从 Release 下载一份放到该路径" >&2
  exit 1
fi

# 结构校验：搬运一份坏快照进 HAP 会让 App 启动就白屏
python3 - "$SRC" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
cats = d.get('categories') or []
apps = sum(len(c.get('apps') or []) for c in cats)
if apps == 0:
    print(f'快照里一个应用都没有，拒绝搬运：{p}', file=sys.stderr)
    sys.exit(1)
print(f'快照校验通过：schema={d.get("schemaVersion")} 分类 {len(cats)} 个 应用 {apps} 个 '
      f'生成于 {d.get("generatedAt")}')
PY

mkdir -p "$RAWFILE_DIR"
cp "$SRC" "$DST"

SIZE="$(du -h "$DST" | cut -f1 | tr -d ' ')"
echo "已同步内置快照：$DST（$SIZE）"
echo "下一步：./scripts/build.sh 重新打包 HAP"
