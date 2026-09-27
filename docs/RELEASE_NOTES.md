## Rikugan 1.0 · 未签名 IPA

原生 SwiftUI + WKWebView 浏览器（iOS / iPadOS 17+），按 spec 实现：

- 多标签页（WKWebView 常驻，切换不重载）、类 Safari 标签页组、无痕浏览、恢复关闭的标签页、iPad 标签栏 / 侧边栏 / 多窗口
- 地址栏搜索与 9 个内置搜索引擎 + 自定义引擎 + 关键词快捷方式 + 搜索建议
- 用户脚本管理器：`.user.js` 安装页、文件 / 分享 / 网址 / 粘贴 / 新建，GM_* API（值存储、XHR、样式、菜单命令、资源、下载、通知…），带行号的编辑器，更新检查
- Chrome MV3 兼容运行时：ZIP / CRX / 文件夹 / Chrome 应用商店 / Edge 加载项安装，权限确认，content scripts、后台 Service Worker、popup、storage、runtime 消息与 Port、scripting、tabs、permissions、action、DNR 等（见 App 内兼容性矩阵）
- 内容拦截：内置规则、AdGuard / EasyList 订阅、自定义规则、元素选择隐藏
- 网页深色模式、自定义网页字体（描述文件安装的字体 + 导入字体文件）、阅读模式、整页翻译
- 媒体嗅探 / HLS 下载 / 画中画、图片模式批量保存、下载管理（暂停 / 继续）、PDF / 打印、二维码、定时刷新、页面跳转控制、网站设置与网页权限、自动填充（钥匙串）、身份（Profiles）、设置与标签页导入导出、分享扩展、应用内网页检查器

**IPA 没有签名**：请用自己的证书 / 侧载工具（AltStore、Sideloadly、TrollStore 等）重签后安装。`SHA256SUMS.txt` 用于校验。

本版本由 GitHub Actions 编译；同一次运行中包含 Swift 单元测试、JS 运行时测试和模拟器端到端自检（测试扩展 + 测试脚本在本地页面上真正运行）。详见 README。
