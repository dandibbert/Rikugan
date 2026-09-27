## Rikugan 0.1.0 · 首个可测试版本

原生 SwiftUI 浏览器，支持 WebKit WebExtension、常用用户脚本和独立身份空间。无内购、无账户服务。

下载 `Rikugan-0.1.0-unsigned.ipa`，**先用自己的证书/侧载工具重签**。最低 iOS 18.4，arm64。`SHA256SUMS.txt` 用于文件校验。

从首页「扩展与脚本」导入 ZIP / `.user.js`，或安装自检示例。底部人物图标切换独立身份。改变扩展或脚本后刷新目标网页。

本 release 由成功完成真机目标编译及模拟器测试的 GitHub Actions 发布。测试日志和 `.xcresult` 在对应运行的 Test Evidence artifact 中。真实设备安装和具体第三方扩展尚需验证；这不是完整 Chrome 或 Tampermonkey 的兼容替代。

不含 iCloud、默认浏览器特权、入站分享扩展、CRX 原生导入和扩展商店自动更新。详细兼容范围与脚本 API 限制请阅读 README。

