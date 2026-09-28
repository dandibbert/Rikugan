# Rikugan 安全边界：用户脚本与扩展

本页说明页面 JavaScript、用户脚本和扩展之间的特权边界，以及 CI 中用来验证它们的对抗测试。

## 原则

**放在页面 JS 里的秘密不是安全边界。** 页面脚本能读取页面环境中的一切：全局变量、DOM、事件、`postMessage` 流量、被改写的原型。所以 Rikugan 不用“更难猜的令牌”，而用 WebKit 自己报告、页面无法伪造的信息来鉴权：

- 每个消息都经由同一个 `WKScriptMessageHandlerWithReply`（名为 `rikugan`）进入原生层，分为 `gm` / `chrome` / `tools` / `page` 四个通道。
- 原生层读取 `message.world.name`（发出消息的 **WKContentWorld**）和 `message.frameInfo.securityOrigin`（发出消息的 frame 的来源）。这两项由 WebKit 填写，页面 JS 改不了。

| 环境 | 名称 | 谁在其中运行 |
|---|---|---|
| 页面环境 | `""`（`.page`） | 网页自己的脚本、页面环境用户脚本、PageHooks（媒体嗅探 / SPA 事件） |
| 用户脚本隔离环境 | `us-<脚本 UUID>` | 每个特权用户脚本各自一个 |
| 扩展隔离环境 | `ext-<扩展 ID>` | 每个扩展的内容脚本各自一个 |
| 工具环境 | `rikugan-tools` | 深色模式、字体、元素隐藏、元素选择器、阅读、翻译 |

## 用户脚本

### 在哪个环境运行

| 条件 | 环境 | 特权 GM API |
|---|---|---|
| `@inject-into content`，或声明了任何特权授权（`GM_setValue`、`GM_xmlhttpRequest`、`GM_openInTab`、`GM_registerMenuCommand`、`GM_notification` 等） | 该脚本自己的隔离环境 | 可用；每次调用都校验调用方环境与 `@grant` |
| 只用页面安全授权（`none`、`unsafeWindow`、`GM_info`、`GM_log`、`GM_addStyle`、`GM_addElement`、`window.onurlchange`） | 页面环境 | 不需要 |
| `@inject-into page`，且声明了特权授权 | 页面环境 | **不可用**：调用时抛出明确错误；脚本详情页有橙色警告列出这些 API |

### GM_cookie 的范围

`GM_cookie` 可以读写 HttpOnly Cookie，因此只对两类域名开放：当前网页所在的网站，以及脚本 `@match` / `@include` / `@connect` 覆盖的域名（与 `GM_xmlhttpRequest` 的规则相同）。无痕标签页里只能访问无痕会话的 Cookie。脚本必须声明 `@grant GM_cookie` 或 `GM.cookie`，页面环境脚本不可用。

### 页面环境脚本拿不到什么

- 没有消息处理器名、令牌、回调 ID 或分发函数；
- 没有该脚本的 GM 存储值（配置中的 `values` 为空）；
- 原生层拒绝任何以页面环境身份发出的 `gm` 通道消息（记录到安全拒绝记录）。

所以页面环境脚本不会意外获得特权，页面也无法通过它“借道”。

### 隔离环境脚本如何鉴权

`GMBridge` 对每次调用检查：

1. 消息中的脚本 ID 必须存在；
2. 该脚本必须**不**在页面环境；
3. `message.world.name` 必须等于 `us-<该脚本 ID>`；
4. 脚本已启用；
5. 该操作对应的 `@grant` 已声明（存储读 / 写、菜单、标签页、XHR、通知、下载、剪贴板……分别检查）。

其他加固：

- XHR 请求 ID 以脚本为命名空间，别的脚本无法中止它；
- `GM_addValueChangeListener` 的广播和菜单命令回调只发往该脚本自己的隔离环境。

`unsafeWindow` 在隔离环境中是隔离环境自己的 `window`：看得到 DOM，看不到页面 JS 全局变量。矩阵中标为 **Partial**。这是有意的取舍：需要真实页面窗口的脚本应只用页面安全授权（会自动进入页面环境），或用 `@inject-into page` 并放弃特权 API。

## 扩展

`ChromeAPIBridge` 对每次调用检查：

- 扩展 ID 必须已安装并启用；
- 内容脚本上下文的消息必须来自 `ext-<该扩展 ID>` 环境；
- 扩展页面（后台 / Popup / 选项页）的消息必须来自页面环境，且 frame 的来源（由 WebKit 填写）必须是该扩展自己的 `<扩展 scheme>://<ID>`。网页或其他扩展的页面无法冒充。同一扩展内的页面之间不再细分（与 Chrome 一致，它们本来就共享权限）；
- 内容脚本只能调用允许的 API（消息、Port、storage 等），不能调用 tabs / scripting 等。

Port：

- Port 按 `扩展 ID|Port ID` 登记；
- 已存在的 ID 不能再次 `connect`；
- 只有打开方或接收方端点能 `postMessage` / `disconnect`。

即使扩展 B 得知了扩展 A 的 Port ID，也无法向其中注入消息或断开它。

所有拒绝都记入**安全拒绝记录**（设置 → 开发者 → 安全拒绝记录），计数也出现在诊断导出中。

其他通道：

- `tools` 通道只接受工具环境；
- 页面通道的 `historyStateUpdated`（页面 JS 可以调用）只接受与该 frame 来源相同的网址。页面无法伪造跨源历史记录或 `webNavigation` 事件。

## 对抗测试（CI：Simulator: security）

测试夹具：

- 恶意页面 `SelfTest/sec/index.html`，在 `document_start` 前就挂钩 `postMessage` / `bind`，用于截获桥流量；
- 受害脚本 `sec/victim.user.js`（隔离环境，存有秘密值，注册了菜单命令）；
- `sec/victim-page.user.js`（`@inject-into page` + `GM_setValue`）；
- 扩展 A（存有秘密、有一个打开的 Port，并故意把 Port ID 泄露到 DOM）；
- 恶意扩展 B。

**恶意页面必须全部被拒绝的尝试**（18 项）：

- 枚举全局变量与消息处理器；截获 GM 桥流量；
- 以受害脚本 ID 调用 `GM_getValue` / 全部值（含猜测令牌）、`GM_setValue`、`GM_xmlhttpRequest`、伪造 ID 中止 XHR、`GM_openInTab`、注册菜单、通知；
- 冒充页面环境脚本；使用不存在的脚本 ID；
- 冒充扩展 A 的内容脚本 / 页面 / 后台，调用 A 的 scripting、runtime、Port；
- 调用工具通道（元素选择器、凭据）；
- 伪造跨源历史记录；
- 调用受害脚本的分发函数。

**恶意扩展 B 的尝试**：

- 以 A 的身份（内容脚本 / 页面 / 后台）读写 storage、发消息、调用 tabs；
- 声称是 A 向 A 的 Port 发消息、向 A 的 Port 注入、断开 A 的 Port；
- 以受害脚本身份调用 GM。

**断言的是效果，由原生层核实，而不只是看 JS 返回值**：

- 受害脚本的 GM 值不变；A 的存储不变；
- A 的 Port 没有收到伪造消息，并且攻击之后仍能正常收发；
- 没有新标签页、伪造的菜单命令、拦截规则或跨源历史记录；
- 拒绝次数都记入安全拒绝记录；
- 受害脚本自己的菜单命令仍然可用（合法路径没有被误伤）；
- 诊断导出中没有这些秘密值、完整网址或 URL 中的凭据。

## 已知限制

- 隔离环境中的 `unsafeWindow` 看不到页面 JS 全局变量（Partial，见上文）。
- `@inject-into page` 的脚本不能使用特权 GM API。
- 页面环境中的 PageHooks（媒体嗅探、SPA 事件）可以被页面调用；这两个通道只接受与该 frame 同源的信息，不执行特权操作。
- 以上是模拟器中验证的结论。WebKit 的内容环境隔离在真机上是同一实现，但真机结果仍需按 DEVICE_CHECKLIST 验证。
