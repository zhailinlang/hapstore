# HapStore

鸿蒙（HarmonyOS）未上架 HAP 的聚合目录 App，基于 Zitann/HarmonyOS-Haps 的整理，把截止目前（2026-9-30）散落在 87 个 GitHub 仓库 Release 里的
第三方 HAP 聚成一份可浏览、可搜索、可对比版本的快照，装在手机上就能看。

**本仓库不托管、不修改、不重签名任何 HAP 文件。**

---

## 为什么是「目录」而不是「应用商店」

鸿蒙不允许第三方应用静默安装（`INSTALL_BUNDLE` 是 `system_basic` 权限，普通应用拿不到），
所以这个 App 的定位是**发现 → 下载 → 交给系统安装器**，不是应用商店的替代品。
你点安装后会跳到系统的安装确认页，需要手动确认一次。

未上架 ≠ 装不了，只是多一步手动确认。

---

## 免责声明

- 本仓库**不包含任何 HAP 文件**。App 里所有的下载直链都指向各上游项目的官方 Release。
- 本App使用 Workbuddy Vibe Coding而来，本人自测运行正常，当然也可能存在不少bug，如果有使用问题可以提issue。
- 各应用的版权与责任归其原作者。发现侵权内容请提 issue，会尽快下架索引。
- App 不收集、不上传任何用户数据，全部逻辑在本地完成。
- 数据来源：[Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps)（社区维护的清单），
  遵循其自身的许可。

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

---

## 下载安装

最新 HAP 在 [Releases](https://github.com/zhailinlang/hapstore/releases/latest) 里。
每个版本提供两个文件：

| 文件 | 用途 |
|---|---|
| `HapStore-v1.0.0-signed.hap` | 签名版，**绝大多数人下这个**，可直接安装 |
| `HapStore-v1.0.0-unsigned.hap` | 未签名版，供你用自己的证书重签后安装 |

```bash
hdc install HapStore-v1.0.0-signed.hap
```

未签名版**装不上真机**——鸿蒙要求 HAP 必须签名，它只在你不想用本项目证书时才有意义。

首次打开**离线可用**（包里内置了一份快照），联网后点「检查更新」拉最新。
启动默认不自动检查，可在设置里打开。

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

**60 天停用风险**：GitHub 会在仓库 60 天无活动后停用 schedule。每天提交 manifest 本身
是活动，但别把宝押在上面 —— 家里机器上挂个每周 cron 更稳：

```bash
0 9 * * 1 cd <仓库路径> && ./scripts/keepalive.sh >> /tmp/hapstore-keepalive.log 2>&1
```

需要 PAT 带 `workflow` scope。

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

---

## 许可

MIT，见 [LICENSE](LICENSE)。

数据来源 [Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps) 遵循其自身许可。
