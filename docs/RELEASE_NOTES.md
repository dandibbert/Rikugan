## Rikugan 1.0 · 未签名 IPA（claude 分支测试版）

原生 SwiftUI + WKWebView 浏览器（iOS / iPadOS 17+）。

新图标，并可在 设置 → 外观与工具栏 → App 图标 中切换三种图标（脉冲 / 星轨 / 新星）。

本版本重点是**可测试、可长期使用**：

- 标签页生命周期：active / 后台存活 / 挂起 / 恢复中 / 进程终止；超过上限（默认 5）的后台标签页按 LRU 释放 WebView，保存网址、历史、滚动位置与快照，切回时恢复；内存警告时挂起全部后台标签页
- 完整的类 Safari 标签页组：创建、重命名、调整顺序、删除（关闭其标签页或移到默认组）、拖动排序、跨组移动、重启恢复当前组与当前标签页
- 扩展后台运行时状态机：启动期间的消息 / 事件 / Port 排队，启动失败明确报错，空闲挂起（有 Port 时不挂起）、按需唤醒
- 按方法的 Chrome API 矩阵（CI 与实现逐方法核对）；DNR redirect / modifyHeaders 在 WebKit 支持时启用（运行时探测）
- 用户脚本安全边界：特权 GM 调用只接受来自该脚本隔离环境（WKContentWorld）的消息，页面可见的令牌已移除；页面环境脚本（`@grant none` / 页面安全授权 / `@inject-into page`）没有特权桥，特权 GM API 明确报错（见 docs/SECURITY.md）
- 扩展隔离：Port 按扩展命名空间、只允许端点本身发送 / 断开；伪造身份的调用被拒绝并记录
- 网页字体：正文 / 标题 / 等宽分别设置、每站点覆盖或禁用、TTC 导入、图标字体与 emoji 保护
- 导入导出 `rikugan-archive` v2：明确的包含 / 排除内容、校验、v1 迁移、预览、合并 / 替换、导入前自动备份
- 诊断页（设置 → 开发者）：构建信息、生命周期计数、扩展后台状态（驻留、唤醒 / 冷启动 / 卡住恢复计数、活动端口）、WKWebView 计数、安全拒绝记录、功能开关、兼容矩阵版本、DNR 跳过摘要、人工测试状态，可导出为单个不含敏感信息的 JSON
- 设置 → 开发者：扩展后台运行时控制（挂起 / 唤醒 / 停止并重建 / 全部挂起 / 全部唤醒 / 状态时间线 / 清除错误计数）、人工测试清单、安全拒绝记录；设置页底部显示已安装的 commit

**IPA 没有签名**：请用自己的证书 / 侧载工具（AltStore、Sideloadly、TrollStore 等）重签后安装。`SHA256SUMS.txt` 用于校验。

本版本由 GitHub Actions 编译，同一次运行中通过了：Swift 单元测试、JS 运行时测试、API 矩阵校验，以及**模拟器**中的 core / pageworld / security / fonts / dnr / lifecycle / stress / archive 套件（每个套件的结果都用本次运行的随机 runID 校验，旧结果无法冒充）（Job Summary 中有逐项结果）。这些是模拟器结果，不代表真机结果；真机请按 docs/DEVICE_CHECKLIST.md 验证。
