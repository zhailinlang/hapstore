#!/bin/zsh
#
# 保活：手动触发一次快照工作流。
#
# GitHub 会在仓库 60 天无任何活动后停用 schedule 定时任务。本仓库每天会提交
# manifest，本身就是活动，正常不需要这个脚本；真被停用了（Actions 页面提示
# "This scheduled workflow is disabled"）就跑一次即可重新激活。
#
# 适合放在家里的机器上做每周 cron。需要 PAT 带 workflow scope：
#   export GH_TOKEN=ghp_xxx        # 或 gh auth login
#   ./scripts/keepalive.sh
#
# crontab 示例（每周一 09:00）：
#   0 9 * * 1 /Users/maxzhai/Dev/hapstore/scripts/keepalive.sh >> /tmp/hapstore-keepalive.log 2>&1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$REPO" ]]; then
  echo "没配 origin，先：git remote add origin git@github.com:OWNER/hapstore.git" >&2
  exit 1
fi
REPO="${REPO%.git}"
REPO="${REPO#git@github.com:}"
REPO="${REPO#https://github.com/}"

if command -v gh >/dev/null; then
  gh workflow run snapshot.yml --repo "$REPO"
else
  echo "未安装 gh" >&2
  exit 1
fi

echo "$(date '+%F %T') 已触发 $REPO 的 snapshot 工作流"
