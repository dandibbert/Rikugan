# Rikugan · 六眼

## 0.4.0 · 分享安装与跨页面脚本通信

新增 `.user.js` 文件/源码分享，多条消息不再共用单个覆盖槽；主 App 逐个展示脚本源码与权限并等待确认。设置中的「待处理分享」可继续或移除。新增 GM_addValueChangeListener / GM_removeValueChangeListener、GM.* 异步对应接口和跨标签/iframe 存储镜像，按脚本、身份及无痕会话隔离。下载文件名为 `Rikugan-0.4.0-unsigned.ipa`；设备签名和第三方扩展兼容仍以实际设备验证为准。

## 0.3.0 · 最新规格续做

本轮加入标签按需创建/内存压力挂起与 WebKit 状态恢复、v2→v3 备份迁移和引用校验、无痕新标签及 GM 存储隔离；修复脚本元数据更新和重复重装；下载统一使用带当前身份 Cookie 的 WKDownload，支持进度、暂停、服务器支持时的续传、取消与失败记录。具体实现、自动化测试入口和未完成项见 `docs/IMPLEMENTATION_STATUS.md`。

本版本文件名为 `Rikugan-0.3.0-unsigned.ipa`。成功主分支构建同时发布 `tests.zip` 与 `SHA256SUMS.txt`；测试包 manifest 会记录真实结果，真机验证不会冒充已完成。

自用 iOS 浏览器：**WebExtension + 用户脚本 + 多身份**。SwiftUI / WKWebView 原生实现，无内购、无账号服务、无遥测。不使用 Teak 的二进制、代码或购买信息。

## 安装

GitHub Actions 在功能分支推送、针对 `main` 的 pull request，以及 `main` 推送时，用 macOS 上的 `xcodebuild` 编译 **未签名** IPA，并上传名为 `Rikugan-unsigned-IPA` 的 artifact，其中包含 `Rikugan-0.3.0-unsigned.ipa`。`main` 上测试成功后，同一份 IPA 也会出现在 prerelease。没有签名证书或描述文件，不能直接点开安装，需要用自己的证书或侧载工具重签。最低 iOS / iPadOS **18.4**，设备产物为 arm64。

默认 Bundle ID：`com.dandibbert.Rikugan`。工程带有 App Group `group.com.dandibbert.Rikugan`，供分享扩展和主 App 交换待打开的链接；未签名包不会激活这个 group，重签时描述文件需要包含同一个 group。没有默认浏览器 entitlement，设置页也不会把它说成可用。一个 App 内可建立多个身份，不必多开 IPA。

## 第一版用法

1. 首页 → **扩展与脚本** → 从文件导入 WebExtension ZIP / CRX / 目录，或 `.user.js`。ZIP 的根目录必须含 `manifest.json`，不能多套一层文件夹。安装前会展示权限。也可以粘贴 Chrome / Edge 扩展 ID。
2. 用户脚本也支持 HTTPS 直链导入、源码编辑、新建、启停；直接访问 HTTPS `.user.js` 地址会转入确认界面。导入后刷新网页。
3. 扩展列表里的 **打开扩展** 显示 action/popup；详情页可打开选项页、管理网站匹配权限、查看加载错误。
4. 底部 **身份空间** 新建不同身份。网站数据、扩展配置、GM 存储、标签、书签和历史按身份分离。切换时会销毁原身份的页面和运行时，再恢复目标身份；未提交表单和页面内临时 JS 状态不会恢复。
5. 脚本注册的菜单在底部 **更多 → 脚本菜单命令**。下载在 **设置与下载** 或系统「文件 → 我的 iPhone → Rikugan → Downloads」中。

## 扩展支持边界

使用 iOS 18.4 起公开的 `WKWebExtension`、`WKWebExtensionContext`、`WKWebExtensionController`，不是自制 `chrome.*` 全量替代品，也不会把扩展改写成用户脚本。支持标准 ZIP、解压目录、CRX2/CRX3（剥掉头后交给同一套校验）、WebKit 支持的 Manifest V3、content scripts、后台、messaging、storage、action/popup、options、网站权限和基础 tabs/window 宿主。可以从 Chrome 或 Edge 扩展 ID / 商店链接下载 CRX；下载失败会显示原因，不会假装安装成功。更新时若权限变多，会先说明新增项再替换文件。

**不能保证任意 Chrome/Firefox 扩展能直接运行。** 设置里的兼容表把 API 标成 Supported、Partial 或 Unsupported。`debugger`、`nativeMessaging` 和持久通知是 Unsupported。`runtime.sendNativeMessage` / `connectNative` 列入 `unsupportedAPIs`。扩展的签名及商店来源不由本 App 验证。不同 iOS 的 WebKit API 支持可能不同。

### 普通证书版的后台兼容模式

未获得默认浏览器 / Service Worker entitlement 的普通 iOS 签名不能保证原生扩展 Service Worker 可用。因此这个自用版本把 MV3 `background.service_worker` 的入口放入 **非持久后台页面**，仍由 WebKit 提供原生 `browser.*` / `chrome.*` API，而不是把扩展转成用户脚本。转换前保留完整原始 ZIP / 目录，权限预览和详情页明确标注兼容模式；不会改扩展的 JS 代码或权限。

这不是完整 Service Worker 兼容层。`importScripts`、Worker 的 install/activate/fetch 事件、clients 等语义没有模拟，依赖它们的扩展可能失败。兼容模式限制单个解压文件 8 MB、总计 128 MB。只有取得相应 Apple 授权并使用包含 entitlement 的描述文件的开发者，才应在构建中配置 `RikuganNativeServiceWorkers=true`；这个开关本身不会赋予权限。

技术依据：WebKit 的 `Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm` 在没有 `com.apple.developer.WebKit.ServiceWorkers`、`com.apple.developer.web-browser` 或 App-Bound Domains 时关闭 Service Workers。本浏览器不会用限制全网导航的 App-Bound Domains 冒充解决方案。

Profiles 使用稳定 UUID 对应的 `WKWebsiteDataStore(forIdentifier:)`，每个身份也有独立的 `WKWebExtensionController.Configuration(identifier:)`。这是一款 App 内的逻辑分区，不是多个独立安装 App 的 OS 安全边界。

## 用户脚本支持

元数据：`@match`、`@include`、`@exclude`、`@exclude-match`、`@run-at`（start/body/end/idle）、`@noframes`、`@grant`、`@connect`、HTTPS `@require`、HTTPS `@resource`（最多 8 个，安装时下载并缓存）、`@author`、`@namespace`、HTTPS `@updateURL` / `@downloadURL`。每个脚本最多 8 个依赖，安装时下载并固定保存在该身份中。有更新地址时可以检查版本并重新导入。单页应用换 URL 后，仍匹配的脚本会再跑一次。

常用 API（同时提供适用的同步 `GM_*` 与异步 `GM.*` 接口）：

- getValue / setValue / deleteValue / listValues、info、addStyle、log
- xmlHttpRequest / `GM_xmlhttpRequest`，文本/JSON/arraybuffer/blob 响应
- setClipboard、openInTab、registerMenuCommand / unregisterMenuCommand

明确的兼容限制：

- 带 GM 原生权限的脚本运行在各自 `WKContentWorld` 中；`@grant none` 运行在页面环境。接受 `@grant unsafeWindow`，但其兼容性是 Partial：隔离环境下只提供注入 `eval` 或 JSON 可序列化属性赋值，读取页面对象会抛错；页面 CSP 也可能拒绝注入。页面环境下它就是 `window`。`GM_getResourceText` / `GM_getResourceURL` 读安装时缓存的 `@resource`。未知 grant 会拒绝安装并给出原因。
- 同步 `GM_getValue` 读取当前页面缓存；其他标签修改的值使用异步 `GM.getValue` 读取，或刷新页面。跨标签 value-change listener 尚未实现。存储是 JSON，不支持函数/循环引用/特殊对象序列化。
- GM 网络使用无 Cookie 的 ephemeral URLSession，不自动附带浏览器登录 Cookie。按 `@connect` 检查首个请求和每次重定向；同源默认允许。系统 ATS 对普通 HTTP 原生请求仍可能限制；建议 HTTPS。
- XHR 不支持流式、进度事件、FormData 和完整同步/中间 readyState 语义；`abort()` 当前只中止回调交付，不保证终止底层传输。单次响应限制 8 MB。
- 脚本菜单仅支持顶层页面。DOM 注入不是对所有油猴脚本的完整兼容承诺。

只导入自己信任的脚本与扩展。页面数据可能包括登录后内容，授予 `<all_urls>` 或 `@connect *` 前应审阅源码。

## 浏览器功能

多标签、标签组、关闭后恢复、无痕标签（`WKWebsiteDataStore.nonPersistent()`，不进历史和会话快照）、地址栏关键词与 `{query}` 搜索引擎、前进/后退/刷新、自动刷新、系统分享、页内查找、桌面版模式、书签文件夹、按天历史、下载暂停/继续/进度、网页对话框、站点级权限（摄像头、麦克风、位置、剪贴板、弹窗、外部跳转）。iPhone 保持原来的单栏界面；较宽的 iPad 使用侧栏和标签条，并可以打开第二个窗口。

另外有：内置广告域名和 AdGuard 子集规则（网络规则走 `WKContentRuleList`，元素隐藏同时注入 CSS，订阅和自定义规则有上限）、页面暗黑、阅读模式、Apple Translation 整页替换、媒体嗅探、图片保存、二维码、HTML5 画中画 / 全屏 / AirPlay、打印和 PDF、钥匙串自动填充（只在点按后填入，不写 UserDefaults）、实验控制台，以及 Share Extension。普通网页文件输入由 WebKit/系统处理。

没有系统默认浏览器资格，也没有 iCloud 同步。FairPlay / Widevine 不在范围内。广告规则不是完整 EasyList。分享扩展需带 App Group 的描述文件重签才能共享待打开内容；iOS 不保证允许分享扩展直接启动主 App，失败时会明确提示手动打开。缺少 App Group 时提供复制退路，不谎报已发送。

### 字体与备份

全局网页字体和站点字体覆盖独立于用户脚本。可以导入系统接受的 ttf/otf/ttc 字体，字体替换避开常见图标类、符号字体、PUA 图标字符和代码区，关闭后恢复原样；未知自定义图标仍可能需要对该网站关闭覆盖。备份导入先校验和预览，再选择合并或替换标签/分组/书签及设置。导入前保留当前状态恢复副本，不包含 Cookie、扩展包、脚本、钥匙串或字体/壁纸的文件内容。

## 构建与验证

GitHub Actions（`.github/workflows/build.yml`，`macos-15`）在 `main`、`cursor/**` 推送、pull request 或手动触发时：生成资源和 Xcode 项目 → 用 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、`CODE_SIGN_IDENTITY=''` 编译真机目标 → 把 `.app` 放进 `Payload/` 并打成 `Rikugan-0.3.0-unsigned.ipa` → **立刻上传 artifact** → 再跑模拟器单元和 UI 测试。测试失败不会撤掉已经上传的 IPA，失败证据仍会打包为 tests.zip。只有 `main` 推送且测试成功时才发 prerelease。不需要签名用的 secret。

```bash
brew install xcodegen
python3 scripts/prepare_resources.py
node scripts/test_runtime.cjs
node scripts/test_page_tools.cjs
xcodegen generate
xcodebuild -project Rikugan.xcodeproj -scheme Rikugan \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' ARCHS=arm64 build
mkdir -p dist/Payload
cp -R build/Build/Products/Release-iphoneos/Rikugan.app dist/Payload/
( cd dist && zip -qry Rikugan-0.3.0-unsigned.ipa Payload )
```

自动化 UI 测试使用 CI 上 `127.0.0.1:8765` 的测试网页，不依赖公共网站：安装内置示例 → 验证脚本/扩展注入 → 检查 GM 存储 → 检查扩展后台通信和 popup → 写入 Cookie/localStorage → 新身份确认无数据且无扩展/脚本 → 切回验证数据保留。

真实设备重签安装、键盘交互、长期内存压力，以及具体第三方扩展的兼容性，仍需要设备上验证；模拟器测试不能替代这些。

## 主要目录

`Models.swift`：数据结构、脚本元数据、URL 权限与 ZIP 检查。`FeatureModels.swift` / `StateMigration.swift`：标签组、站点设置、备份和 schema 1 升级。`AppModel.swift`：持久化与身份切换。`BrowserSession.swift`：浏览器与下载。`ExtensionHost.swift` / `ExtensionPackage.swift`：WebExtension 宿主、CRX 和兼容表。`AdBlockEngine.swift`：广告规则子集。`UserScriptEngine.swift` / `UserscriptRuntime.js`：隔离桥接与 GM API。`PageTools.js`：暗黑、阅读、查找、元素选择和填充。`BrowserUI.swift` / `AddonsUI.swift` / `ToolsUI.swift`：界面。`ShareExtension/`：系统分享。`Tests` / `UITests`：测试。

## Apple / WebKit 参考

- https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
- https://developer.apple.com/documentation/webkit/wkwebextension
- https://developer.apple.com/documentation/webkit/wkwebextensioncontroller
- https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)

