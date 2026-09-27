# Rikugan · 六眼

原生 iOS / iPadOS 浏览器（Swift / SwiftUI / WKWebView，最低 iOS 17）。核心能力按优先级：**Chrome MV3 扩展 → 用户脚本 → 内容拦截 → 完整浏览器体验 → 媒体 / 翻译 / 阅读等工具**。无信息流、推荐内容、广告和遥测。

> 本分支按《Rikugan – Teak-like iOS Browser 功能规格》重新实现，源码全部在 `Sources/`。main 分支上的旧原型（`Rikugan/`、`Tests/`、`Examples/`、`scripts/prepare_resources.py`、`scripts/test_runtime.cjs`）已在本分支删除；main 分支未改动。
>
> 测试分级与结果解读见 [docs/TESTING.md](docs/TESTING.md)；真实扩展兼容性见 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)；真机验证清单见 [docs/DEVICE_CHECKLIST.md](docs/DEVICE_CHECKLIST.md)。

## 获取 IPA

GitHub Actions（`.github/workflows/build.yml`）会在每次推送时：

1. `swift test`：核心逻辑单元测试（URL 匹配、脚本元数据、manifest、ZIP/CRX、过滤规则、DNR、导入导出…）
2. `node scripts/test_js.cjs`：注入脚本运行时测试（GM API、chrome.* shim、消息与端口、lastError、Unsupported API）
3. XcodeGen 生成工程 → `iphoneos` Release **无签名**编译 → 打包 `Rikugan-<版本>-build<N>-unsigned.ipa`（含分享扩展），上传为 **Rikugan-unsigned-ipa** artifact
4. 模拟器端到端套件（每个套件一个任务）：core、pageworld、fonts、dnr、lifecycle、stress（扩展后台 30 轮）、archive；另有不阻塞发布的真实扩展兼容性报告任务
5. 全部通过后发布 prerelease（附 IPA 和 `SHA256SUMS.txt`）

模拟器通过只代表模拟器通过，不代表真机通过（见 docs/TESTING.md）。

IPA 未签名，需要自行重签（AltStore / Sideloadly / TrollStore / 企业证书等）。Bundle ID：`com.dandibbert.Rikugan`，分享扩展：`com.dandibbert.Rikugan.Share`。

本地构建（macOS + Xcode 16）：

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Rikugan.xcodeproj -scheme Rikugan -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
swift test && node scripts/test_js.cjs
```

## 功能与实现位置

| 规格 | 实现 |
|---|---|
| §3 Tab 模型与生命周期 | `Browser/BrowserTab.swift`：状态 active / liveBackground / suspended / restoring / terminated；`Core/TabSession.swift` 的 `TabLifecyclePolicy` 按 LRU 挂起超过上限（默认 5，可在开发者设置中调整）的后台 WebView，内存警告时挂起全部后台标签页；挂起保存网址、标题、快照、组、顺序、`interactionState` 历史与滚动位置 |
| §4 标签页 / 类 Safari 标签页组 / 无痕 | `Core/TabSession.swift`（`SessionOps`：创建 / 重命名 / 调整顺序 / 删除组〔关闭或移到默认组〕/ 移动 / 组内排序 / 校验与修复，有单元测试）、`Browser/TabManager.swift`、`TabSwitcherView.swift`（拖动排序、组顺序）；iPad 标签栏、侧边栏、多窗口 |
| §5 地址栏与搜索 | `Core/Omnibox.swift`（网址/搜索判定、9 个内置引擎、自定义模板、关键词快捷方式）、`Browser/OmniboxView.swift`（历史、书签、搜索记录、搜索建议） |
| §6–§10 用户脚本 | `Userscripts/`：元数据解析与编辑器诊断（`Core/UserScriptMetadata.swift`），URL 匹配（`Core/URLMatcher.swift`），注入（`UserScriptStore.swift` + `Resources/JS/UserscriptRuntime.js`），`GMBridge.swift`，资源 / 依赖、更新检查、管理器与带行号的编辑器 |
| §2 自定义网页字体 | `Core/Fonts.swift`（`FontPlan`：正文 / 标题 / 等宽 + 每站点覆盖 / 禁用 / 排除；TTC 拆分）、`Tools/FontManager.swift`、`PageTools.js`（按元素分类打标签，图标字体 / 私有区字符 / 连字图标不替换，emoji 回退）；导入字体通过 FontFace API 注入（不受 CSP 限制） |
| §11–§20 Chrome MV3 运行时 | `Extensions/`：安装器（ZIP / CRX2/3 / 文件夹 / Chrome 应用商店 / Edge 加载项）、`ExtensionRuntime.swift`（内容脚本、后台 Service Worker 宿主、事件、存储、DNR）、`ChromeAPIBridge.swift`、`ExtensionSchemeHandler.swift`（`chrome-extension://<id>/` 逻辑源）、`Resources/JS/ChromeRuntime.js` |
| §21–§22 AdBlock / 元素隐藏 | `Core/FilterRules.swift`（AdGuard / ABP 解析与 WKContentRuleList 编译）、`AdBlock/AdBlockEngine.swift`、元素选择器在 `PageTools.js` |
| §23 网页深色模式 | `PageTools.js`（反色算法 + 已是深色网页自动跳过），全局 关/自动/开 + 每站点例外 |
| §24 阅读模式 / §25 翻译 | `Reader/ReaderView.swift`、`Translation/TranslationService.swift`（可替换 provider：Microsoft、Google、LibreTranslate、DeepL） |
| §26–§29 媒体 / 图片 / 视频 / 下载 | `Media/MediaViews.swift`、`PageHooks.js`（fetch/XHR 嗅探）、`Downloads/DownloadManager.swift`（WKDownload + URLSession，暂停/继续、HLS 下载） |
| §30–§35 页面工具、跳转控制、定时刷新、查找、PDF/打印、无痕 | `Browser/PageMenu.swift`、`PageActions.swift`、`NavigationManager.swift` |
| §36 Profiles | `Browser/BrowserProfile.swift`：每个身份独立的 `WKWebsiteDataStore(forIdentifier:)`、历史、书签、脚本、扩展、网站设置 |
| §37–§39 书签 / 历史 / 导入导出 | `Data/Stores.swift`、`Data/BookmarksHistoryViews.swift`；归档格式 `Core/Archive.swift`（`rikugan-archive` v2，见下文），界面与写入在 `Settings/ContentSettingsViews.swift` |
| 诊断 | `Settings/DiagnosticsView.swift`：构建信息（版本、Git commit、构建时间、设备 / 系统）、标签页生命周期计数、存活 WebView、扩展后台状态与时间线、API 调用 / 不支持调用统计、DNR 能力、App Group / 分享扩展 / 检查器状态、最近错误；可导出不含敏感信息的 JSON。设置 → 开发者 中开启 |
| §40 自动填充 | `Data/Stores.swift`（`AutofillStore`，Keychain）、`Tools/AutofillCoordinator.swift` |
| §41 Share Extension | `Sources/ShareExtension/`（Open / Search in Rikugan） |
| §42 默认浏览器 | 未包含 `com.apple.developer.web-browser` 权利，设置页如实显示不可用 |
| §43 Web Inspector | `isInspectable` 开关 + 应用内控制台 / 元素 / 资源 / 存储（`Tools/InspectorAndQR.swift`） |
| §44–§46 首页 / 二维码 / 工具栏 | `Browser/HomeView.swift`（收藏、常用、壁纸），二维码生成与扫描，长按自定义快捷按钮，地址栏顶部 / 底部 |
| §47–§48 网站设置 / 权限 | `Core/Preferences.swift`（`SiteSettings`）、`Web/ScriptBridge.swift`（位置、通知、剪贴板按网站 询问/允许/阻止），摄像头/麦克风在 `NavigationManager.swift` |

## 导入导出格式（rikugan-archive v2）

```jsonc
{
  "format": "rikugan-archive", "formatVersion": 2,
  "exportedAt": "2026-09-27T10:00:00.000Z", "appVersion": "1.0.0 (41)",
  "contents": { "userscriptSource": true, "userscriptValues": true, "extensionPackages": false, "fontFiles": false },
  "excluded": ["passwords", "payment cards", "keychain items", "cookies", "website data (localStorage / IndexedDB / cache)", "…"],
  "settings": { … }, "activeProfileID": "…",
  "profiles": [ { "id", "name", "symbol", "isDefault", "siteSettings": [], "bookmarks": [], "windows": [ { "tabs", "groups", "selectedTabID", "selectedGroupID" } ],
                  "userscripts": [ { "name", "namespace", "version", "enabled", "sourceURL", "source"?, "values"? } ], "extensions": [ 元数据 ] } ],
  "fonts": [ 元数据 ], "contentBlocking": { "enabled", "customRules", "subscriptions", "allowlist" }
}
```

- 文件明确声明是否包含脚本源码 / 存储值；扩展包和字体文件只导出元数据（导入后需重新安装），密码、Keychain、Cookie 等永远不导出（`excluded` 列表）。
- 导入：先校验（JSON、格式名、版本、结构——组引用、选中标签页等），v1（`rikugan-export`）自动迁移，未知字段忽略，比当前版本新的文件拒绝；显示预览后选择 **合并**（按域名 / URL / 脚本名去重，标签页与组追加并重新分配 ID）或 **替换**；写入前把当前状态备份到 `Backups/pre-import-*.rikugan.json`；解析失败不会修改任何数据。
- 测试：`CoreTests/SessionAndArchiveTests.swift`（往返、合并、损坏 / 未来版本、v1 迁移含仓库中的 v1 样本文件）与模拟器 archive 套件（真实存储上的 导出→重置→导入）。

## 扩展兼容性

App 内「设置 → 兼容性矩阵」列出每个 `chrome.*` 命名空间的 Supported / Partial / Unsupported。要点：

- 首阶段 API：runtime、storage、scripting、tabs、permissions、action、i18n 完整实现；contextMenus、cookies、downloads、notifications、webNavigation、declarativeNetRequest、alarms、windows 部分实现。
- 未实现的命名空间 / 方法**不会是 undefined**：调用时 Promise 以 `Unsupported API: chrome.xxx` 拒绝，回调模式设置 `chrome.runtime.lastError`。
- 内容脚本运行在每个扩展独立的 `WKContentWorld`；主框架脚本在导航提交前按原生规则选择，保留顶层作用域语义；`all_frames` 子框架变体由同一规则生成的 JS 正则守卫。
- 后台 Service Worker 运行在独立的隐藏 WKWebView（`chrome-extension://<id>/_generated_background_page.html`），不依赖任何网页标签。`importScripts` 通过同步加载实现。
- API 矩阵来自 `Resources/JS/chrome-api-matrix.json`，精确到方法（级别、原因、与 Chrome 的差异）；CI 逐方法校验：标为支持的方法必须在 JS shim 中真实存在且在原生桥中有实现，标为不支持的必须是明确报错的桩函数。
- DNR：block / allow / allowAllRequests / upgradeScheme 编译为 WKContentRuleList；redirect（url / extensionPath / transform）与 modifyHeaders 仅在当前 WebKit 接受对应内容规则动作时启用（运行时探测，结果显示在诊断页），否则明确跳过并列出；`regexSubstitution` 无法等价实现。`webRequest` 不可用（WKWebView 没有公开的请求拦截接口）。
- 后台运行时是显式状态机（notStarted / starting / ready / idle / suspended / waking / failed）：启动期间的消息、事件和 Port 排队，就绪后投递；启动失败或 15 秒未就绪时明确报错；空闲超时挂起（有打开的 Port 时不挂起），下一条消息 / 已订阅事件唤醒。
- 扩展默认不在无痕标签页运行（等同 Chrome“在无痕模式下启用”关闭）。
- iOS 限制：无法拦截/修改任意网络请求（无 webRequest），后台计时在 App 挂起后不会继续。

## 用户脚本兼容性

- 支持 `@match @include @exclude @exclude-match @run-at(document-start/body/end/idle) @grant @connect @require @resource @icon @downloadURL @updateURL @noframes @inject-into`。
- GM API：见 App 内矩阵。`GM_getValue` 等使用每个脚本独立的原生存储，不使用网页 localStorage；`GM_addValueChangeListener` 支持跨标签页。
- **运行环境（安全边界，见 [docs/SECURITY.md](docs/SECURITY.md)）**：只使用“页面安全”授权（`none`、`unsafeWindow`、`GM_info`、`GM_log`、`GM_addStyle`、`GM_addElement`、`window.onurlchange`）的脚本，以及 `@inject-into page` 的脚本，运行在页面环境，`unsafeWindow` 就是真实页面窗口，但**没有任何特权桥**：不注入凭据、不注入存储值，`GM_setValue` / `GM_xmlhttpRequest` / `GM_openInTab` 等会抛出明确错误（脚本详情页有橙色警告）。其他声明了特权 GM API 的脚本一律运行在各自的隔离环境（WKContentWorld），特权调用由 WebKit 报告的内容环境鉴权，页面 JS 无法伪造；在隔离环境中 `unsafeWindow` 看不到页面 JS 全局变量（矩阵中标为 Partial）。
- `GM_xmlhttpRequest` 在原生侧执行并逐跳检查 `@connect`；默认携带该网站 Cookie（`anonymous: true` 可关闭）。

## 自检

`设置 → 自检` 可选择套件运行，或以 `-RikuganSuite <core|pageworld|fonts|dnr|lifecycle|stress|archive|compat>` 启动（`-RikuganSelfTest` 等同 core）。App 在 127.0.0.1 上启动内置测试服务器（记录每个请求，用于判定拦截结果），安装对应的测试扩展 / 脚本 / 字体，打开测试页并验证**实际效果**，结果写入 `Documents/SelfTestReports/<suite>.json`。各套件内容见 [docs/TESTING.md](docs/TESTING.md)。
