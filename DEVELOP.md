# 维护者笔记

只想用 App 的话看 [README.md](README.md)。这份是给自己看的：怎么构建、怎么发版、快照怎么自动更新、出问题怎么排查。

---

## 数据流

```
apps.yaml（上游清单）
    │
    ▼
sync/sync.py          GitHub API + ETag 增量 + 图标转 base64 内嵌
    │                 （纯 IO 活，零算力，Actions 里 3-5 分钟跑完）
    ▼
data/apps.json        528KB，schemaVersion 2
    │
    ├──▶ ① Release 滚动资产 snapshot-latest   ← 主地址，可被 ghfast.top 等镜像代理
    └──▶ ② snapshot-data 分支的 raw 地址      ← 兜底地址
              │
              ▼
         App 先拉 700B 的 data/manifest.json，比对 sha256 再决定要不要拉 528KB
```

三条地址（可直接 curl 验证）：

```bash
# 主地址：快照
curl -sI -L https://github.com/zhailinlang/hapstore/releases/download/snapshot-latest/apps.json

# 主地址：指针文件（含快照 sha256 与 App 最新版本）
curl -s https://github.com/zhailinlang/hapstore/releases/download/snapshot-latest/manifest.json

# 兜底地址
curl -s https://raw.githubusercontent.com/zhailinlang/hapstore/snapshot-data/apps.json
```

---

## 仓库结构

| 目录 | 内容 |
|---|---|
| `app/` | ArkTS 应用（DevEco Studio，API 12+ / API 26 实测） |
| `sync/` | 快照生成器（Python 3.12，只要 PyYAML + Pillow） |
| `data/` | `manifest.json` 入库；`apps.json` 被 gitignore，只作 Release 资产 |
| `scripts/` | 本地发版脚本（签名只在本机做，不进仓库） |
| `.github/` | 定时快照工作流 |
| `docs/` | README 用的截图 |

---

## 本地构建

前置：DevEco Studio、Python 3.12、`gh`。

```bash
# 1) 生成签名配置（签名材料只在本机 ~/.hapstore-signing.env，权限 600）
./scripts/setup-signing.sh

# 2) 自查仓库干净（签名配置、口令、证书都没被跟踪）
./scripts/check-clean.sh

# 3) 日常开发
./scripts/build.sh

# 4) 发版
./scripts/bump.sh patch              # 或 ./scripts/bump.sh 1.2.0
./scripts/sync-rawfile.sh            # 把最新快照拷进包内
./scripts/build.sh
./scripts/release.sh --push          # 归档 + 刷 manifest + 打 tag + 建 Release
```

签名安全：`app/build-profile.json5` 与 `*.p12` / `*.cer` 全部 gitignore，
`.githooks/pre-commit` 二次拦截。仓库里只有 `app/build-profile.example.json5` 占位模板。

`versionCode` 规则 `major×10⁶ + minor×10³ + patch`，**必须单调递增** ——
App 自更新就是靠比这个数字判断有没有新版本的，`bump.sh` 会拒绝回退。

发版产物命名：`HapStore-vX.Y.Z-signed.hap` / `HapStore-vX.Y.Z-unsigned.hap`。
manifest 的 `downloadUrl` 只指向签名版（App 自更新认这个），未签名版另记 `unsignedUrl`。

---

## 快照自动化

`.github/workflows/snapshot.yml` 每天 UTC 04:23 / 16:23（北京 12:23 / 00:23）跑一次，
刻意避开整点（整点排队严重，实测可能延迟 20-30 分钟）。

```bash
gh workflow run snapshot.yml            # 手动触发
gh workflow run snapshot.yml -f force=true   # 忽略 ETag 全量重抓
gh run list --workflow=snapshot.yml
```

设计要点：

- **故意不配 `on: push`** —— 工作流自己会提交 manifest，配了会递归触发。
- 增量状态 `state.json` 走 `actions/cache`，key 必须带 `run_id`：
  静态 key 会让 cache 永不更新、ETag 不再变化、快照从此不再更新。
- `snapshot-latest` 标 prerelease，不抢 `/releases/latest`。
- `snapshot-data` 分支每轮单提交强推，历史永远 1 个 commit，不撑大仓库。
- 图标目录 `sync/icons/*.png` 已入库，命中本地缓存，每轮省 87 次 API。
- 兜底分支那步是 `continue-on-error`，整轮照样绿 —— 汇总步骤会打印两条地址的状态码，看那里。

**60 天停用风险**：GitHub 会在仓库 60 天无活动后停用 schedule。每天提交 manifest 本身
是活动，但别把宝押在上面 —— 家里机器上挂个每周 cron 更稳：

```bash
0 9 * * 1 cd <仓库路径> && ./scripts/keepalive.sh >> /tmp/hapstore-keepalive.log 2>&1
```

需要 PAT 带 `workflow` scope。

CDN 不同步是常态：Release 资产约 1-2 分钟刷新，raw 兜底 5 分钟以上。

---

## 排错速查

| 现象 | 原因 / 处理 |
|---|---|
| 检查更新 404 | Release 还没生成，看 Actions 首轮跑完没有；或 `snapshot-latest` tag 被删了 |
| 「快照格式版本不支持」 | 远端的 `schemaVersion` 超过 App 内的 `SUPPORTED_SCHEMA_VERSION`，升级 App |
| 主地址通但一直 304 | `sync/state.json` 缓存问题，用 `-f force=true` 重跑 |
| 国内下载慢 | 设置里开 `ghfast.top` 镜像（Release 资产可代理，`github.io` 不可） |
| Actions 显示绿但兜底坏了 | 强推 `snapshot-data` 那步是 `continue-on-error`，单独 curl 兜底地址验证 |
| 重装后数据源显示「未配置」 | 旧版本存的空 `sourceUrl` 压住默认值，已在 `read()` 里迁移；仍不行就点「恢复默认地址」 |
| 构建报 symbol table 路径错 | hvigor 缓存残留旧绝对路径，`rm -rf app/entry/build app/.hvigor` 后重建 |
| 覆盖安装后数据源还是旧地址 | 覆盖安装不清数据，旧持久化的 `sourceUrl` 会压过新默认值。卸载重装，或点「恢复默认地址」 |
| push 报 terminal prompts disabled | `gh auth setup-git` 把 gh 凭据接给 git |

---

## App 侧能力边界

写代码前值得知道的两条硬限制：

- **不能静默安装**：SDK 里没有任何安装 API，`INSTALL_BUNDLE` 是 `system_basic` 权限。
  App 自更新只能做到「下载新版 → 跳 InstallGuidePage」，装的那一步必须用户手动确认。
- **没有后台下载**：`request.agent.Mode.FOREGROUND`，`module.json5` 也未声明后台任务权限。
