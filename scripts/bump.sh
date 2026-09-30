#!/bin/zsh
#
# 升版本号：改 app/AppScope/app.json5 的 versionCode / versionName。
#
# versionCode 规则：major*1_000_000 + minor*1_000 + patch（1.0.0 → 1000000）。
# App 端拿 manifest.app.versionCode 跟本机比大小判断有没有新版，
# 所以 versionCode 必须单调递增，不能只改 versionName。
#
# 用法：
#   ./scripts/bump.sh patch        # 1.0.0 → 1.0.1
#   ./scripts/bump.sh minor        # 1.0.0 → 1.1.0
#   ./scripts/bump.sh major        # 1.0.0 → 2.0.0
#   ./scripts/bump.sh 1.2.3        # 直接指定
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_JSON5="$ROOT/app/AppScope/app.json5"

if [[ $# -ne 1 ]]; then
  echo "用法：$0 patch|minor|major|X.Y.Z" >&2
  exit 1
fi

python3 - "$APP_JSON5" "$1" <<'PY'
import json, re, sys

path, arg = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
code = int(re.search(r'"versionCode"\s*:\s*(\d+)', s).group(1))
name = re.search(r'"versionName"\s*:\s*"([^"]+)"', s).group(1)
major, minor, patch = (int(x) for x in name.split('.'))

if arg == 'major':
    major, minor, patch = major + 1, 0, 0
elif arg == 'minor':
    minor, patch = minor + 1, 0
elif arg == 'patch':
    patch += 1
elif re.fullmatch(r'\d+\.\d+\.\d+', arg):
    major, minor, patch = (int(x) for x in arg.split('.'))
else:
    print(f'无法识别的版本参数：{arg}', file=sys.stderr)
    sys.exit(1)

new_name = f'{major}.{minor}.{patch}'
new_code = major * 1_000_000 + minor * 1_000 + patch
if new_code <= code:
    print(f'versionCode 必须递增：当前 {code}，算出 {new_code}，拒绝写入', file=sys.stderr)
    sys.exit(1)

s = re.sub(r'"versionCode"\s*:\s*\d+', f'"versionCode": {new_code}', s, count=1)
s = re.sub(r'"versionName"\s*:\s*"[^"]+"', f'"versionName": "{new_name}"', s, count=1)
open(path, 'w', encoding='utf-8').write(s)
print(f'{name} ({code}) → {new_name} ({new_code})')
PY

echo "下一步：./scripts/build.sh && ./scripts/release.sh"
