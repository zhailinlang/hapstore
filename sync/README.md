# hapstore-sync

把 [Zitann/HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps) 的 `apps.yaml`
同步成鸿蒙 App 可直接消费的 `apps.json`（含最近两次 Release 的 HAP 直链 + 打标结果）。

## 用法

```bash
export GITHUB_TOKEN=ghp_xxx      # 可选；没有则只能用网页抓取模式
python3 sync.py                  # 增量同步（推荐）
python3 sync.py --force          # 忽略 ETag，全量重抓
python3 sync.py --limit 40       # 本轮最多处理 40 个仓库
python3 sync.py --mode html      # 只用网页抓取（无 Token 时的兜底）
python3 sync.py --mode api       # 只用 GitHub API（需要 Token）
python3 sync.py --workers 6      # 网页模式并发数（默认 6）
```

实测：87 个仓库走网页模式、并发 6，约 4 分钟跑完（串行要 15 分钟以上）。

## 两条数据通道

| 通道 | 触发条件 | 配额 | 体积信息 | 并发 |
|---|---|---|---|---|
| API | 有 `GITHUB_TOKEN` 或剩余配额 > 2 | 1000/小时（Actions 里的 `GITHUB_TOKEN`）、5000/小时（个人 PAT）、60/小时（未鉴权） | 有 | 串行（避免触发限流） |
| 网页抓取 | 无配额 / 显式 `--mode html` | 无硬限流 | 有（HEAD 探测） | 默认 6 线程 |

网页抓取的三个关键点（都踩过坑）：
1. GitHub 的 release 资源列表是异步加载的，必须单独请求 `/releases/expanded_assets/{tag}` 片段页
2. 下载链接的大小写可能与 `owner/repo` 不一致，正则不能按原仓库名 escape
3. **releases 列表页的出现顺序 ≠ 发布时间顺序**（置顶、pre-release 会打乱）。
   所以第一个 release 一律以 `/releases/latest` 的 302 重定向结果为准，其余才按列表页顺序补齐

## 打标（tagger.py）

规则引擎，离线零成本，输出三个筛选维度：

- `funcType` 功能类型（单选）：影音播放 / 网络代理 / 社区社交 / 阅读漫画 / 游戏启动 /
  开发工具 / 系统工具 / 效率工具 / 浏览器 / 其他
- `deviceTypes` 设备类型（多选）：手机 / 平板 / 电脑 / 穿戴
- `tags` 属性标签（多选）：自托管 / 第三方客户端 / 多端适配 / Flutter / 免root

关键词表是针对这 87 个应用的真实描述人工调过的，实测 87 个里只有 4 个落到「其他」。
`tagger.py` 里预留了 `tag_with_llm()` 占位——将来换成真 LLM 打标时，
只要输出结构（funcType / deviceTypes / tags）不变，App 侧无需任何改动。

## 图标（icons.py）

每个应用抓一个应用图标，**以 base64 data URL 内嵌进 apps.json 的 `iconUrl` 字段**
（`data:image/png;base64,...`），不走网络图片加载 —— 规避 raw.githubusercontent.com
在国内的可达性问题，App 离线也能显示。

- 抓取逻辑：`git/trees/HEAD?recursive=1` 列仓库文件 → 按优先级匹配
  （`AppScope/.../app_icon.png` > `**/media/icon|logo.png` > `assets/...`，排除
  screenshot/layered 前景背景等干扰项）→ raw 下载。
- 兜底：仓库里没有合适图标时用作者头像（`github.com/{owner}.png`）。
- 处理：居中裁方 → 64×64 → 有透明通道垫白底 → 256 色 PNG，平均 1.8 KB/个。
- 缓存：落盘到 `icons/{owner}__{repo}.png`，重跑不重复下载；
  `--force-icons` 强制刷新，`--no-icons` 跳过本阶段。
- 实测 87/87 命中，其中约 8 个是头像兜底。apps.json 总体积 316 KB → 516 KB。
- App 侧：`Image(dataUrl)` 原生支持 base64（API 26 起还支持通配 MIME）；
  无图标时显示首字母色块。

## 产物

`data/apps.json`，schemaVersion 2（被 `.gitignore` 排除，不入库，只作 Release 资产分发）：

```jsonc
{
  "schemaVersion": 2,
  "generatedAt": "2026-09-29T18:20:00+08:00",
  "stale": false,               // true = 本轮有失败，部分数据是旧值
  "totalApps": 87,
  "availableApps": 68,          // status=ok 的数量
  "categories": [{
    "id": "c1",
    "name": "一次开发，多端部署",
    "apps": [{
      "id": "owner/repo",       // 小写，稳定主键
      "name": "LNGA",
      "desc": "…",
      "category": "…",
      "owner": "…", "repo": "…",
      "repoUrl": "…", "releaseUrl": "…",
      "iconUrl": "",
      "updatedAt": "2026-09-26",
      "status": "ok|no_release|no_hap|fetch_error|unknown",

      // 最近两次发布，按新→旧排列；[0] 即官方 latest
      "releases": [{
        "tag": "1.2.5", "name": "…", "publishedAt": "…",
        "hapAssets": [{ "name": "x.hap", "size": 4120806, "downloadUrl": "…" }],
        "otherAssets": []
      }],

      // 以下为兼容字段，等价于 releases[0]，列表页/卡片按最新一次渲染
      "release": { "tag": "1.2.5", … },
      "hapAssets": […],
      "otherAssets": [],

      // 打标结果
      "funcType": "阅读漫画",
      "deviceTypes": ["手机"],
      "tags": ["第三方客户端", "多端适配"]
    }]
  }],
  // 维度统计，UI 直接拿去渲染筛选项，不必自己遍历全量
  "dimensions": {
    "funcType":   [{ "name": "影音播放", "count": 22 }],
    "deviceType": [{ "name": "手机", "count": 41 }],
    "tag":        [{ "name": "多端适配", "count": 45 }]
  }
}
```

## 增量策略

- `apps.yaml` 用 `If-None-Match`，304 直接复用
- 每个仓库带 ETag，304 零成本（仅 API 模式；网页模式无 ETag 概念，每轮全抓）
- 单仓库失败保留上次结果并置 `stale=true`，连续 3 次才标 `fetch_error`
- **每处理 20 个仓库落盘一次 state**：抓取慢，中途挂掉不至于全丢

写盘注意：`save_state()` 和 `apps.json` 都是**直接覆盖写**，不用 `tmp + os.replace`。
后者需要先 unlink 已存在的文件，在受限环境下会被拒绝（`rename overwrite refused`），
实测导致跑了 15 分钟的全量抓取在最后一刻全丢。

## 自动化（GitHub Actions）

本机不跑定时同步，全部交给 `.github/workflows/snapshot.yml`：

```bash
# 手动触发（force=true 忽略 ETag 全量重抓）
gh workflow run snapshot.yml -f force=true

# 查看最近几次运行
gh run list --workflow=snapshot.yml
```

工作流每天 UTC 04:23 / 16:23（北京 12:23 / 00:23）跑一次，产出两个发布物：

| 产出 | 去向 | 用途 |
|---|---|---|
| `data/apps.json` | Release 滚动资产 `snapshot-latest` | 主地址，URL 永久稳定，可被 ghfast.top 等镜像代理 |
| `data/apps.json` + `manifest.json` | `snapshot-data` 分支强推 | raw 兜底地址，单提交无历史膨胀 |

`snapshot-latest` **必须标 prerelease**，否则会抢走 `/releases/latest`（那是 App 自更新用的）。

增量状态 `state.json` 不入库，走 `actions/cache` 续命：key 必须带 `run_id`，
静态 key 会让 cache 永不更新、ETag 不再变化、快照从此不再更新。
