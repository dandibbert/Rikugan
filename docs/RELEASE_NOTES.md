## Rikugan 0.2.0

原生 SwiftUI 浏览器。扩展仍由 iOS 18.4 的 WKWebExtension 运行，不是自研的完整 `chrome.*`。这一版补上接近 Teak 的浏览面：用户脚本 `@resource` 与 Partial `unsafeWindow`、CRX 与商店下载、广告规则子集、无痕标签、标签组、阅读 / 翻译 / 媒体工具、钥匙串自动填充、网页字体，以及 Share Extension。

下载 `Rikugan-0.2.0-unsigned.ipa`，**先用自己的证书或侧载工具重签**。最低 iOS 18.4，arm64。`SHA256SUMS.txt` 用于文件校验。功能分支和 pull request 的同一份未签名 IPA 在 workflow artifact `Rikugan-unsigned-IPA` 里，不依赖这次 prerelease。

从首页「扩展与脚本」导入 ZIP、CRX 或 `.user.js`，或安装自检示例。设置里的兼容表会标明 Supported、Partial 和 Unsupported。未实现的扩展 API 不会被记成成功。

本 release 由成功完成真机目标编译及模拟器测试的 GitHub Actions 发布。测试日志和 `.xcresult` 在对应运行的 Test Evidence artifact 中。真实设备安装和具体第三方扩展尚需验证。

不含默认浏览器特权、iCloud，也不播放 FairPlay / Widevine。分享扩展的 App Group 要在重签描述文件里启用。详细范围见 README。
