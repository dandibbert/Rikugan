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
| Simulator: security | 对抗测试：恶意页面（18 项伪造尝试：GM 存储 / XHR / 标签页 / 菜单 / 通知、冒充页面环境脚本、冒充扩展 A 的内容脚本 / 页面 / 后台、工具通道、跨源历史、分发函数）与恶意扩展 B（冒充 A 读写存储、发消息、调用 tabs、注入 / 断开 A 的 Port、冒充用户脚本）。**断言效果**：受害者的值 / 存储 / Port / 标签页 / 菜单 / 规则 / 历史都不变，拒绝都有记录，合法路径仍可用，诊断导出不泄露秘密。详见 [SECURITY.md](SECURITY.md) | 是 |
| Simulator: fonts | 导入 TTF 与 TTC（拆分为两个字体）；正文 / 标题 / 等宽规则；图标字体（class、私有区字符、连字图标）不被替换；emoji 回退；页面自定义 @font-face；动态插入内容；实时生效；网站覆盖、网站禁用、排除列表。用专门的测试字体（`x` 宽 2em、图标宽 3em）按**像素宽度**判定是否真正渲染 | 是 |
| Simulator: dnr | 以本地服务器请求日志判定：image / stylesheet / script / XHR / fetch / font / media / sub_frame / main_frame 的 block（每项都有对照请求，对照未到达则判为“无法判定”而非通过）；allow 优先级；redirect 与 modifyHeaders（WebKit 支持则验证生效，不支持则验证被明确跳过并报告）；卸载后规则移除。**下载 / 媒体（规则生效期间）**：被 block 的下载不发请求、不产生下载项；普通下载（WKDownload）与直接下载（URLSession）字节完全一致（文件内容里含被拦截的网址字符串）；被跳过的 redirect / modifyHeaders 规则不会让下载被改写、改名或被报告为拦截；媒体嗅探仍能检测到 HLS 与 MP4，被 DNR 拦截的媒体请求不会被列为可下载；HLS 下载分段按序拼接 | 是 |
| Simulator: lifecycle | 36 个标签页 / 3 个组；LRU 挂起；快速切换 80 次；挂起→恢复（网址、后退历史、滚动位置）；关闭 / 重新打开；WebContent 终止处理（见下方说明）；移动 / 调整组顺序 / 两种删除组方式；会话快照往返；内存警告；BrowserTab 与 WKWebView 泄漏检查；每步检查“无重复 WebView、注册表一致” | 是 |
| Simulator: stress | 扩展后台运行时 30 轮：冷启动→消息、冷启动→Port、启动中发消息（排队）、3 个并发 Port、存储往返、空闲→挂起、唤醒（验证是新的运行时实例）、打开的 Port 阻止挂起、关闭标签页时 Port 断开、启动期间 Popup 发消息、关闭。**每步有独立期限，不重试；任何一轮失败即任务失败** | 是 |
| Simulator: archive | 真实存储上的 导出→重置→导入（替换）、合并两次不重复、损坏 / 未来版本 / 非本应用文件被拒绝且数据不变、v1 文件迁移、导入前备份 | 是 |
| Simulator: real extension compatibility (report) | 下载真实扩展（Dark Reader、uBlock Origin Lite、Violentmonkey 来自 GitHub Releases；Tampermonkey、沉浸式翻译来自 Chrome 应用商店 CRX），记录来源、版本、sha256，逐个隔离安装并按领域记录观察结果（见 [COMPATIBILITY.md](COMPATIBILITY.md)） | 否（报告性质；下载失败记录为“未测试”，不会伪装成通过或失败） |

每个模拟器任务都会：

- 在 Job Summary 中输出逐项结果表；
- 上传 `selftest-<suite>` artifact（JSON 报告、`.xcresult`、日志）。JSON 报告的 `environment` 字段是 `simulator`。

**结果完整性（防止旧结果或伪造结果通过）**：

1. 每次调用前，任务生成随机 runID（`ci-<run>-<attempt>-<suite>-<UUID>`）并记录开始时间；runID 经 `TEST_RUNNER_RIKUGAN_RUN_ID` → UI 测试 → App 启动参数 `-RikuganRunID` 传入 App。
2. App 在套件开始时删除该套件旧的报告。报告中写入：`runID`、`suiteName`、`processID`、`processLaunchedAt`、`startedAt`、`finishedAt`（未完成时为 null）、`result`（PASS / FAIL / IN PROGRESS）、`assertionCount`、`failureCount`。
3. UI 测试要求屏幕上的结果文字包含本次的 runID。
4. 之后 `scripts/verify_selftest_result.py` 独立校验 JSON，不满足以下任一条件即任务失败：
   - runID、套件名一致；
   - `finishedAt` 存在且不早于 `startedAt`；
   - 两个时间都晚于本任务开始时间；
   - 进程启动时间不晚于套件开始时间（崩溃后重启、再跑出旧结果的情况会被识别）；
   - 断言数不少于该套件的下限（`build.yml` 中的 `min`），且与记录的结果条数一致；
   - 失败数与结果一致；结果为 PASS。
   
   超时未产生新结果时，报告不存在或仍为 IN PROGRESS，都算失败。
5. 因此 XCUITest 自身的快照超时可以只记录、不判失败：判定通道是这份校验过的报告。
6. `scripts/test_verify_selftest.py`（core 任务中运行）有 15 个负面测试，包括“上一次运行留下的 PASS 被拒绝”“同一 runID 但早于任务开始”“崩溃重启”“截断”“计数不一致”。compat 是报告性质，允许 FAIL，但仍要求结果是本次、已完成。

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
| 36324268080 | d499558 | 未完成：XCUITest 快照超时（之后改为只记录不失败） |
| 36325781215 | 7c4e32e | 29/30：128 次启动中 2 次导航未开始 |
| 36326890854 | 5b24cab | 27/30：129 次中 5 次，换新 WebView 后仍卡住（都在“挂起后唤醒”） |
| 36329596521 | 8fa1d76 | **30/30**，改为挂起时保留 WebView（about:blank）之后 |
| 36331210498 | 6ab6af0 | **30/30（284 s），129 次启动中 0 次导航未开始** |
| 36372804939 | a4b4174（图标，未改后台代码） | 第 1 次：**29/30**，130 次启动中 1 次卡住：第 26 轮挂起后唤醒，复用的驻留 WebView 与换上的新 WebView 都停在 isLoading=true、progress=0.10，扩展 scheme handler 从未收到请求；只重跑失败任务一次：通过 |
| 36334562568 / 36335924012 | 5fdc72e（中途取消）/ bb8ffc2 | bb8ffc2：**30/30（264.5 s），129 次启动中 0 次导航未开始**；结果经 runID 校验 |
| 36332418737 | 3cfe319（仅文档） | **28/30**：130 次启动中 3 次导航未开始；第 16 轮（冷启动→sendMessage）与第 22 轮（挂起后唤醒）在换新 WebView 后仍卡住 → 任务失败 |

随后 commit 8cb052f 的 core 套件出现了同一现象：新建的后台 WKWebView 调用 `load()` 后，WebKit **60 s 内都没有开始导航**（时间线只有 `launch starting`）。同一 App 中的测试页、扩展 Popup（同类配置）都正常加载，主线程也在响应。所以这不是“慢”，而是新建 WebView 的导航偶发地卡在 WebKit 内部，根因在 WebKit 的进程启动 / 导航派发中，无法从外部确认。

处理（commit 之后的版本）：

- 后台页面的导航若 5 s 内没有开始，丢弃该 WebView，换一个全新的，每次启动最多一次。正常情况下导航在 0.7–2.2 s 内开始（CI 冷启动模拟器也包括在内），5 s 是实测最慢正常启动的 2 倍以上。
- 换过仍不开始，则明确失败（与之前相同）。
- 每次恢复都写入后台时间线、诊断页（`stuckStartRecoveries`）和错误日志；stress 报告中有一行专门记录次数。
- 这是有上限、可见的恢复，不是无限重试。测试期限没有加长，stress 中任何失败轮次仍会让任务失败。
- 真机上需要按真机清单第 4 节验证，并在诊断页查看该计数。

后续证据（run 36326890854）：把期限改为 5 s 后，129 次启动中有 5 次被判为“未开始”，其中 3 次换了新 WebView 仍然卡住，3 轮失败，**且全部发生在“挂起后唤醒”这一步**。结合之前的失败（stop 后立即 start、挂起后唤醒）：卡住的都是**刚销毁旧的后台 WebView 后立即新建的 WebView**；长期存在的标签页 WebView、Popup 从未出现。

据此修改设计：挂起时不再销毁 WebView，而是导航到 `about:blank`。JS 上下文被销毁，语义与 MV3 Service Worker 被终止相同：内存状态全部丢失，唤醒后重新注册监听器。唤醒时在同一个 WebView 中重新加载后台页，不再反复新建。代价是每个挂起的扩展保留一个空闲的 WebContent 进程；系统结束该进程时会释放这个 WebView。新建时卡住的恢复机制（5 s）保留，用于冷启动。

实测频率（修改前）：run 36325781215 中 128 次后台启动有 2 次导航未开始，均被恢复。但当时等待期限是 10 s，其中一次恢复太慢，所在那一轮仍超出了测试自己的 15 s 消息期限（29/30）。之后把期限改为 5 s，测试期限不变。

**3cfe319 之后的结论（如实记录）**：保留 WebView 的设计降低了频率，但没有消除问题，冷启动与唤醒都仍会偶发卡住。按本阶段要求，没有设备证据之前**不再修改这一架构**，只增加证据采集：

- 卡住时记录 WebView 自身状态（isLoading、进度、URL、是否在窗口中）、同时加载中的标签页数、各用途 WKWebView 数量；
- 保留最近一次失败启动的完整时间线；
- stress 报告先列证据，再列摘要。

诊断页与“开发者 → 扩展后台运行时”中可以看到每个扩展的唤醒次数、冷启动次数、卡住恢复次数和状态时间线，用于在 PlayCover / 真机上收集同类证据。若 stress 再次失败，CI 为红，不会发布。

**pageworld 的一次未解释失败（如实记录）**：run 36333682693（commit c58d038）中 pageworld 为 6/43。原因是测试标签页始终停在 `about:blank`：所有属性读取为空，页面上相对路径的 `window.open` 报 SyntaxError。随后的 run 36334562568 为 56/56。原因未查明。之后的版本在打开页面后立即记录一项“测试页面加载”（网址、是否在加载、生命周期、服务器是否收到请求），再次出现时会留下证据；我们没有加长期限或增加重试。

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

步骤见 [MANUAL_TESTING.md](MANUAL_TESTING.md)：

1. 校验 IPA；
2. 确认已安装的 commit（设置页底部）；
3. 按顺序执行冒烟清单，在 App 内“人工测试清单”记录结果；
4. 导出单个诊断文件并附在反馈中。

---

## L3 · 真机（手动）

按 [DEVICE_CHECKLIST.md](DEVICE_CHECKLIST.md) 执行。每次记录设备型号、iOS 版本、安装方式（AltStore / Sideloadly / TrollStore / 开发者证书）和 Rikugan 版本 / commit。
