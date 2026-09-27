# Rikugan · 六眼

原生 iOS / iPadOS 浏览器（Swift / SwiftUI / WKWebView，最低 iOS 17）。核心能力按优先级：**Chrome MV3 扩展 → 用户脚本 → 内容拦截 → 完整浏览器体验 → 媒体 / 翻译 / 阅读等工具**。无信息流、推荐内容、广告和遥测。

> 本分支按《Rikugan – Teak-like iOS Browser 功能规格》重新实现。源码在 `Sources/`；仓库根目录的 `Rikugan/`、`Tests/`、`Examples/`、`scripts/prepare_resources.py`、`scripts/test_runtime.cjs` 是 main 分支上的旧实现，新的 `project.yml` 已不再引用，可以删除。

## 获取 IPA

GitHub Actions（`.github/workflows/build.yml`）会在每次推送时：

1. `swift test`：核心逻辑单元测试（URL 匹配、脚本元数据、manifest、ZIP/CRX、过滤规则、DNR、导入导出…）
2. `node scripts/test_js.cjs`：注入脚本运行时测试（GM API、chrome.* shim、消息与端口、lastError、Unsupported API）
3. XcodeGen 生成工程 → `iphoneos` Release **无签名**编译 → 打包 `Rikugan-<版本>-build<N>-unsigned.ipa`（含分享扩展），上传为 **Rikugan-unsigned-ipa** artifact
4. 模拟器端到端自检（XCUITest 启动 `-RikuganSelfTest`，见下文）
5. 全部通过后发布 prerelease（附 IPA 和 `SHA256SUMS.txt`）

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
| §3 WKWebView 常驻、Tab 模型 | `Browser/BrowserTab.swift`：每个标签一个长期存在的 WKWebView，切换只换视图；`interactionState` 恢复会话历史 |
| §4 标签页 / 类 Safari 标签页组 / 无痕 | `Browser/TabManager.swift`、`TabSwitcherView.swift`；iPad 标签栏、侧边栏、多窗口（`UIApplicationSupportsMultipleScenes`） |
| §5 地址栏与搜索 | `Core/Omnibox.swift`（网址/搜索判定、9 个内置引擎、自定义模板、关键词快捷方式）、`Browser/OmniboxView.swift`（历史、书签、搜索记录、搜索建议） |
| §6–§10 用户脚本 | `Userscripts/`：元数据解析与编辑器诊断（`Core/UserScriptMetadata.swift`），URL 匹配（`Core/URLMatcher.swift`），注入（`UserScriptStore.swift` + `Resources/JS/UserscriptRuntime.js`），`GMBridge.swift`，资源 / 依赖、更新检查、管理器与带行号的编辑器 |
| §2 自定义网页字体 | `Tools/FontManager.swift`：描述文件安装的系统字体直接按名称使用；导入的 TTF/OTF/WOFF 通过 FontFace API 注入（不受 CSP 限制） |
| §11–§20 Chrome MV3 运行时 | `Extensions/`：安装器（ZIP / CRX2/3 / 文件夹 / Chrome 应用商店 / Edge 加载项）、`ExtensionRuntime.swift`（内容脚本、后台 Service Worker 宿主、事件、存储、DNR）、`ChromeAPIBridge.swift`、`ExtensionSchemeHandler.swift`（`chrome-extension://<id>/` 逻辑源）、`Resources/JS/ChromeRuntime.js` |
| §21–§22 AdBlock / 元素隐藏 | `Core/FilterRules.swift`（AdGuard / ABP 解析与 WKContentRuleList 编译）、`AdBlock/AdBlockEngine.swift`、元素选择器在 `PageTools.js` |
| §23 网页深色模式 | `PageTools.js`（反色算法 + 已是深色网页自动跳过），全局 关/自动/开 + 每站点例外 |
| §24 阅读模式 / §25 翻译 | `Reader/ReaderView.swift`、`Translation/TranslationService.swift`（可替换 provider：Microsoft、Google、LibreTranslate、DeepL） |
| §26–§29 媒体 / 图片 / 视频 / 下载 | `Media/MediaViews.swift`、`PageHooks.js`（fetch/XHR 嗅探）、`Downloads/DownloadManager.swift`（WKDownload + URLSession，暂停/继续、HLS 下载） |
| §30–§35 页面工具、跳转控制、定时刷新、查找、PDF/打印、无痕 | `Browser/PageMenu.swift`、`PageActions.swift`、`NavigationManager.swift` |
| §36 Profiles | `Browser/BrowserProfile.swift`：每个身份独立的 `WKWebsiteDataStore(forIdentifier:)`、历史、书签、脚本、扩展、网站设置 |
| §37–§39 书签 / 历史 / 导入导出 | `Data/Stores.swift`、`Data/BookmarksHistoryViews.swift`、`Settings/ContentSettingsViews.swift`（`ImportExport`） |
| §40 自动填充 | `Data/Stores.swift`（`AutofillStore`，Keychain）、`Tools/AutofillCoordinator.swift` |
| §41 Share Extension | `Sources/ShareExtension/`（Open / Search in Rikugan） |
| §42 默认浏览器 | 未包含 `com.apple.developer.web-browser` 权利，设置页如实显示不可用 |
| §43 Web Inspector | `isInspectable` 开关 + 应用内控制台 / 元素 / 资源 / 存储（`Tools/InspectorAndQR.swift`） |
| §44–§46 首页 / 二维码 / 工具栏 | `Browser/HomeView.swift`（收藏、常用、壁纸），二维码生成与扫描，长按自定义快捷按钮，地址栏顶部 / 底部 |
| §47–§48 网站设置 / 权限 | `Core/Preferences.swift`（`SiteSettings`）、`Web/ScriptBridge.swift`（位置、通知、剪贴板按网站 询问/允许/阻止），摄像头/麦克风在 `NavigationManager.swift` |

## 扩展兼容性

App 内「设置 → 兼容性矩阵」列出每个 `chrome.*` 命名空间的 Supported / Partial / Unsupported。要点：

- 首阶段 API：runtime、storage、scripting、tabs、permissions、action、i18n 完整实现；contextMenus、cookies、downloads、notifications、webNavigation、declarativeNetRequest、alarms、windows 部分实现。
- 未实现的命名空间 / 方法**不会是 undefined**：调用时 Promise 以 `Unsupported API: chrome.xxx` 拒绝，回调模式设置 `chrome.runtime.lastError`。
- 内容脚本运行在每个扩展独立的 `WKContentWorld`；主框架脚本在导航提交前按原生规则选择，保留顶层作用域语义；`all_frames` 子框架变体由同一规则生成的 JS 正则守卫。
- 后台 Service Worker 运行在独立的隐藏 WKWebView（`chrome-extension://<id>/_generated_background_page.html`），不依赖任何网页标签。`importScripts` 通过同步加载实现。
- DNR：block / allow / allowAllRequests / upgradeScheme 编译为 WKContentRuleList；redirect、modifyHeaders 不支持，会在扩展详情中列出被跳过的规则。
- 扩展默认不在无痕标签页运行（等同 Chrome“在无痕模式下启用”关闭）。
- iOS 限制：无法拦截/修改任意网络请求（无 webRequest），后台计时在 App 挂起后不会继续。

## 用户脚本兼容性

- 支持 `@match @include @exclude @exclude-match @run-at(document-start/body/end/idle) @grant @connect @require @resource @icon @downloadURL @updateURL @noframes @inject-into`。
- GM API：见 App 内矩阵。`GM_getValue` 等使用每个脚本独立的原生存储，不使用网页 localStorage；`GM_addValueChangeListener` 支持跨标签页。
- `@grant none`、`@inject-into page` 或声明 `unsafeWindow` 的脚本运行在页面环境（`unsafeWindow` 完整可用）；其他脚本运行在独立的隔离环境，其中 `unsafeWindow` 看不到页面 JS 全局变量（已在矩阵中标为 Partial）。
- `GM_xmlhttpRequest` 在原生侧执行并逐跳检查 `@connect`；默认携带该网站 Cookie（`anonymous: true` 可关闭）。

## 自检（规格 §50 / §51）

`设置 → 自检` 或以 `-RikuganSelfTest` 启动：App 在 127.0.0.1 上启动内置测试服务器，安装 `Resources/SelfTest/ext`（测试扩展）和 `selftest.user.js`，打开测试页并逐项验证**实际效果**：

- 扩展 Test 1–8：document_start / document_end / CSS 内容脚本、runtime.sendMessage、Port、storage.local、Popup 读取当前标签页、scripting.executeScript（含返回值）、host permissions、后台唤醒 + tabs.sendMessage、DNR 屏蔽测试资源、Unsupported API 报错
- 用户脚本：@match 注入、@exclude、GM 存储与持久化、GM_xmlhttpRequest、GM_addStyle、菜单命令、刷新、无痕标签页
- AdBlock：元素隐藏规则生效

CI 中的 XCUITest（`UITests/BrowserUITests.swift`）以 `SELFTEST PASS n/n` 为验收标准。真机上的长期内存压力、具体第三方扩展（Dark Reader、uBlock Origin Lite、Violentmonkey 等）的兼容性仍需在设备上验证。
