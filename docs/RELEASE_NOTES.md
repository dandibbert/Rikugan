## Rikugan 0.4.0

新增 `.user.js` 文件与源码分享安装、多项持久分享队列、逐个权限确认及待处理分享管理；新增 GM 跨标签/iframe value-change listener 与同步存储镜像，保持普通/无痕/身份/脚本隔离。分享安装不自动执行源码，缺少 App Group 会明确提示。

GM XHR 新增实际取消、超时、进度事件及 FormData/二进制上传，保留 @connect/重定向校验和 Cookie 隔离。扩展可直接从工具栏打开 popup，固定测试扩展补充 Port、scripting、权限和 DNR 的实际效果测试。完整 Worker、第三方扩展及真实设备分享资格仍不冒充已验收。

本轮补齐标签懒加载/内存回收与恢复、v2→v3 备份迁移及引用校验，修复无痕新标签/GM 存储隔离、脚本元数据更新和重装保留数据。导航和媒体下载统一使用发起页面的 WKDownload，增加进度、暂停、服务器支持时的续传、失败/取消和原身份归档。

广告拦截现已补充真实 WebKit 规则编译、请求阻断、白名单放行和元素隐藏测试，并修正原来的正则与规则排序问题。主页面跳转前应用目标站点开关；关闭最后一个无痕标签/切换身份时终止未完成的无痕下载，释放临时网站数据，保留用户已经保存的文件。

`tests.zip` 包含真实测试结果、日志、源码与夹具；`SHA256SUMS.txt` 同时覆盖 IPA 和 tests.zip。真实设备未测试，不把模拟器结果冒充真机验收。完整边界见 `docs/IMPLEMENTATION_STATUS.md`。

原生 SwiftUI 浏览器。扩展仍由 iOS 18.4 的 WKWebExtension 运行，不是自研的完整 `chrome.*`。这一版补上接近 Teak 的浏览面：用户脚本 `@resource` 与 Partial `unsafeWindow`、CRX 与商店下载、广告规则子集、无痕标签、标签组、阅读 / 翻译 / 媒体工具、钥匙串自动填充、网页字体，以及 Share Extension。

下载 `Rikugan-0.4.0-unsigned.ipa`，**先用自己的证书或侧载工具重签**。最低 iOS 18.4，arm64。功能分支和 pull request 的同一份未签名 IPA 在 workflow artifact `Rikugan-unsigned-IPA` 里，不依赖 prerelease。

从首页「扩展与脚本」导入 ZIP、CRX 或 `.user.js`，或安装自检示例。设置里的兼容表会标明 Supported、Partial 和 Unsupported。未实现的扩展 API 不会被记成成功。

**普通证书版使用后台页面兼容模式**：MV3 Service Worker 入口转为非持久后台页面，仍用原生 WebExtension 消息、存储和弹窗；原安装包保留不变。不是完整 Worker 模拟器，不保证使用 importScripts / Worker 生命周期 / clients 的扩展可用。安装预览和详情会标注限制。

网页字体支持系统字体、可见的描述文件字体及 ttf/otf/ttc 导入；常见图标和符号字体不会被统一覆盖，可按网站关闭。备份先预览再合并或替换，并自动保留导入前的资料恢复副本。

本 release 由成功完成真机目标编译及模拟器测试的 GitHub Actions 发布。测试日志和 `.xcresult` 在对应运行的 Test Evidence artifact 中。真实设备安装和具体第三方扩展尚需验证。

不含默认浏览器特权、iCloud，也不播放 FairPlay / Widevine。分享扩展的 App Group 要在重签描述文件里启用。详细范围见 README。
