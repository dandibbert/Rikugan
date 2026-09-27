# 测试分层

PlayCover 上的结果不是 iPhone 通过。模拟器通过也不是真机通过。

## Level 1 — CI

GitHub Actions 的 `Build and test iOS`：

- `node scripts/test_runtime.cjs`
- `node scripts/test_page_tools.cjs`
- `node scripts/test_extension_bridge.cjs`（含 12 轮 background gate：cold start、queue、port、idle、wake、fail）
- `xcodebuild test` 里的 CoreTests，包括 32 个标签的 suspend 预算、标签组顺序、备份 roundtrip
- Release 未签名 IPA：`CODE_SIGNING_ALLOWED=NO`，artifact 名 `Rikugan-unsigned-IPA`

`logic` job 只跑 node，不下载扩展，也不访问商店。

## Level 2 — PlayCover

用 CI 的 device IPA 在 Mac 上用 PlayCover 做手工冒烟：启动、标签、分组、用户脚本、扩展、popup、background、内容拦截、字体、媒体、导入导出、诊断页。

适合看界面和 WKWebView 是否能起来。不能代替下面这些：

- Share Extension、App Group、默认浏览器 entitlement
- 系统字体描述文件、相机、照片、画中画、AirPlay
- 内存压力、WebContent 被系统杀掉、触摸和安全区
- 第三方扩展的真实页面效果

诊断页在「设置与下载」里连点版本号后出现。导出的 JSON 不含历史、Cookie、密码或页面正文。

## Level 3 — 真机

安装重签后的 IPA，至少核对：

- Share Extension 和 App Group
- 默认浏览器是否出现在系统设置（未签名包不会出现）
- 描述文件安装的字体是否出现在字体列表
- 相机、照片、画中画、文件 App
- `rikugan://` 和外部 App 跳转
- 打开 30 个以上标签后，诊断页里的 Live WebView 数量停在预算内，旧标签显示已暂停
- 系统杀掉 WebContent 后，页面提示重新加载，而不是假装 JS 堆还在
- Dark Reader、uBlock Origin Lite、Violentmonkey 的实际页面效果

## 已知限制

- 暂停或进程结束后，只重新请求保存的 URL，并尽量恢复滚动位置。后退列表、JS 堆、WebSocket 和未保存的页面状态不会恢复。
- `chrome.declarativeNetRequest` 的 redirect 和 modifyHeaders、`chrome.webRequest`、`chrome.debugger`、`nativeMessaging` 是 Unsupported。
- BackgroundGate 只排队我们桥接层看到的 `sendMessage` / `connect`。WebKit 自己已经在投递的消息不会再包一层 sleep。
- 扩展兼容矩阵是按方法和 WebKit 能力写的，不是商店扩展的运行结果。
- 未签名 IPA 不能当系统默认浏览器。没有 FairPlay / Widevine。
