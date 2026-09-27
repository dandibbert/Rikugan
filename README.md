# Rikugan · 六眼

自用 iOS 浏览器：**WebExtension + 用户脚本 + 多身份**。SwiftUI / WKWebView 原生实现，无内购、无账号服务、无遥测。不使用 Teak 的二进制、代码或购买信息。

## 安装

在仓库 **Releases** 下载 `Rikugan-0.1.0-unsigned.ipa`，使用自己的证书或侧载工具重新签名安装。最低 iOS / iPadOS **18.4**，设备产物为 arm64。IPA **没有签名**，不能直接点开安装；没有随包提供证书。

默认 Bundle ID：`com.dandibbert.Rikugan`。不需要 App Groups、iCloud、默认浏览器或推送的特殊 entitlement。常规个人开发签名的系统要求仍由所用签名工具和 iOS 决定。一个 App 内可建立多个身份，不必多开 IPA。

## 第一版用法

1. 首页 → **扩展与脚本** → 从文件导入 WebExtension ZIP / 目录，或 `.user.js`。ZIP 的根目录必须含 `manifest.json`，不能多套一层文件夹。安装前会展示权限。
2. 用户脚本也支持 HTTPS 直链导入、源码编辑、新建、启停；直接访问 HTTPS `.user.js` 地址会转入确认界面。导入后刷新网页。
3. 扩展列表里的 **打开扩展** 显示 action/popup；详情页可打开选项页、管理网站匹配权限、查看加载错误。
4. 底部 **身份空间** 新建不同身份。网站数据、扩展配置、GM 存储、标签、书签和历史按身份分离。切换时会销毁原身份的页面和运行时，再恢复目标身份；未提交表单和页面内临时 JS 状态不会恢复。
5. 脚本注册的菜单在底部 **更多 → 脚本菜单命令**。下载在 **设置与下载** 或系统「文件 → 我的 iPhone → Rikugan → Downloads」中。

## 扩展支持边界

使用 iOS 18.4 起公开的 `WKWebExtension`、`WKWebExtensionContext`、`WKWebExtensionController`，不是自制 `chrome.*` 全量替代品。支持标准 ZIP/解压目录加载、WebKit 支持的 manifest、content scripts、后台、messaging、storage、action/popup、options、网站权限和基础 tabs/window 宿主。

**不能保证任意 Chrome/Firefox 扩展能直接运行。** CRX 原始格式、商店自动安装/更新、native messaging、桌面多窗口管理及所有桌面专用 API 不在首版范围内。扩展的签名及商店来源不由本 App 验证。不同 iOS 的 WebKit API 支持可能不同。

Profiles 使用稳定 UUID 对应的 `WKWebsiteDataStore(forIdentifier:)`，每个身份也有独立的 `WKWebExtensionController.Configuration(identifier:)`。这是一款 App 内的逻辑分区，不是多个独立安装 App 的 OS 安全边界。

## 用户脚本支持

元数据：`@match`、`@include`、`@exclude`、`@exclude-match`、`@run-at`（start/end/idle）、`@noframes`、`@grant`、`@connect`、HTTPS `@require`。每个脚本最多 8 个依赖，安装时下载并固定保存在该身份中，不自动追踪更新。

常用 API（同时提供适用的同步 `GM_*` 与异步 `GM.*` 接口）：

- getValue / setValue / deleteValue / listValues、info、addStyle、log
- xmlHttpRequest / `GM_xmlhttpRequest`，文本/JSON/arraybuffer/blob 响应
- setClipboard、openInTab、registerMenuCommand / unregisterMenuCommand

明确的兼容限制：

- 带 GM 原生权限的脚本运行在各自 `WKContentWorld` 中；`@grant none` 运行在页面环境。`unsafeWindow`、`@resource`、高级 Tampermonkey 专用 API 暂不实现，未知 grant 会拒绝安装并给出原因。
- 同步 `GM_getValue` 读取当前页面缓存；其他标签修改的值使用异步 `GM.getValue` 读取，或刷新页面。跨标签 value-change listener 尚未实现。存储是 JSON，不支持函数/循环引用/特殊对象序列化。
- GM 网络使用无 Cookie 的 ephemeral URLSession，不自动附带浏览器登录 Cookie。按 `@connect` 检查首个请求和每次重定向；同源默认允许。系统 ATS 对普通 HTTP 原生请求仍可能限制；建议 HTTPS。
- XHR 不支持流式、进度事件、FormData 和完整同步/中间 readyState 语义；`abort()` 当前只中止回调交付，不保证终止底层传输。单次响应限制 8 MB。
- 脚本菜单仅支持顶层页面。DOM 注入不是对所有油猴脚本的完整兼容承诺。

只导入自己信任的脚本与扩展。页面数据可能包括登录后内容，授予 `<all_urls>` 或 `@connect *` 前应审阅源码。

## 浏览器功能

多标签、标签 URL 恢复、地址搜索、前进/后退/刷新、系统分享、查找、桌面版模式、书签、历史、下载、网页对话框和摄像头/麦克风权限请求。iPhone 与 iPad 原生自适应。

首版没有系统默认浏览器资格、iCloud 同步、入站 Share Extension、广告规则订阅管理或完整会话快照。普通网页文件输入由 WebKit/系统处理。

## 构建与验证

GitHub Actions 在 `main` 推送或手动触发时：生成资源和 Xcode 项目 → 真机目标无签名编译 → 模拟器单元和 UI 测试 → 打包 IPA → 发布带校验和的 prerelease。**只有测试成功才发布。** Test Evidence artifact 包含 `.xcresult`、UI 截图和日志。

```bash
brew install xcodegen
python3 scripts/prepare_resources.py
node scripts/test_runtime.cjs
xcodegen generate
xcodebuild -project Rikugan.xcodeproj -scheme Rikugan \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

自动化 UI 测试使用 CI 上 `127.0.0.1:8765` 的测试网页，不依赖公共网站：安装内置示例 → 验证脚本/扩展注入 → 检查 GM 存储 → 检查扩展后台通信和 popup → 写入 Cookie/localStorage → 新身份确认无数据且无扩展/脚本 → 切回验证数据保留。

真实设备重签安装、键盘交互、长期内存压力，以及具体第三方扩展的兼容性，仍需要设备上验证；模拟器测试不能替代这些。

## 主要目录

`Models.swift`：数据结构、脚本元数据、URL 权限与 ZIP 检查。`AppModel.swift`：持久化与身份切换。`BrowserSession.swift`：浏览器与下载。`ExtensionHost.swift`：WebExtension 宿主。`UserScriptEngine.swift` / `UserscriptRuntime.js`：隔离桥接与 GM API。`BrowserUI.swift` / `AddonsUI.swift`：界面。`Tests` / `UITests`：测试。

## Apple / WebKit 参考

- https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
- https://developer.apple.com/documentation/webkit/wkwebextension
- https://developer.apple.com/documentation/webkit/wkwebextensioncontroller
- https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:)

