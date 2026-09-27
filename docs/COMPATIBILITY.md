# 真实扩展兼容性

**结果来源：** CI 任务 “Simulator: real extension compatibility (report)”（iOS **模拟器**，非真机）。每次推送都会重新下载扩展、逐个隔离安装并记录观察结果；本页是某一次运行的快照，最新结果看对应运行的 Job Summary（`selftest-compat` artifact 中有完整 JSON）。

**判定方法：**

- **API 各领域**（storage / messaging / ports / scripting / tabs / dnr）按扩展**实际发出的调用**统计次数与错误数，不从 manifest 推断：
  - `ok`：有调用且无错误；
  - `partial`：部分出错；
  - `fail`：全部出错；
  - `untested`：没有观察到调用。
- **行为**用页面上的可观察效果判定：
  - Dark Reader：注入的 darkreader 样式，以及 body 背景色；
  - uBOL：已知广告脚本在无扩展基线下能加载，装扩展后被拦截，且对照请求仍能加载；
  - 沉浸式翻译：注入的界面元素。
- 下载失败记为“未测试”，不会记为通过或失败。

## 当前结果（CI run 36321777638，commit 84b0094，iOS 26.2 模拟器；与 run 36318483508 结果一致）

| 扩展 | 版本 | 来源 | 安装 | 后台 | 内容脚本 | Popup | storage | messaging | ports | scripting | tabs | DNR | 行为 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Dark Reader | 4.9.133 | GitHub `darkreader-chrome-mv3.zip` | ✅ | ✅ 1.0 s | ✅ | ✅ | ✅ 39 | ✅ 15 | ⚪ | 🟡 ¹ | ✅ | — | ✅ 页面变暗（body `rgb(24,26,27)`） |
| uBlock Origin Lite | 2026.926.2202 | GitHub `uBOLite_*.chromium.zip` | ✅ | ✅ 0.8 s | — | ✅ | ✅ 109 | ⚪ | ⚪ | ✅ | ✅ | 🟡 ² | ✅ 广告脚本被拦截，对照请求正常 |
| Violentmonkey | 2.49.0 | GitHub `Violentmonkey-webext-*.zip` | ❌ ³ | — | — | — | — | — | — | — | — | — | — |
| Tampermonkey | 5.5.0 | Chrome 应用商店 CRX | ✅ | ✅ 0.9 s | — | ❌ ⁴ | ✅ 23 | ✅ | ✅ 6 | ⚪ | ✅ | 🟡 ⁵ | ❌ ⁴ |
| 沉浸式翻译 | 1.33.3 | Chrome 应用商店 CRX | ✅ | ✅ 1.0 s | ✅ | ❌ ⁶ | ✅ 463 | 🟡 ⁶ | ⚪ | ⚪ | ✅ | ❌ ⁶ | ✅ 界面元素已注入 |

（数字为观察到的调用次数；⚪ = 该扩展在测试期间没有调用这类 API。）

具体原因：

1. **Dark Reader scripting**：3 次 `executeScript` 中有 1 次被拒绝（“Cannot access contents of the page”），目标页面不在授予的主机权限内，属于权限检查按预期生效。
2. **uBOL DNR**：
   - 启用的 7 个规则集转换出 **127,757** 条规则，编译成 3 个 WKContentRuleList，耗时 16 s；
   - 1,860 条被跳过并列出：`redirect` 与 `modifyHeaders` 规则，以及 WebKit 正则不支持的 `regexFilter`；
   - 实际效果：在无扩展基线下能加载的广告脚本，安装后被拦截，对照请求仍正常；
   - uBOL 会调用 `chrome.userScripts`（不支持），只影响其“自定义过滤器 / 脚本注入”类功能，报告中有记录。
3. **Violentmonkey**：Chrome 版仍是 **Manifest V2**，安装时被明确拒绝（“仅支持 Manifest V3 扩展（当前 manifest_version = 2）”）。
4. **Tampermonkey**：MV3 版的核心依赖 `chrome.userScripts`（`configureWorld`、`onUserScriptConnect`）和 `webRequest`（`onBeforeRequest` 等），Rikugan 都不提供，所以 Popup 为空，无法用它注入脚本。后台、存储、消息、Port 正常。**替代方案**：Rikugan 内置用户脚本管理器（GM API、`unsafeWindow`、`@inject-into`）。
5. **Tampermonkey DNR**：24 条规则使用 `redirect`，被跳过并列出。
6. **沉浸式翻译**：
   - 内容脚本注入并在页面上生成界面元素；实际翻译需要其在线服务，本套件不验证。
   - **DNR ❌**：唯一的规则集中 32 条规则全部是 `modifyHeaders`，WebKit 不支持，全部被跳过（明确列出，不是静默失效）。
   - **Popup ❌**：页面加载但内容为空，没有记录到脚本错误。它申请了 `sidePanel`、`offscreen`、`webRequest`，Rikugan 都不提供，这是最可能的原因，未进一步确认。
   - **messaging 🟡**：17 次调用中 1 次 `tabs.sendMessage` 返回 “Receiving end does not exist”，目标标签页没有它的内容脚本，与 Chrome 行为一致。
   - 后台报错 “Cannot find menu item with id toggleTranslatePage”：它更新了一个不存在的右键菜单项，原因未确认，已记录。

### 修复记录（由此报告驱动）

| 首次运行（30e76f9）发现 | 修复 | 修复后 |
|---|---|---|
| Dark Reader Popup 崩溃：`list.map` of undefined，因为 `chrome.fontSettings.getFontList` 未实现 | 实现 `getFontList`（系统字体 + 描述文件安装的字体 + 导入字体） | Popup ✅ |
| uBOL 转换出 0 条规则、广告未拦截；后台 14.9 s 后才开始加载 | 同一时间只有一个 DNR 编译，期间的请求合并，每次完成都生效；解析与转换移出主线程 | 127,757 条规则生效；后台 0.8 s 就绪；广告被拦截 |
| DNR `redirect` 规则编译通过却不执行（dnr 套件实测） | 不再启用 redirect / modifyHeaders（跳过并在诊断页列出）；dnr 套件每次运行都用 WebKit 实际行为校验这一声明 | 不再有“看似支持”的规则 |

## 与此相关的已知限制

- **MV2 扩展不能安装**（Violentmonkey 当前的 Chrome 版本即是）。
- `chrome.userScripts` 不提供：请使用 Rikugan 内置的用户脚本管理器（支持 GM API、`unsafeWindow`、`@inject-into`）。
- `webRequest` / `webRequestBlocking` 不可用：WKWebView 没有公开 API，Rikugan 不使用私有 API。
- DNR `redirect` / `modifyHeaders`：WebKit 能编译 `redirect` 内容规则但**不执行**（dnr 套件实测），`modify-headers` 无法编译。这类规则会被跳过，并在诊断页中列出。
- `offscreen` 文档、`sidePanel` 不提供；本阶段不实现 `webRequest`、`offscreen`、`sidePanel`、DNR redirect / modifyHeaders。
- **下载与 DNR 的 WebKit 边界**（dnr 套件“下载 / 媒体”阶段实测）：
  - 内容规则只作用于 WebKit 自己发出的加载：导航（包括转为 WKDownload 的导航）、页面的 fetch / XHR。
    - 被 block 的下载导航不会发出请求，也不会产生下载项；
    - 普通下载的字节不受影响。
  - Rikugan 自己用 URLSession 发出的下载（直接下载链接、媒体嗅探、HLS 分段、`GM_download`）不经过内容规则，既不会被 DNR 拦截，也不会被改写。
  - 被跳过的 redirect / modifyHeaders 规则不会让请求被改写、改名，也不会被报告为已拦截；`declarativeNetRequest.getMatchedRules` / `onRuleMatchedDebug` 不提供，因此不存在错误的“命中”报告。
  - 媒体嗅探只列出实际收到响应的媒体；被 DNR 拦截的媒体请求不会出现在可下载列表中。
