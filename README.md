# Rikugan · 六眼

自用 iOS 浏览器：**WebExtension + 用户脚本 + 多身份**。SwiftUI / WKWebView 原生实现，无内购、无账号服务、无遥测。不使用 Teak 的二进制、代码或购买信息。

## 安装

GitHub Actions 在功能分支推送、针对 `main` 的 pull request，以及 `main` 推送时，用 macOS 上的 `xcodebuild` 编译 **未签名** IPA，并通过 `actions/upload-artifact` 上传名为 `Rikugan-unsigned-IPA` 的 artifact。打开对应 workflow run，下载 `dist/Rikugan-0.2.0-unsigned.ipa`。`main` 上测试成功后，同一份 IPA 也会出现在 prerelease。没有签名证书或描述文件，不能直接点开安装，需要用自己的证书或侧载工具重签。部署目标是 iOS / iPadOS **17.0**，设备产物为 arm64。浏览、用户脚本和广告拦截在 iOS 17 上编译运行。扩展安装走 `WKWebExtension`，系统低于 18.4 时显示「需要 iOS 18.4」，不会另做一套 `chrome.*`。

默认 Bundle ID：`com.dandibbert.Rikugan`。工程带有 App Group `group.com.dandibbert.Rikugan`，供分享扩展和主 App 交换待打开的链接；未签名包不会激活这个 group，重签时描述文件需要包含同一个 group。`Rikugan.entitlements` 写了 `com.apple.developer.web-browser`。未签名 IPA 没有有效签名，**不会**出现在「设置 → App → 默认 App → 浏览器 App」。只有用包含这项权限的付费描述文件重签之后，系统才可能把它列出来。设置页写的是同一句话。一个 App 内可建立多个身份，不必多开 IPA。

## 第一版用法

1. 首页 → **扩展与脚本** → 从文件导入 WebExtension ZIP / CRX / 目录，或 `.user.js`。ZIP 的根目录必须含 `manifest.json`，不能多套一层文件夹。安装前会展示权限。也可以粘贴 Chrome / Edge 扩展 ID。
2. 用户脚本也支持 HTTPS 直链导入、源码编辑、新建、启停；直接访问 HTTPS `.user.js` 地址会转入确认界面。导入后刷新网页。
3. 扩展列表里的 **打开扩展** 显示 action/popup；详情页可打开选项页、向当前标签页插入 CSS、在页面世界执行一段脚本、管理网站匹配权限、查看加载错误。脚本列表每一行显示 `@grant`。没有 `@downloadURL` 和 `@updateURL` 时，「重新安装」会提示无法重新安装。
4. 底部 **身份空间** 新建不同身份。网站数据、扩展配置、GM 存储、标签、书签和历史按身份分离。切换时会销毁原身份的页面和运行时，再恢复目标身份；未提交表单和页面内临时 JS 状态不会恢复。
5. 脚本注册的菜单在底部 **更多 → 脚本菜单命令**。下载在 **设置与下载** 或系统「文件 → 我的 iPhone → Rikugan → Downloads」中。

## 扩展支持边界

使用 iOS 18.4 起公开的 `WKWebExtension`、`WKWebExtensionContext`、`WKWebExtensionController`，不是自制 `chrome.*` 全量替代品，也不会把扩展改写成用户脚本。支持标准 ZIP、解压目录、CRX2/CRX3（剥掉头后交给同一套校验）、WebKit 支持的 Manifest V3、content scripts、后台、messaging、storage、action/popup、options、网站权限和基础 tabs/window 宿主。工具栏横向滚动，已启用且已载入的扩展都会显示按钮，第 4 个也能点，点按走 `performExtension` → `performAction`。图标和 badge 来自 `WKWebExtension.Action`，弹出的是 WebKit 自己的 popup。扩展脚本调用 `chrome.scripting.insertCSS` 和 `chrome.scripting.executeScript`。WebKit 已经提供这些方法时沿用 WebKit，不覆盖。没有这些方法时，载入扩展前会把桥接脚本写进 service worker 和 content script：`css`、`func` / `code` 和 `files` 都转发。`files` 从该扩展包里读取，文件不存在就返回错误。`executeScript` 默认在扩展的 content script 隔离世界执行；只有 `world: "MAIN"` 才在页面世界执行。`func` 和 `args` 会在目标世界调用。`target.tabId` 会送到那个标签的 content script；宿主也能用标签 UUID 或 `bridgeTabID` 找到 `BrowserSession` 里的标签。`target.allFrames` 跑进同源子框架，`frameIds` 里 `0` 是顶层框架，后面按 `window.frames` 的顺序。`insertCSS` 写入页面 CSSOM，并接受 `world`。扩展详情里的按钮仍是手动入口。这不是第二套完整 `chrome.scripting`。网页里只挂消息中继，不在页面上定义 `chrome.scripting`。可以从 Chrome 或 Edge 扩展 ID / 商店链接下载 CRX。商店更新地址如果返回 `<gupdate><updatecheck codebase>` XML，会解析 `codebase` 再下载那个 CRX，不会把 XML 当成扩展包。扩展详情和扩展列表里可以按更新 URL 检查更新。下载失败会显示原因，不会假装安装成功。更新时若权限变多，会先说明新增项再替换文件。

**不能保证任意 Chrome/Firefox 扩展能直接运行。** 设置里的兼容表只把扩展脚本真正能调用、且参数没有被丢掉的 API 标成 Supported。`scripting` 与 `notifications` 是 Partial。`chrome.scripting.insertCSS` / `executeScript` 能把 `css`、`func` / `code` 和扩展包里的 `files` 放进目标标签页。`executeScript` 默认是隔离世界，`world: "MAIN"` 才进页面世界。`chrome.notifications.create` / `update` / `clear` / `getAll` / `getPermissionLevel` 会写入或读取通知记录。`create` 和 `update` 进入 App 内通知列表，并提交 `UNUserNotificationCenter`。系统通知已授权时 `getPermissionLevel` 返回 `granted`，未授权或被拒绝时返回 `denied`。`iconUrl` 和 `imageUrl` 从扩展包相对路径、扩展 URL 或 https 图片读取，显示在列表行上，并在系统允许时作为通知附件。`progress` 存在记录上并显示为 0–100 的进度，`update` 会改它；系统通知本身没有进度条。列表行出现时，以及系统通知提交成功时，都会触发 `onShown`。点按列表里的通知行会触发 `onClicked`，点按按钮会触发 `onButtonClicked`，滑掉一行或 `clear` 会触发 `onClosed`，点「通知设置」会触发 `onShowSettings`。系统通知本身不能深链这些按钮，可点的是 App 内列表。页面 `Notification` 仍走同一条系统通知。`debugger` 与 `nativeMessaging` 仍是 Unsupported，并写进 `WKWebExtensionContext.unsupportedAPIs`（`debugger.*`、`runtime.sendNativeMessage`、`connectNative`）。没有自研 `chrome.debugger` 或 `nativeMessaging`。扩展的签名及商店来源不由本 App 验证。FairPlay / Widevine、未签名 IPA 作为系统默认浏览器、把内容规则做成真实 HTTP 2xx 重定向或改写原始响应字节，都做不到。

Profiles 使用稳定 UUID 对应的 `WKWebsiteDataStore(forIdentifier:)`，每个身份也有独立的 `WKWebExtensionController.Configuration(identifier:)`。这是一款 App 内的逻辑分区，不是多个独立安装 App 的 OS 安全边界。

## 用户脚本支持

元数据：`@match`、`@include`、`@exclude`、`@exclude-match`、`@run-at`（start/body/end/idle）、`@noframes`、`@grant`、`@connect`、HTTPS `@require`、HTTPS `@resource`（最多 8 个，安装时下载并缓存）、`@author`、`@namespace`、HTTPS `@updateURL` / `@downloadURL`。每个脚本最多 8 个依赖，安装时下载并固定保存在该身份中。有更新地址时可以检查版本并重新导入。单页应用换 URL 后，仍匹配的脚本会再跑一次。

常用 API（同时提供适用的同步 `GM_*` 与异步 `GM.*` 接口）：

- getValue / setValue / deleteValue / listValues、info、addStyle、log
- xmlHttpRequest / `GM_xmlhttpRequest`，文本/JSON/arraybuffer/blob/stream 响应，readyState 2/3/4 随数据到达
- setClipboard、openInTab、registerMenuCommand / unregisterMenuCommand

明确的兼容限制：

- 带 GM 原生权限的脚本运行在各自 `WKContentWorld` 中；`@grant none` 运行在页面环境。两种环境都会安装消息通道，所以 `@grant none` 的 `GM_registerMenuCommand` 能回到宿主。`unsafeWindow` 不是 `@grant`：页面环境下就是 `window`。隔离环境下往页面注入脚本，用对象句柄读写 `window` 和 DOM，并调用页面函数。没有外部绑定的函数，以及只闭合 JSON 可序列化局部变量（含脚本 `try` 里的 `const` / `let`）的函数，会把那些值内联后在页面里执行，并同步返回字符串、数字、布尔和 JSON 对象。其余闭包在页面放一个桩，通过 `rikuganPage` 的 `iso-call` 回到隔离世界执行；JSON 对象返回值写回页面，带方法的对象仍是句柄。不发同步 `rikugan-bridge://` 请求。这不是 Tampermonkey 完整实现。`GM_getResourceText` / `GM_getResourceURL` 读安装时缓存的 `@resource`。未知 grant 会拒绝安装并给出原因。规格点名的 grant 可以安装。
- `GM_getValue` / `GM_setValue` / `GM_deleteValue` / `GM_listValues` 使用脚本自己的 JSON 存储，不写网页 localStorage。`GM_addValueChangeListener` 在本页立刻回调，并通知同一身份里其他同样私密性的标签。存储不支持函数或循环引用。无痕标签的 GM 值只留在 `BrowserSession.privateScriptValues`，不写入普通身份的脚本存储；最后一个无痕标签关闭后清空。
- GM 网络使用不保存 Cookie 的 ephemeral URLSession。同源且 `@connect` 允许时，会从当前身份（无痕则用无痕存储）的 `WKWebsiteDataStore` 抄一份 Cookie 放进请求头；跨源不带。重定向离开该主机时去掉 Cookie。按 `@connect` 检查首个请求和每次重定向；同源默认允许。系统 ATS 对普通 HTTP 原生请求仍可能限制；建议 HTTPS。
- `GM_xmlhttpRequest` 有 `onprogress`，`abort()` 会 `task.cancel()`。字符串、`URLSearchParams` 和 `FormData`（含文件字段）以及 `Blob` / `ArrayBuffer` 会作为请求体发出；`FormData` 使用 `multipart/form-data`。响应头到达时 `readyState` 为 2，之后每个数据块为 3，`onprogress` 带上已下载字节，`response` / `responseText` 是截至目前的文本；完成时为 4。`responseType: "stream"` 时 `onloadstart` 得到 `ReadableStream`，每个块写入这个流。`readyState` 随网络回调送达，不是阻塞式同步 XHR。单次请求体和响应各限制 8 MB。`@inject-into page` 把带 GM 权限的脚本放进页面世界，GM 调用仍走同一条消息通道。
- `GM_notification` 进入应用内通知并调用 `SystemNotifications.deliver`，点击后执行脚本的 `onclick`。`GM_download` 把文件放进下载列表，同源时带上当前身份的 Cookie。`GM_cookie` 只读写当前网站在该标签数据仓库里的 Cookie。`GM_addElement` 在页面创建元素，隔离脚本与其它 DOM 写入一样注入页面世界。`GM_getTab` / `GM_saveTab` / `GM_getTabs` 只看当前身份里相同私密性的标签。`window.close` 关闭当前标签，`window.onurlchange` 在 `noteURLChange` 的 SPA 换址和完整导航时触发。
- 脚本列表显示 HTTPS `@icon` 和 `updatedAt`。脚本菜单仅支持顶层页面。DOM 注入不是对所有油猴脚本的完整兼容承诺。

只导入自己信任的脚本与扩展。页面数据可能包括登录后内容，授予 `<all_urls>` 或 `@connect *` 前应审阅源码。

## 浏览器功能

多标签、标签组（缩略图写入身份目录，网格里可以重命名和删除分组）、关闭后恢复、无痕标签（`WKWebsiteDataStore.nonPersistent()`，不进历史和会话快照，也不记搜索历史）、地址栏关键词与可改名/删除的自定义 `{query}` 引擎、只输入关键词就打开网址的快捷方式、Google / Bing / DuckDuckGo / Brave / Yahoo / Baidu / Startpage / Naver / Yandex 搜索建议（设置里可关）、前进/后退/标签按钮长按快捷动作、自动刷新（恢复会话后继续当前标签的计时）、系统分享、页内查找（`WKWebView.find`，匹配次数用只读文本统计，不往页面插 `<mark>`）、桌面版模式、按 `parentID` 嵌套的书签文件夹（删除文件夹时子项回到上一层）、书签编辑同时改标题和网址、按天历史、下载暂停/继续。`URLSession` 路径有速度和剩余时间，并带上 `WKWebsiteDataStore` 的 Cookie。网页触发的 `WKDownload` 走 WebKit 会话（因此带页面 Cookie），可以取消并拿 resume data 再 `resumeDownload`。公开的 `WKDownloadDelegate` 没有字节回调，进度、速度和剩余时间来自目标文件在磁盘上的增长。下载列表的「保存到文件」用 `UIDocumentPickerViewController` 导出已完成的文件。站点权限含摄像头、麦克风、位置、剪贴板、通知、弹窗和外部跳转。剪贴板「询问」使用和相机一样的允许/禁止对话框；允许后页面 `readText` 保持可用，禁止则拒绝读取。允许通知后，页面 `Notification` 进入 App 内通知列表，并在系统授权后提交 `UNUserNotificationCenter`。iPhone 保持单栏界面；较宽的 iPad 使用侧栏和标签条。「新窗口」在同一个 `BrowserSession` 里再开一组 `BrowserTab`，所以脚本、内容规则、下载、页内查找、阅读模式和页面菜单都会跑。这些标签不写入主窗口保存的标签列表。切换仍在预算内的标签不会重建网页。当前标签保持 live WKWebView；其余最近使用的标签保留到最多 8 个，更早的标签会 suspend，只留下 URL、标题、滚动位置、分组和缩略图。打开暂停的标签或 WebContent 被系统回收后会重新请求这个 URL，不恢复 JS 堆、WebSocket 或后退列表。

另外有：

- 广告规则是 AdGuard 子集，不是内置的完整 EasyList。内置列表只覆盖常见广告域和少量元素隐藏。订阅 URL 会整份下载（单次上限 8 MB）并编译，列表里可以重新下载。网络规则和元素隐藏编译成 `WKContentRuleList`，默认按 5 万条一块（Safari 内容拦截扩展的实际上限；WebKit 没有公开硬顶，编译失败的段会退回纯网络规则）。`@@`、`$script`、`$image`、`$stylesheet`、`$xmlhttprequest`、`$third-party`、`$domain=`、`##`、`#@#` 会进规则。`#$#` 作为 CSS 注入。`#?#` 的 `:has()` 当元素隐藏；`:has-text`、`:contains`、`:xpath`、`:matches-css`、`:upward`、`:remove`、`:style` 由页面脚本执行。`#%#` 和 `##+js` 会跑 abort-on-property-read、abort-on-property-write、json-prune、set-constant、prevent-fetch、prevent-xhr。`$removeparam` 在主框架导航前删掉对应查询参数。`$csp` 插入 meta 策略。WKContentRuleList 没有重定向动作，所以 `$redirect` 和 `$redirect-rule` 的网络动作是拦截，不是重定向，也不会换成空的 2xx。noopjs、empty、1x1 会额外在页面定义空值：`__rgRedirect.noopjs` 是空函数，`__rgRedirect.empty` 是空字符串，`__rgRedirect.pixel` 是 1×1 透明图的 data URL，并对该主机 `prevent-fetch`。`$replace` 在页面载入后改主框架 HTML，并改写之后 fetch/XHR 读到的文本；二进制响应跳过。`$jsonprune` 不丢弃整条规则，也不拦截该请求，而是交给 json-prune，让匹配 URL 的 fetch/XHR JSON 删掉指定字段。只闭合 JSON 局部变量的隔离函数在页面里同步返回；不能序列化的闭包由 `iso-call` 在隔离世界执行，结果写回页面，不再使用会卡住网页进程的同步请求。元素选择器确认后写入自定义规则并立刻隐藏。内容拦截页可以一键订阅 `https://easylist.to/easylist/easylist.txt`，下载后的列表会编译并安装，不内置整份 EasyList。
- 暗黑模式是样式表（Off / Auto / On，站点可覆盖），给文字节点上色，`img` / `video` / `picture` / `canvas` / `svg` 保持 `filter:none`，不用整页 `invert`。
- 阅读模式抽出标题、作者和带标签的块（标题、段落、图片、链接），字号、字体、行高和主题写进 `ReaderSettings` 并作用到阅读页。
- 翻译读取 `BrowserSettings.translationBackend`。选择器只有 Apple 设备端；存的是 `apple` 时才会创建 `TranslationSession`。其它值会显示错误，不会假装译完。语言列表是可以交给系统的目标语言。正文会分批译完，翻译页开着时会继续补译新出现的文字。设备没下载的语言包由系统报错。需要 iOS 18。
- 媒体嗅探会列出 m3u8 / mpd 变体。有 `Content-Length` 或 `Content-Range` 时显示大小。下载带上页面 Cookie。不处理 FairPlay / Widevine。
- 视频菜单的全屏和 AirPlay 调用页面上的 `webkitEnterFullscreen` / `webkitShowPlaybackTargetPicker`（以及标准全屏）。
- 二维码扫描后可以打开、搜索或复制；打开会导航。
- 钥匙串自动填充仍是点按后填入，编辑项含地址。列表里支付条目只显示末四位；点按填入时 `cardNumber` 用钥匙串里保存的卡号。不写 UserDefaults。打开自动填充页会在 iCloud 可用时读取私有数据库 `iCloud.com.dandibbert.Rikugan` 的 `AutofillVault` 记录并按 id 合并回钥匙串。未签名 IPA 没有可用的 iCloud 容器，读取失败就继续用钥匙串。图片页的「打开原图」在查看器里用当前身份的 Cookie 加载图片，返回仍留在原页面。
- 实验控制台收集页面 `console.log` / `info` / `warn` / `error` 和未捕获错误。完整检查器仍是 Safari 的 Develop（`isInspectable`），本 App 不是 Web Inspector。
- 字体按身份应用到网页。正文、标题和等宽分开设置，站点可以覆盖，也可以选不覆盖。样式不使用 `*` 选择器，并写回 Material Icons、Font Awesome 和 iconfont。ttf / otf / ttc 交给 Core Text。woff / woff2 无法由 Core Text 注册，导入会被拒绝。备份是 formatVersion 3，导入前可预览并选择合并或替换；密码、Cookie、扩展二进制和字体文件字节不在文件里。连点设置里的版本号打开诊断页。PlayCover 和模拟器的结果都不是 iPhone 通过，步骤在 `docs/TESTING.md`。第三方扩展没有在 WKWebView 里跑过，见 `docs/EXTENSION_COMPATIBILITY.md`。

浏览数据（标签、历史、书签、Cookie）没有 iCloud 同步。自动填充可以尝试写入上面的私有数据库；未签名包会失败并留在钥匙串。分享扩展在未签名 IPA 里编进包，但 App Group 要等带该 entitlement 的描述文件重签后才真正共享文件；短链接仍可通过 `rikugan://` 唤起主 App。

## 构建与验证

GitHub Actions（`.github/workflows/build.yml`，`macos-15`）在 `main`、`cursor/**` 推送、pull request 或手动触发时：生成资源和 Xcode 项目 → 用 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`、`CODE_SIGN_IDENTITY=''` 编译真机目标 → 把 `.app` 放进 `Payload/` 并打成 `Rikugan-0.2.0-unsigned.ipa` → **立刻上传 artifact** → 再跑模拟器单元和 UI 测试。测试失败不会撤掉已经上传的 IPA。只有 `main` 推送且测试成功时才发 prerelease。不需要签名用的 secret。

```bash
brew install xcodegen
python3 scripts/prepare_resources.py
node scripts/test_runtime.cjs
node scripts/test_page_tools.cjs
node scripts/test_extension_bridge.cjs
xcodegen generate
xcodebuild -project Rikugan.xcodeproj -scheme Rikugan \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' ARCHS=arm64 build
mkdir -p dist/Payload
cp -R build/Build/Products/Release-iphoneos/Rikugan.app dist/Payload/
( cd dist && zip -qry Rikugan-0.2.0-unsigned.ipa Payload )
```

自动化 UI 测试使用 CI 上 `127.0.0.1:8765` 的测试网页，不依赖公共网站：安装内置示例 → 验证脚本/扩展注入 → 检查 GM 存储 → 检查扩展后台通信、`chrome.scripting` 写入的「脚本注入成功」、`chrome.notifications.create` 的「通知已创建」和 popup → 写入 Cookie/localStorage → 新身份确认无数据且无扩展/脚本 → 切回验证数据保留。

真实设备重签安装、键盘交互、长期内存压力，以及具体第三方扩展的兼容性，仍需要设备上验证；模拟器测试不能替代这些。

## 主要目录

`Models.swift`：数据结构、脚本元数据、URL 权限与 ZIP 检查。`FeatureModels.swift` / `StateMigration.swift`：标签组、站点设置、搜索建议、播放列表解析、备份和 schema 1 升级。`AppModel.swift`：持久化与身份切换。`BrowserSession.swift` / `SessionFeatures.swift`：标签、查找、下载接入和内容规则。`Windows.swift`：第二个窗口复用 `BrowserSession` 的 `BrowserTab`。`DownloadCenter.swift`：URLSession 与 WKDownload。`ExtensionHost.swift` / `ExtensionPackage.swift`：WebExtension 宿主、CRX、更新 XML 和兼容表。`AdBlockEngine.swift`：广告规则子集。`UserScriptEngine.swift` / `UserscriptRuntime.js`：隔离桥接与 GM API。`PageTools.js`：暗黑样式、阅读结构、查找计数、媒体列表、元素选择和填充。`BrowserUI.swift` / `AddonsUI.swift` / `ToolsUI.swift`：界面。`ShareExtension/`：系统分享。`Tests` / `UITests`：测试。

## Apple / WebKit 参考

- https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
- https://developer.apple.com/documentation/webkit/wkwebextension
- https://developer.apple.com/documentation/webkit/wkwebextensioncontroller
- https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)

