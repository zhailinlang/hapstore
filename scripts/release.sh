#!/bin/zsh
#
# 发版：构建签名 HAP → 刷新 manifest 的 app 段 → 打 tag。
#
# HAP 的构建与签名只在本机做（签名材料不进仓库、也不上 CI），
# GitHub 那边只负责存 Release 资产和每天刷新快照。
#
# 用法：
#   ./scripts/release.sh                 # 只在本机准备好：构建 + 写 manifest + 打本地 tag
#   ./scripts/release.sh --push          # 额外 push 分支与 tag，并用 gh 建 Release
#
# --push 需要：gh 已登录（gh auth status），且当前分支干净。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/out"
DO_PUSH=0
NOTES="${NOTES:-}"

for a in "$@"; do
  case "$a" in
    --push) DO_PUSH=1 ;;
    --notes=*) NOTES="${a#--notes=}" ;;
    *) echo "未知参数：$a" >&2; exit 1 ;;
  esac
done

APP_JSON5="$ROOT/app/AppScope/app.json5"
VERSION="$(python3 -c "
import re,sys
s=open('$APP_JSON5',encoding='utf-8').read()
print(re.search(r'\"versionName\"\s*:\s*\"([^\"]+)\"', s).group(1))
")"
CODE="$(python3 -c "
import re,sys
s=open('$APP_JSON5',encoding='utf-8').read()
print(re.search(r'\"versionCode\"\s*:\s*(\d+)', s).group(1))
")"
TAG="v$VERSION"

echo "准备发布 $TAG（versionCode $CODE）"

# 1) 内置快照是不是最新的：data/apps.json 与 rawfile 不一致就提醒（不阻断，
#    因为 Actions 每天会刷新远端快照，内置快照只是离线兜底）
if [[ -f "$ROOT/data/apps.json" ]]; then
  if ! cmp -s "$ROOT/data/apps.json" "$ROOT/app/entry/src/main/resources/rawfile/apps.json"; then
    echo "提示：内置快照与 data/apps.json 不一致，如需带上最新快照请先跑 ./scripts/sync-rawfile.sh"
  fi
fi

# 2) 构建
"$ROOT/scripts/build.sh"

# 3) 产物归档到 out/：签名版（可直接装）+ 未签名版（供自行重签）
mkdir -p "$OUT_DIR"
HAP_SRC="$(find "$ROOT/app/entry/build" -name 'entry-default-signed.hap' | head -1)"
UNSIGNED_SRC="$(find "$ROOT/app/entry/build" -name 'entry-default-unsigned.hap' | head -1)"
[[ -z "$HAP_SRC" ]] && { echo "未找到签名产物 entry-default-signed.hap" >&2; exit 1; }

HAP_OUT="$OUT_DIR/HapStore-$TAG-signed.hap"
cp "$HAP_SRC" "$HAP_OUT"
echo "签名版已归档：$HAP_OUT"
echo "  sha256: $(shasum -a 256 "$HAP_OUT" | cut -d' ' -f1)"

UPLOADS=("$HAP_OUT")
UNSIGNED_OUT=""
if [[ -n "$UNSIGNED_SRC" ]]; then
  UNSIGNED_OUT="$OUT_DIR/HapStore-$TAG-unsigned.hap"
  cp "$UNSIGNED_SRC" "$UNSIGNED_OUT"
  echo "未签名版已归档：$UNSIGNED_OUT"
  echo "  sha256: $(shasum -a 256 "$UNSIGNED_OUT" | cut -d' ' -f1)"
  UPLOADS+=("$UNSIGNED_OUT")
else
  echo "提示：没有未签名产物，本次只发签名版"
fi

# 4) 刷新 manifest 的 app 段（App 自更新只认签名版；未签名版另记一个 unsignedUrl）
# 注意：zsh 不会自动拆分不带引号的参数展开，可选参数必须拼成数组再展开，
# 否则 "--asset-unsigned /path" 会被当成一个 argv 元素传进去。
: "${PYTHON:=python3}"
MANIFEST_ARGS=(--set-app-version "$VERSION" --asset "$HAP_OUT")
if [[ -n "$UNSIGNED_OUT" ]]; then
  MANIFEST_ARGS+=(--asset-unsigned "$UNSIGNED_OUT")
fi
MANIFEST_ARGS+=(--notes "${NOTES:-HapStore $TAG}")
"$PYTHON" "$ROOT/sync/manifest.py" "${MANIFEST_ARGS[@]}"

# 5) 提交并打 tag
cd "$ROOT"
git add app/AppScope/app.json5 data/manifest.json
if git diff --cached --quiet; then
  echo "没有需要提交的版本改动"
else
  git commit -m "release: $TAG"
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG 已存在，跳过创建"
else
  git tag -a "$TAG" -m "HapStore $TAG"
  echo "已打 tag：$TAG"
fi

# Release 页面正文。没传 --notes 就用默认文案，把两个资产的区别讲清楚。
if [[ -z "$NOTES" ]]; then
  NOTES="HapStore $TAG

**HapStore-$TAG-signed.hap** —— 签名版，可直接安装：
\`hdc install HapStore-$TAG-signed.hap\`

**HapStore-$TAG-unsigned.hap** —— 未签名版，供你用自己的证书重签。
鸿蒙要求 HAP 必须签名才能安装，未签名版直接装会失败，仅在你不想用本项目证书时使用。"
fi

if [[ $DO_PUSH -eq 0 ]]; then
  cat <<TIP

本机准备完毕。确认无误后执行：

  git push origin HEAD && git push origin $TAG
  gh release create $TAG "${UPLOADS[@]}" --title "HapStore $TAG" --notes "$NOTES"
  gh release upload snapshot-latest "$ROOT/data/apps.json" --clobber   # 可选：顺手刷新快照资产

或者直接跑：./scripts/release.sh --push
TIP
  exit 0
fi

# 6) 推送 + 建 Release
command -v gh >/dev/null || { echo "未安装 gh（brew install gh）" >&2; exit 1; }
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git push origin "HEAD:$BRANCH"
git push origin "$TAG"

# 滚动 tag 必须标 pre-release，否则会抢走 /releases/latest
gh release view snapshot-latest >/dev/null 2>&1 \
  || gh release create snapshot-latest --prerelease --title "快照（滚动更新）" \
       --notes "由 GitHub Actions 每 12 小时刷新，请勿手动下载此处的旧文件。"

if [[ -f "$ROOT/data/apps.json" ]]; then
  gh release upload snapshot-latest "$ROOT/data/apps.json" "$ROOT/data/manifest.json" --clobber
fi

gh release create "$TAG" "${UPLOADS[@]}" --title "HapStore $TAG" --notes "$NOTES"
REPO_SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"
echo "发布完成：$TAG"
if [[ -n "$REPO_SLUG" ]]; then
  echo "  https://github.com/$REPO_SLUG/releases/tag/$TAG"
fi
