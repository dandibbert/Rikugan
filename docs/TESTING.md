# Rikugan 测试说明

Rikugan 的验证分三级。**每一级只证明它能证明的东西**：CI 模拟器通过 ≠ PlayCover 通过 ≠ iPhone / iPad 真机通过。报告、Release 说明和 Issue 中必须写明结果来自哪一级。

| 级别 | 在哪里跑 | 证明什么 | 不能证明什么 |
|---|---|---|---|
| L1 CI | GitHub Actions（macOS 15、Xcode 16.4、iOS 18.5 SDK、iPhone 模拟器） | 逻辑正确性、WebKit 行为（模拟器中的 WebKit）、运行时状态机、导入导出、字体、DNR、页面世界、真实扩展在模拟器中的表现 | 真机内存压力 / jetsam、真实 WebContent 进程被系统杀死、签名后的 App Group / 分享扩展、键盘 / 触控 / 多任务、真实网络环境 |
| L2 PlayCover 冒烟 | Apple Silicon Mac + PlayCover（以 iPad 应用运行 IPA） | 真实签名后的 IPA 能启动、基本浏览与界面、扩展 / 脚本安装流程、Diagnostics 页面 | iPhone 布局与手势、iOS 内存上限、后台挂起策略、分享扩展（PlayCover 下不可用或行为不同） |
| L3 真机 | 已重签的 IPA 安装在 iPhone / iPad | 最终用户体验：内存、后台、分享扩展、App Group、长时间使用 | —（按 [DEVICE_CHECKLIST.md](DEVICE_CHECKLIST.md) 逐项执行并记录设备型号与系统版本） |

---

## L1 · CI（每次推送自动运行）

工作流：`.github/workflows/build.yml`

| 任务 | 内容 | 是否阻塞发布 |
|---|---|---|
| Core unit tests + JS runtime tests | `swift test`（`CoreTests/`：URL 匹配、元数据、manifest、ZIP/CRX、过滤规则、DNR 转换含 redirect/modifyHeaders、标签页生命周期策略、标签页组模型、归档格式 / 迁移 / 损坏文件、字体解析 / TTC 拆分、API 矩阵 JSON）；`node scripts/test_js.cjs`（GM API、chrome.* shim、**API 矩阵与 JS shim / 原生桥逐方法比对**） | 是 |
| Build unsigned IPA | Release、`iphoneos`、无签名；必须出现 `** BUILD SUCCEEDED **` 且二进制存在 | 是 |
| Build for simulator tests | `build-for-testing` 一次，产物供下列任务复用 | 是 |
| Simulator: core | 原有端到端自检：测试扩展（内容脚本、消息、Port、存储、Popup、scripting、权限、后台、DNR、Unsupported API）+ 测试脚本（GM API、@exclude、刷新、无痕）+ 元素隐藏 | 是 |
| Simulator: pageworld | 真实页面上的 `@grant none` / 已授权隔离脚本 / `unsafeWindow` 读写调用 / `@inject-into page`；事件双向；reload、pushState、同源 iframe、`window.open` 新标签页 | 是 |
| Simulator: fonts | 导入 TTF 与 TTC（拆分为两个字体）；正文 / 标题 / 等宽规则；图标字体（class、私有区字符、连字图标）不被替换；emoji 回退；页面自定义 @font-face；动态插入内容；实时生效；网站覆盖、网站禁用、排除列表。用专门的测试字体（`x` 宽 2em、图标宽 3em）按**像素宽度**判定是否真正渲染 | 是 |
| Simulator: dnr | 以本地服务器请求日志判定：image / stylesheet / script / XHR / fetch / font / media / sub_frame / main_frame 的 block（每项都有对照请求，对照未到达则判为“无法判定”而非通过）；allow 优先级；redirect 与 modifyHeaders（WebKit 支持则验证生效，不支持则验证被明确跳过并报告）；卸载后规则移除；HLS / 下载作为观察项记录 | 是 |
| Simulator: lifecycle | 36 个标签页 / 3 个组；LRU 挂起；快速切换 80 次；挂起→恢复（网址、后退历史、滚动位置）；关闭 / 重新打开；WebContent 终止处理（见下方说明）；移动 / 调整组顺序 / 两种删除组方式；会话快照往返；内存警告；BrowserTab 与 WKWebView 泄漏检查；每步检查“无重复 WebView、注册表一致” | 是 |
| Simulator: stress | 扩展后台运行时 30 轮：冷启动→消息、冷启动→Port、启动中发消息（排队）、3 个并发 Port、存储往返、空闲→挂起、唤醒（验证是新的运行时实例）、打开的 Port 阻止挂起、关闭标签页时 Port 断开、启动期间 Popup 发消息、关闭。**每步有独立期限，不重试；任何一轮失败即任务失败** | 是 |
| Simulator: archive | 真实存储上的 导出→重置→导入（替换）、合并两次不重复、损坏 / 未来版本 / 非本应用文件被拒绝且数据不变、v1 文件迁移、导入前备份 | 是 |
| Simulator: real extension compatibility (report) | 下载真实扩展（Dark Reader、uBlock Origin Lite、Violentmonkey 来自 GitHub Releases；Tampermonkey、沉浸式翻译来自 Chrome 应用商店 CRX），记录来源、版本、sha256，逐个隔离安装并按领域记录观察结果（见 [COMPATIBILITY.md](COMPATIBILITY.md)） | 否（报告性质；下载失败记录为“未测试”，不会伪装成通过或失败） |

每个模拟器任务都会：

- 在 Job Summary 中输出逐项结果表；
- 上传 `selftest-<suite>` artifact（JSON 报告、`.xcresult`、日志）。JSON 报告的 `environment` 字段是 `simulator`。

**测试原则**：等待一律是“轮询一个具体条件直到固定期限，失败时报告观察到的状态”，不使用固定 sleep 掩盖竞态，不重试被测操作，不因为超时而加长期限。

**XCUITest 快照超时**：App 忙时（套件跑在主线程上），XCUITest 自己的无障碍快照可能超时。UI 测试只记录并计数这类超时，然后继续等待；是否通过只看套件的 `SELFTEST … PASS n/n` 结果。stress 套件每轮结束都写一次报告，即使 App 被结束也能留下证据。

**WebContent 终止说明**：iOS 没有公开 API 可以杀死 WebContent 进程，lifecycle 套件直接调用 Rikugan 的终止处理函数（与 `webViewWebContentProcessDidTerminate` 调用的是同一函数），验证状态迁移与恢复路径；系统真实杀进程只能在真机上验证（见真机清单）。

### 已知的间歇性问题（如实记录）

stress 套件在连续 3 次完整运行中的结果：

| run | commit | 结果 |
|---|---|---|
| 36318483508 | d8cb557 | 30/30 轮通过（228 s） |
| 36320615750 | 1e4e788 | **28/30**：第 6、11 轮失败 |
| 36321777638 | 84b0094 | 30/30 轮通过 |

随后 commit 8cb052f 的 core 套件出现了同一现象：新建的后台 WKWebView 调用 `load()` 后，WebKit **60 s 内都没有开始导航**（时间线只有 `launch starting`）。同一 App 中的测试页、扩展 Popup（同类配置）都正常加载，主线程也在响应。所以这不是“慢”，而是新建 WebView 的导航偶发地卡在 WebKit 内部，根因在 WebKit 的进程启动 / 导航派发中，无法从外部确认。

处理（commit 之后的版本）：

- 后台页面的导航若 10 s 内没有开始，丢弃该 WebView，换一个全新的，每次启动最多一次。
- 换过仍不开始，则明确失败（与之前相同）。
- 每次恢复都写入后台时间线、诊断页（`stuckStartRecoveries`）和错误日志；stress 报告中有一行专门记录次数。
- 这是有上限、可见的恢复，不是无限重试。测试期限没有加长，stress 中任何失败轮次仍会让任务失败。
- 真机上需要按真机清单第 4 节验证，并在诊断页查看该计数。

### 本地运行

```bash
swift test && node scripts/test_js.cjs
brew install xcodegen && xcodegen generate
# 全部 UI 套件（模拟器）
xcodebuild test -project Rikugan.xcodeproj -scheme Rikugan -destination 'platform=iOS Simulator,name=iPhone 16'
# 单个套件
xcodebuild test -project Rikugan.xcodeproj -scheme Rikugan -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RikuganUITests/BrowserUITests/testBackgroundStressSuite
# 真实扩展报告：先下载，再把 compat/ 放进 App 包里的 SelfTest/compat/
python3 scripts/fetch_compat_extensions.py compat-packages
```

App 内：设置 → 自检，可选择任意套件运行（会修改当前身份中的标签页、设置和测试扩展 / 脚本）。以 `-RikuganSuite <name>` 启动会自动运行。

---

## L2 · PlayCover 冒烟测试（手动）

PlayCover 把 iOS 应用作为 iPad 应用运行在 Apple Silicon Mac 上。它适合快速确认**签名后的 IPA** 能启动和基本可用，但它不是 iPhone：内存上限、后台策略、分享扩展、App Group、触控手势都不同。**PlayCover 通过不得记为 iPhone / iPad 通过。**

1. 下载 CI 发布的 `Rikugan-*-unsigned.ipa`，校验 `SHA256SUMS.txt`。
2. 在 PlayCover 中导入 IPA（PlayCover 会自行签名）。
3. 启动后打开 设置 → 开发者 → 打开诊断，记录：版本、Git commit、构建时间、设备（应显示 Mac 的 iPad 形态）、App Group 状态、分享扩展状态。
4. 冒烟项（每项记录 通过 / 失败 / 不适用）：
   - [ ] 打开 https://example.com、搜索关键词、前进后退、刷新
   - [ ] 新建 10 个标签页，创建 2 个组，拖动排序，切换组，重启 App 后标签页与组恢复
   - [ ] 设置 → 自检 → 运行 `core`，结果为 PASS（记录 n/m）
   - [ ] 设置 → 自检 → 运行 `pageworld`、`fonts`、`archive`
   - [ ] 安装一个 `.user.js`（例如 Greasy Fork 上的脚本），确认在目标网站运行
   - [ ] 从文件安装一个扩展 ZIP，打开 Popup
   - [ ] 导出归档 → 重置（导入空归档或删除数据）→ 导入，确认恢复
   - [ ] 诊断 → 导出诊断信息，确认 JSON 中没有网址路径、Cookie、密码
5. 结果记录格式：`PlayCover <版本> · macOS <版本> · <Mac 型号> · Rikugan <版本 / commit> · 结果`。

---

## L3 · 真机（手动）

按 [DEVICE_CHECKLIST.md](DEVICE_CHECKLIST.md) 执行。每次记录设备型号、iOS 版本、安装方式（AltStore / Sideloadly / TrollStore / 开发者证书）和 Rikugan 版本 / commit。
