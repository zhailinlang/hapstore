# 调试助手能力集成调研 v2（更正版）

> ⚠️ 本文取代 `DEBUG-HUB-PROPOSAL.md`。v1 基于「鸿蒙三方 App 不能安装 HAP」的判断，已被实证推翻，结论有误。

---

## 0. 我错在哪（先认错，再给结论）

v1 里的四条判断，经 `likuai2010/auto-installer`（小白调试助手）实证**全部站不住**：

| v1 的错误判断 | 实际情况 |
|---|---|
| ❌「三方 App 无法安装 HAP，INSTALL_BUNDLE 是 system_core」 | ✅ 严格说：**无法用应用框架 API 安装**，但可以**走 hdc 调试通道**。这条路不占用任何安装权限 |
| ❌「App 内自建 hdc 客户端是死路（RSA 鉴权绕不过）」 | ✅ 可行。hdc 是**开源**的（OpenHarmony `developtools_hdc`），编译进 App 即可；鉴权不用绕——**用户在系统弹窗点一次「始终允许使用本机调试」** |
| ❌「证书必须由 AGC 签发，本地无法签名」 | ✅ 可以本地重签名。它内置了自己的 `p12` / `cer` / `p7b`，配 `libsigner.so` 在手机上完成签名 |
| ❌「鸿蒙无线调试没有配对码，只有 IP:端口」 | ✅ 有配对码。开发者选项 → 无线调试 → 使用配对码配对设备 → 显示 **IP + 端口 + 6 位配对码** |

**根本性认知错误**：我把「应用框架内的权限」当成了唯一通道，漏掉了「**调试通道是一条平行于权限系统的独立通道**」。

---

## 1. auto-installer 的真实机制（解包实证）

### 1.1 它是什么

- 仓库：`likuai2010/auto-installer`，3031 stars，README 自述「**基于开源 OpenHarmony 项目的 Hdc 工具**」
- 鸿蒙版包名：`com.xiaobai.hap_installer`，Flutter 应用（非 ArkTS）
- 仓库里**没有源码**（只有 README + 收款码），但 release 里的 HAP 可以解包取证

### 1.2 解包拿到的硬证据

`hap_installer-harmonyos-3.1.0.hap`（48MB）内部：

```
ets/modules.abc
libs/arm64-v8a/libhdc_napi.so      ← 7MB，hdc 全套编译进 App
libs/arm64-v8a/libsigner.so        ← 签名库
libs/arm64-v8a/libgo_signer.so
libs/arm64-v8a/libunhap.so         ← HAP 解包
libs/arm64-v8a/libflutter.so
resources/rawfile/flutter_assets/assets/store/xiaobai.p12     ← 作者证书
resources/rawfile/flutter_assets/assets/store/xiaobai-debug.cer
resources/rawfile/flutter_assets/assets/store/xiaobai-debug.p7b
resources/rawfile/flutter_assets/assets/ohos/auto_installer.hap
```

**a) 权限声明**（`module.json`）——决定性证据：

```json
"requestPermissions": [
  {"name": "ohos.permission.INTERNET"},
  {"name": "ohos.permission.KEEP_BACKGROUND_RUNNING"},
  {"name": "ohos.permission.READ_CALENDAR"},
  {"name": "ohos.permission.WRITE_CALENDAR"}
]
```

**没有 `INSTALL_BUNDLE`**。它不是用 `bundleInstaller` API 安装，而是走 hdc。

**b) NAPI 导出符号**（`libhdc_napi.so`）：

```
HdcExtConnect  HdcExtInstall  HdcExtUninstall  HdcExtShell
HdcExtListTargets  HdcExtFile  HdcExtFport  HdcExtStart  HdcExtKill
```

整个 hdc 命令集暴露给 Flutter 层调用。

**c) 鉴权没被绕过**：符号里有 `HdcAuth::AuthVerify`、`HdcAuth::AuthSign`、`RsaSignAndBase64`，还有 `Unauthorized` 错误串——走的是标准 RSA 挑战响应。

**d) 它注册为 .hap 的打开方式**（`module.json` skills）：

```json
"skills": [{
  "uris": [
    {"scheme":"file","linkFeature":"FileOpen","type":"openharmony.package"},
    {"scheme":"file","utd":"general.text"}
  ],
  "actions": ["action.system.home","ohos.want.action.sendData","ohos.want.action.viewData"]
}],
"querySchemes": ["xiaobai"]
```

**e) 用户授权环节**：官方教程第 7 步「**点击始终允许使用本机调试**」。这就是系统弹出的调试授权对话框，用户点「始终允许」后本机客户端公钥进入信任列表，此后不再询问。

### 1.3 完整机制还原

```
首次：电脑 hdc install 把小白调试助手装进手机（鸿蒙版无法自装）
     ↓
之后（全在手机上）：
  1. 设置 → 开发者选项 → 无线调试 → 使用配对码配对设备 → 得到 IP:端口 + 6位配对码
  2. 打开小白调试助手，填本机 IP:端口（或配对码）
  3. 系统弹「允许调试？」→ 用户点「始终允许」← 关键：授权在这里完成
  4. App 内 hdc client 连本机 hdcd，鉴权通过
  5. 选 HAP → libsigner 按需重签名 → hdc install 装上
```

**为什么能「自己连自己」**：用户就在手机跟前，系统弹窗他自己点允许。不需要任何特权，也不需要绕过鉴权。

官方 FAQ 佐证：
> 「有一种玩法是：利用这个方法，先给鸿蒙手机装上鸿蒙版的『小白调试助手』。一旦鸿蒙手机自己有了助手，以后就可以直接在鸿蒙手机上操作，不需要安卓手机做中转了。」

---

## 2. 对 HapStore 意味着什么

**好消息**：HapStore 和用户的关系，跟小白调试助手鸿蒙版**完全一样**——都是「用户第一次用电脑装进来，之后希望全在手机上完成」。所以这条路对 HapStore 同样成立。

**而且 HapStore 有一个巨大优势**：它收录的 68 个可下载 HAP，绝大多数是上游 Release 里**已经签好名**的包。**HapStore 只需要 hdc 通道，不需要签名能力**——`libsigner` 那一整套可以直接砍掉。这大幅降低了实现门槛。

---

## 3. 修正后的可行性矩阵

| 能力 | v1 判断 | 修正后 | 说明 |
|---|---|---|---|
| 手机上完成 HAP 安装 | ❌ | ✅ **可行** | 内置 hdc client，走调试通道，用户授权一次 |
| 批量安装 | ⚠️ | ✅ **可行** | hdc install 循环即可 |
| 卸载应用 | ❌ | ✅ **可行** | `HdcExtUninstall` |
| 本地 HAP 扫描管理 | ✅ | ✅ | 不变 |
| 已装应用全量列表 | ❌ | ❌ | 仍不可行（隐私限制），除非 hdc shell `bm dump -a`——**这条路可能通，待实测** |
| 查看系统日志 | ❌ | ⚠️ **可能可行** | 有 hdc 就能 `hilog`，理论上可行 |
| 执行 shell 命令 | ❌ | ⚠️ **可能可行** | `HdcExtShell`，但做成产品功能要慎重 |
| 本地重签名 | ❌ | ✅ 可行 | 但我们**不需要**，且不建议做 |

---

## 4. 三条路线

### 路线 1（重）：HapStore 自带 hdc，闭环自持

把 OpenHarmony `developtools_hdc` 源码交叉编译成 arm64 `.so`，NAPI 封装 connect / install / uninstall / listTargets，ArkTS 层做引导与调用。

- **可行性**：✅ 有实证（7MB so，人家做出来了）
- **工作量**：**3–5 天**（熟悉 C++ 交叉编译）到 **1–2 周**（不熟）
  - hdc 源码拉通 + 编译链打通：1–2 天
  - NAPI 封装 + ArkTS 联调：1–2 天
  - 引导流程（开无线调试 → 配对码 → 授权）UI：1 天
- **风险**：
  - hdc client 与设备系统版本要匹配，系统升级可能失效
  - 依赖用户手动开无线调试 + 手动授权，引导做不好就劝退
  - 华为对「App 自带 hdc」的态度未知，理论上属于公开能力，但不排除收紧
  - 应用的「只申请两个权限」卖点会破功（需加 `KEEP_BACKGROUND_RUNNING`）
- **收益**：HapStore 从「目录 + 下载」升级为「**目录 + 下载 + 安装**」闭环，价值质变

### 路线 2（轻）：与小白调试助手联动（推荐先做）

小白调试助手已声明接收 `ohos.want.action.viewData` / `sendData` + `scheme: file` + `type: openharmony.package`。

**HapStore 下载完 HAP → 构造 want 把文件转交给他 → 由他完成安装。**

- **可行性**：✅ 标准鸿蒙应用间协作机制，无特权需求
- **工作量**：**1 天内**
- **收益**：HapStore 保持干净（不加权限、不内置证书、不重签名），体验上「下载 → 一键装机」闭环成立
- **代价**：依赖用户已装小白调试助手

### 路线 3（中）：路线 2 + 完整引导

在路线 2 基础上加：
- 检测小白调试助手是否已安装（用 `GET_BUNDLE_INFO` 单项查询，**normal 权限，可行**）
- 未安装 → 给下载链接 + 图文引导（含无线调试、配对码步骤）
- 已安装 → 一键转交
- 附带「签名有效期提醒」

推荐：**路线 3 先做（1–2 天），验证用户真实需求后再决定要不要投入路线 1。**

---

## 5. 我的建议：先轻后重

**不要一上来就移植 hdc。** 3–5 天的投入，赌的是「用户真的需要在 HapStore 里完成安装」。先用 1–2 天的路线 3 验证：

- 如果「一键装机」按钮点击率高 → 说明需求真实，再投路线 1，把依赖去掉、闭环自持
- 如果点击率低 → 说明用户其实习惯用电脑装，省下 3–5 天

**同时**：路线 1 的技术风险可以提前用 0.5 天 spike 摸底——把 `developtools_hdc` 拉下来，看能否在 DevEco 里编译出 arm64 so。这一步决定路线 1 到底是 3 天还是两周。

---

## 6. 必须先验证的项

| # | 验证内容 | 影响 |
|---|---|---|
| 1 | 能否把 `developtools_hdc` 编译成鸿蒙 arm64 `.so` | 路线 1 生死 |
| 2 | HapStore 能否通过 want 把 HAP 转交给小白调试助手（需 `FLAG_AUTH_READ_URI_PERMISSION` 或先存公共目录） | 路线 2/3 生死 |
| 3 | `GET_BUNDLE_INFO` 能否单项查询 `com.xiaobai.hap_installer` | 路线 3 的检测逻辑 |
| 4 | hdc client 连本机 hdcd，真机是否弹授权框、勾选「始终允许」后是否免重复 | 路线 1 体验 |
| 5 | hdc 拿到通道后能否 `bm dump -a` 拿已装应用列表 | 额外惊喜：可做「已安装」标记 |

---

## 7. 关于签名：两种模式与风险

### 7.1 先厘清事实（容易被误读）

auto-installer **同时存在两种签名模式**：

| 模式 | 证据 | 风险 |
|---|---|---|
| 默认：内置**作者**证书 | 解包 `assets/store/xiaobai.p12` / `.cer` / `.p7b` / `.csr` | 高：替第三方 HAP 背书的是作者，且他的私钥随包分发 |
| 可选：**用户自备**证书 | README「支持自定义证书更换」；UI 可换 p12/csr/别名/密码 | 中低：签名责任回到用户自己 |

「用户自己申请开发者账号、用自己的证书签」这条路**确实存在，且风险显著低于内置作者证书**——签名责任、证书归属都在用户身上，不牵连工具作者。

### 7.2 但「用户自签」不是零风险

即便用用户自己的证书，仍有四条实质风险：

1. **你给别人的代码背书。** 用自己的开发者证书签了第三方 HAP，签名链上写的是你。这个包日后被发现有恶意行为，追溯到你。
2. **私钥进了手机。** p12 私钥存在 App 沙箱里，设备被物理攻破或备份泄露，开发者私钥就丢了——别人可以拿你的身份签任何应用。
3. **可能违反开发者协议。** 华为调试证书的用途是「签名自己开发的应用做调试」，批量给他人应用签名，账号有被风控的可能。
4. **有效期是个坑。** 未实名约 14 天、实名约 180 天。到期后用它签的所有应用**集体失效**，全部要重装。

### 7.3 HapStore 的取舍：这道题我们不用答

**HapStore 根本不需要签名能力。** 收录的 68 个可下载 HAP 绝大多数是上游 Release 里**已签好名**的包。我们只要 hdc 通道，把包原样装进去——签名责任留在上游开发者那里，这是最干净的。

所以：

- ✅ **做**：hdc 通道安装（原样装，不碰签名块）
- ❌ **不做**：内置任何证书替用户签名（砸「不托管、不修改、不重签名」的招牌）
- ⚠️ **未签名包的处理**：列表卡片上明确标注「上游未提供签名包，无法安装」，引导用户去上游 issue 催签名——**而不是替他签**

### 7.4 其余合规红线

- **引导要如实。** 必须说清这是利用系统调试通道、需要用户手动开启并授权，不是「一键安装」。
- **别做成 shell 终端产品化。** 有 `HdcExtShell` 能力不等于该暴露给用户。

### 7.5 一个待确认的技术细节

鸿蒙的 `p7b` profile 在较新 API 上是**绑定 bundleName** 的。那么用自己的证书给任意第三方 HAP 重签时，如何生成匹配目标 bundleName 的 profile，机制尚不明确（可能用了通配调试 profile，也可能在包内做了 profile 替换）。**如果将来真要做签名能力，这是第一个要搞清楚的技术点**——但不做签名的话，这条与我们无关。

---

## 附：取证来源

- `likuai2010/auto-installer` README（自述基于 OpenHarmony Hdc 工具；harmonyos next 版「需要通过其他平台进行安装」）
- 解包 `hap_installer-harmonyos-3.1.0.hap`：`module.json` 权限声明、`libhdc_napi.so` NAPI 符号、`assets/store/` 证书
- 官方使用教程与 FAQ：「始终允许使用本机调试」「先装上鸿蒙版助手，以后直接在鸿蒙手机上操作」
- OpenHarmony `developtools_hdc_standard`：RSA 鉴权机制
