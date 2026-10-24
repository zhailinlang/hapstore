# 维护者笔记

只想用 App 的话看 [README.md](README.md)。这份是给自己看的：怎么构建、怎么发版、快照怎么自动更新、出问题怎么排查。

**踩坑记录与验证方法**单独整理在 [docs/DEV-EXPERIENCE.md](docs/DEV-EXPERIENCE.md) ——
模拟器联调、沙箱文件读写、toast 抓取、失败分支怎么造、设置项 schema 迁移等，
这份只讲「是什么」，那份讲「为什么」和「怎么办」。

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
| 构建报 delete 失败 Operation not permitted | 文件带 macOS `com.apple.provenance` 扩展属性，`rm -rf app/entry/build` 后重建 |
| 模拟器 hdc 一直 `[Empty]` | 启动 emulator 必须显式 `-hdcPort 10001`，且 `instancePath` 指向 `deployed` 根目录。详见 [docs/DEV-EXPERIENCE.md](docs/DEV-EXPERIENCE.md) |
| 改不了设备上的沙箱文件 | shell 无写权限、`sed` 不支持 `-i`、设备无 python3 → 用 `hdc file send` 整文件覆盖 |
| 截图抓不到 toast | toast 只活 ~1.6 秒，要在**设备端**循环 `snapshot_display` 连拍；判断有没有弹看 hilog 的 `AceOverlay: Toast node mount` |

---

## App 侧能力边界

写代码前值得知道的几条硬限制：

- **不能静默安装**：SDK 里没有任何安装 API，`INSTALL_BUNDLE` 是 `system_core` 权限。
  App 自更新只能做到「下载新版 → 跳 InstallGuidePage」，装的那一步必须用户手动确认。
- **但可以走 hdc 调试通道**：把 HAP 通过 want 转交给已授权调试通道的装机工具
  （如小白调试助手 `com.xiaobai.hap_installer`），由它完成安装。
  见 `service/InstallerBridge.ets`，不占任何安装权限，也不碰签名。
- **没有后台下载**：`request.agent.Mode.FOREGROUND`，`module.json5` 也未声明后台任务权限。

---

## 数据结构变更记录

| 变更 | 字段 | 说明 |
|---|---|---|
| schemaVersion 2 | `hapAssets` / `otherAssets` | 初始结构，`otherAssets` 装的是非 HAP 文件 |
| 新增（未升 schema） | `hapZipAssets` | 装着 HAP 的 zip 包。`split_assets` 从 `otherAssets` 里分出来，App 侧解压后装机 |
| 新增（未升 schema） | `AssetInfo.isZip` | 标记该资产是压缩包，UI 上显示「下载后自动解压安装」 |
| 新增（未升 schema） | `ReleaseInfo.hapZipAssets` | 同上，按 release 分别记录 |

**未升 schemaVersion 的原因**：新字段全是可选，老 App 读新数据时解析不出 `hapZipAssets`，
会当成没有 zip —— 行为退回到旧版本，不会崩。等 App 侧也发新版后再考虑升 schema。

### 离线重跑分类

`sync/sync.py` 的资产分类规则改了以后，不用等 4 分钟全量重抓：

```bash
python3 sync/backfill_zip.py
```

它读 `state.json` 里已缓存的原始资产，离线重跑一遍 `split_assets` 再重写 `apps.json`。
**前提**：`state.json` 里存的资产字段名是 `downloadUrl`，而 GitHub API 原始字段是
`browser_download_url` —— `split_assets` 两种都认，但自己写脚本处理 state 时别踩这个坑。

---

## zip 包的三种结构（实测）

| 包 | 结构 | 处理 |
|---|---|---|
| `entry-default-20260516.zip`（HiSH） | zip → 直接是 `.hap` | 解压即得 |
| `CanPlayer.zip` | zip → `.app` → **.app 本身是 zip** → `entry-default.hap` | 递归解两层 |
| `MindustryArk-*-payload.zip` | payload 包 | 同上，按 `.hap` 找 |

`service/ZipExtractor.ets` 负责递归解包（最多 3 层），碰到 `.app` 会再解一次。

