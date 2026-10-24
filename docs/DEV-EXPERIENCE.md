# 开发经验沉淀

这份文档记录的是**踩过的坑**和**验证方法**——不是代码结构说明（那个看源码就行），
也不是使用说明（那个看 README）。

每条都尽量写清「现象 → 根因 → 怎么办」，方便下次直接查。

---

## 一、模拟器联调：DevEco 模拟器的 hdc 不通

### 现象

DevEco Studio 里模拟器窗口能正常打开、能看见界面，但命令行 `hdc list targets` 恒为 `[Empty]`，
`hdc install` 直接失败。

### 根因

模拟器实例的配置里 `hw.hdc.port` 是 `notset`，而且**后台启动模拟器不会自动建立 hdc 通道**。
必须在启动时显式指定端口。

### 怎么办

```bash
cd ~/.Huawei/Emulator/deployed
/Applications/DevEco-Studio.app/Contents/tools/emulator/emulator \
  -start "Mate 90 Pro" \
  -instancePath "/Users/maxzhai/.Huawei/Emulator/deployed" \
  -imageRoot "/Users/maxzhai/Library/Huawei/Sdk" \
  -hdcPort 10001
```

然后：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC tconn 127.0.0.1:10001     # → Target is connected
$HDC list targets              # → 127.0.0.1:10001
```

**三个坑叠在一起**：

| 坑 | 说明 |
|---|---|
| `instancePath` | 必须指向 `~/.Huawei/Emulator/deployed` **根目录**，不是具体实例目录 |
| `-hdcPort` | 不给就没有 hdc 通道，`hdc list targets` 永远空 |
| 前台运行 | 命令一结束模拟器就被杀，必须后台跑（`run_in_background` 或 `nohup &`） |

---

## 二、模拟器联调：改设备端沙箱文件

### 现象

想改设备上的 `settings.json`（比如清掉 `lastCheckAt` 以触发启动自动检查），各种写法都失败：

```
/bin/sh: sed: no temp file          # 设备的 sed 不支持 -i
/bin/sh: can't create .../t.txt: Permission denied   # 沙箱目录 shell 无写权限
/bin/sh: python3: inaccessible or not found          # 设备没有 python3
```

### 根因

`hdc shell` 起的是普通用户 shell，**对 App 私有沙箱目录没有写权限**；
而且鸿蒙设备的 shell 工具链比桌面精简得多。

### 怎么办

**`hdc file send` 是唯一可行的写入通道**（走的是文件传输服务，不受 shell 权限限制）：

```bash
# 本地准备好完整 JSON，再整文件覆盖过去
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC file send settings.json /data/app/el2/100/base/com.max.hapstore/haps/entry/files/settings.json
```

注意是**整文件覆盖**，不是增量修改——所以本地要先读回原文件内容、改好、再发。

其他注意：
- 沙箱路径形如 `/data/app/el2/100/base/<bundleName>/haps/entry/files/`
- `hdc file recv <deviceDir> <localDir>` 需要目标目录**不存在**（否则报 `/tmp exist, not directory`）

---

## 三、模拟器联调：抓 toast / 瞬时 UI

### 现象

想截图确认启动时的 toast 提示，截出来什么都没有——因为 `promptAction.showToast` 的
toast 只存活约 **1.6 秒**，而 `hdc shell snapshot_display` + `hdc file recv`
一来一回就要好几秒，永远错过。

### 怎么办

**在设备端连拍**，别在主机端往返：

```bash
# 设备端循环截图，文件名带毫秒时间戳
$HDC shell "for i in $(seq 1 40); do snapshot_display -f /data/local/tmp/ts/$(date +%S_%3N).jpeg; done"

# 一次性拉回全部
$HDC file recv /data/local/tmp/ts /tmp/tsdir
```

再按时间戳排序，找出 toast 出现的那一帧。

> **副作用**：连拍期间设备会持续截屏，可能抢占前台焦点（我遇到过一次被浏览器抢走画面）。
> 触发前先 `aa force-stop` 目标应用，必要时用 `aa start` 拉回来。

### 补充：hilog 能过滤应用自己的日志

之前误以为 hdc 抓不到应用日志，其实能：

```bash
$HDC shell "hilog -x" | grep "com.max.hapstore/HapStore"
```

TAG 是 `HapStore`，DOMAIN `0x1A5B`。系统层面还能看到 toast 的挂载与销毁：

```
AceOverlay: Toast node mount to root node      # toast 已弹出
AceOverlay: pop toast enter                     # 开始退出
AceOverlay: toast remove from root              # 已移除
```

**日志比截图可靠**——判断「有没有弹提示」优先看这三条，截图只用来确认文案长什么样。

---

## 四、模拟器联调：读布局拿真实坐标

### 现象

按截图上的像素位置点击，经常点错地方（点到别的 Tab 或链接），
因为截图是缩放过的，跟设备真实分辨率对不上。

### 怎么办

用 `uitest dumpLayout` 导出布局 JSON，从 `attributes.bounds` 反算真实坐标：

```bash
# 注意：要 -p 存文件。直接重定向 stdout 会因为混了提示行而 JSON 解析失败
$HDC shell "uitest dumpLayout -p /data/local/tmp/lay.json"
$HDC file recv /data/local/tmp/lay.json /tmp/lay2/lay.json
```

然后递归遍历找出目标控件：

```python
def walk(n):
    a = n.get('attributes', {})
    if a.get('text') in ('更新', '应用', '设置'):
        print(a.get('text'), a.get('bounds'))
    for c in (n.get('children') or []):
        walk(c)
```

拿到 bounds 后取中心点：

```bash
$HDC shell "uitest uiInput click 639 2636"   # 更新 Tab
```

---

## 五、构建：macOS 扩展属性导致删不掉中间产物

### 现象

```
Failed to delete .../main_pages.json, Operation not permitted
```

### 根因

文件带 macOS 的 `com.apple.provenance` 扩展属性（来自「下载的 App」来源标记），
hvigor 内部调 restool 删除时被系统拒绝。普通 `rm -f` 却能删掉。

### 怎么办

**构建前先清干净**：

```bash
rm -rf app/entry/build && ./scripts/build.sh
```

同类问题还有：hvigor 缓存残留旧绝对路径导致 symbol table 路径报错，
需要 `rm -rf app/entry/build app/.hvigor`。

---

## 六、功能设计：怎么测「失败分支」

### 坑

想测「更新失败提示原因」，把 `sourceUrl` 改成不存在的地址——**测不出来**。
因为 `RemoteStoreService` 有 raw 兜底逻辑，主地址 404 会自动切到
`ALT_SOURCE_URL`（raw.githubusercontent.com），照样拉回来。

### 怎么办

要触发失败，得绕过兜底。三种可用手法：

| 手法 | 效果 |
|---|---|
| 指向**返回 200 但内容不是 JSON** 的地址 | 解析失败 → `Unexpected Text in JSON: Invalid Token` |
| 指向**域名解析失败**的地址 | 网络错误 |
| 指向**格式版本不兼容**的快照 | `快照格式版本为 N，当前 App 只支持 M` |

**验证失败提示时，「看不出原因」本身就是 bug**——
`outcomeText()` 必须把 `reason` 拼进文案，不能只说「更新失败」。

---

## 七、功能设计：结果模型的收敛

「远端快照检查」和「App 自身版本检查」是两条链路，但用户视角是一件事。
早期版本两条链路各有一套返回结构，UI 层要写两套分支。

### 收敛做法

抽一个统一的结果模型：

```typescript
// model/UpdateOutcome.ets
export const CHECK_OK: string = 'ok';
export const CHECK_UPDATED: string = 'updated';
export const CHECK_FAILED: string = 'failed';

export interface CheckOutcome {
  snapshot: SnapshotCheckOutcome;
  self: SelfUpdateOutcome;
  selfVersionName: string;
  notable: boolean;      // 有没有值得打断用户的变化
}
```

再配一个编排中心（`service/UpdateCenter.ets`）把两条链路串起来，
对外只暴露三个方法：

| 方法 | 用途 |
|---|---|
| `runFullCheck(showTips)` | 手动「检查更新」按钮 —— 一次跑完，弹结果 |
| `autoCheckOnLaunch()` | 启动自动检查 —— 同一套逻辑，但只在值得打扰时才弹 |
| `outcomeText(outcome)` | 结果 → 文案（成功给结论，失败给原因） |

**这样「手动点」和「启动自动跑」永远不会跑偏**——它们共用同一个实现。

### 交互上的关键取舍

「检查更新」按钮原本是两段式：先看差异，再点「应用更新到本机数据」。
改成**一次点击跑完全流程**（拉取 → 比对 → 写入生效），用户不用理解中间态。

但**启动自动检查不能这么激进**——如果每次开 App 都弹「已是最新」，就是骚扰。
所以用 `notable` 标志分流：

```typescript
// 有更新才主动提示；失败也提示原因，用户能知道为什么没更新
if (outcome.notable || outcome.snapshot.status === CHECK_FAILED) {
  UpdateCenter.showOutcomeTips(outcome);
}
```

「已是最新」静默通过，「有更新」和「失败」才弹。

---

## 八、功能设计：设置项的语义变更要升 schema

### 坑

给已有的设置项改语义（比如 `autoCheckOnLaunch` 从「只在配了数据源时生效」
改成「打开 App 就自动检查」），老用户设备上的旧值还在，
按旧语义解释会得出错误行为。

### 怎么办

`SettingsData.schemaVersion` 加版本号，写迁移逻辑：

```typescript
const storedSchema: number = parsed.schemaVersion ?? 1;
base.schemaVersion = storedSchema;
// v2 起 autoCheckOnLaunch 的语义变了，旧的（没配数据源就不查）统一迁到新的
base.autoCheckOnLaunch = storedSchema >= 2 ? (parsed.autoCheckOnLaunch ?? true) : true;
if (storedSchema < 2) {
  base.schemaVersion = 2;
  this.persist();   // 迁移结果要落盘，否则下次又走老分支
}
```

**要点**：迁移后必须 `persist()`，否则每次启动都重新迁移一遍，
而且用户手动改过的新值会被老数据反复覆盖。

---

## 九、Git：全局代理失效

### 现象

```
Failed to connect to 127.0.0.1 port 58317
```

### 根因

`~/.gitconfig` 里的 `http.proxy` 指向的端口已经失效（环境代理实际在另一个端口）。
`curl` 走同一代理正常、git 不行，是因为两者读的代理配置来源不同。

### 怎么办

**单次覆盖**，不改全局配置：

```bash
GIT_CONFIG_COUNT=2 \
GIT_CONFIG_KEY_0=http.proxy  GIT_CONFIG_VALUE_0=http://127.0.0.1:<真实端口> \
GIT_CONFIG_KEY_1=https.proxy GIT_CONFIG_VALUE_1=http://127.0.0.1:<真实端口> \
git push origin main
```

> 长期方案是改 `~/.gitconfig`，但如果代理端口经常变，每次覆盖更省事。

### 非快进推送

远端可能有新提交（尤其是 Actions 自动提交的 manifest 指针）：

```bash
git fetch origin
git merge origin/main --no-edit
git push origin main
```

`origin/snapshot-data` 是强推（force update），每次只有一个 commit，属正常现象。

---

## 十、验证方法论：怎么确认「真的跑到了」

### 原则

**不要靠截图猜，要靠可观测的状态变化。**

本次几个关键结论都是这么证实的：

| 要证明的事 | 观测点 |
|---|---|
| 启动自动检查执行了 | `settings.json` 里 `lastCheckAt` 从 `0` 变成真实时间戳 |
| 数据真的写进本机了 | 首页应用总数从 108 变成 109 |
| 失败分支走到了 | hilog 里的 `快照检查失败：<具体原因>` |
| toast 真的弹了 | hilog 里的 `AceOverlay: Toast node mount` |

### 构造测试数据的通用手法

要测「有更新」的分支，需要一个**比线上多几个应用**的快照。做法：

1. 从 `app/entry/src/main/resources/rawfile/apps.json` 读一份真实结构
2. 复制并改几个字段（加一个应用、改一个版本号）
3. **起一个本地 HTTP 服务**指向它：
   ```bash
   python3 -m http.server 8899 --bind 0.0.0.0
   ```
4. 把 App 的 `sourceUrl` 指到 `http://<本机IP>:8899/xxx.json`
   （模拟器能访问宿主机 IP，**不能用 localhost**）

测完记得恢复 `sourceUrl` 并关掉本地服务。

---

## 十一、其它零散经验

- **ArkTS 的 `zsh` 数组展开**：可选参数必须先拼成数组再展开。
  `MANIFEST_ARGS+=(--asset-unsigned "$F")` 后用 `"${MANIFEST_ARGS[@]}"`，
  否则 `--asset-unsigned /path` 会被当成一个 argv 元素传进去。
- **macOS sed 不支持懒惰量词**：`sed -E 's#x#+?#y#'` 会报错，
  改用 `sed -E 's#x*#y#'`（BSD sed）。
- **`@kit.ArkUI` 的 `promptAction.showToast`** 需要在 UI 上下文中调用，
  从后台 service 里调要确认调用链上有 UI 实例。
- **AppStorage / @StorageLink / @StorageProp 的分工**：
  `setOrCreate` 写全局、`@StorageLink` 双向同步、`@StorageProp` 单向读。
  跨组件通知数据变更用 `storeEpoch` 这类「版本号计数器」最省事——
  订阅方看到数字变了就重新读数据。
- **下载文件名补版本号**：`entry-default.hap` → `entry-default-1.2.5.hap`，
  避免新旧版本互相覆盖。
- **zip 包有三种结构**（实测）：
  - `zip → .hap`（直接解）
  - `zip → .app →（.app 本身是 zip）→ .hap`（递归解两层）
  - `zip → payload 包 → .hap`

---

## 附：本次开发涉及的新增/修改文件

| 文件 | 说明 |
|---|---|
| `service/UpdateCenter.ets`（新增） | 更新编排中心，两条检查链路的统一出口 |
| `model/UpdateOutcome.ets`（新增） | 统一结果模型 |
| `service/ZipExtractor.ets`（新增） | zip 包递归解包 |
| `service/InstallerBridge.ets`（新增） | 经 hdc 调试通道把 HAP 转交给小白调试助手安装 |
| `components/UpdatesTabView.ets` | 一键检查全流程，移除差异卡片 |
| `pages/Index.ets` | 启动自动检查入口 |
| `model/SettingsData.ets` / `service/SettingsStore.ets` | schema v1→v2 迁移 |
| `pages/DetailPage.ets` | 打开即下载、zip 支持 |
| `components/AppsTabView.ets` | 排序、搜索修复 |
