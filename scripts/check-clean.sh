#!/bin/zsh
#
# push 前自查：确认没有任何敏感文件会被提交。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

echo "== 1. 已跟踪文件里是否含签名配置 =="
if git ls-files | grep -qx 'app/build-profile.json5'; then
  echo "  ✗ app/build-profile.json5 已被跟踪"
  fail=1
else
  echo "  ✓ 未被跟踪"
fi

echo "== 2. 已跟踪文件里是否含证书 =="
bad="$(git ls-files | grep -E '\.(p12|p7b|cer)$' || true)"
if [[ -n "$bad" ]]; then
  echo "  ✗ $bad"
  fail=1
else
  echo "  ✓ 无证书文件"
fi

echo "== 3. 已跟踪文件内容里是否出现真实口令 =="
# 只匹配「字段 + 32 位以上值」，放行 example 模板里的 __KEY_PASSWORD__ 占位符
if git grep -nE '"(keyPassword|storePassword)"[[:space:]]*:[[:space:]]*"[^"]{32,}"' -- . 2>/dev/null; then
  echo "  ✗ 上面这些行含真实口令"
  fail=1
else
  echo "  ✓ 无真实口令（example 模板的占位符不算）"
fi

echo "== 3b. 本机签名环境里的真实值是否出现在已跟踪内容中 =="
ENV_FILE="${HAPSTORE_SIGN_ENV:-$HOME/.hapstore-signing.env}"
if [[ -r "$ENV_FILE" ]]; then
  for key in KEY_PASSWORD STORE_PASSWORD; do
    val="$(sed -n "s/^${key}='\(.*\)'$/\1/p" "$ENV_FILE" 2>/dev/null || true)"
    if [[ -n "$val" ]] && git grep -qF "$val" -- . 2>/dev/null; then
      echo "  ✗ 已跟踪内容里出现了 $key 的真实值"
      fail=1
    fi
  done
  echo "  （若上面无 ✗，则真实值未出现在仓库中）"
else
  echo "  - 无 $ENV_FILE，跳过"
fi

echo "== 4. 历史里是否曾出现过签名配置 =="
if git log --all --full-history --oneline -- app/build-profile.json5 2>/dev/null | grep -q .; then
  echo "  ✗ 历史里有 app/build-profile.json5，需要用 git filter-repo 清理并轮换证书"
  fail=1
else
  echo "  ✓ 历史干净"
fi

echo "== 5. 工作区里待提交的文件是否含口令 =="
staged="$(git diff --cached -U0 2>/dev/null | grep -E '^\+.*(keyPassword|storePassword)' || true)"
if [[ -n "$staged" ]]; then
  echo "  ✗ 暂存区 diff 含口令："
  echo "$staged"
  fail=1
else
  echo "  ✓ 暂存区干净"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "全部通过，可以 push。"
else
  echo "存在问题，先修再 push。" >&2
fi
exit $fail
