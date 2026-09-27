# Rikugan 实现规格对照 · 2026-09-27

以用户在 2026-09-27 上传的《Rikugan - Teak-like iOS Browser 功能规格》及随后修订为准。
main 目前沿用 iOS 18.4 的公开 WKWebExtension 宿主与普通签名后台适配。它不等价于基线规格中的完整自研 Chrome MV3 兼容运行时；该架构差异不能标成已经完全达标。本轮在现有 main 上继续补齐可交付功能，不混入另一分支。

## 0.4.0 续做

新增脚本文件/源码分享读取、原子多项分享批次、App Group→主 App 本地队列转移、逐个源码/权限确认、待处理分享管理。临时文件在 NSItemProvider 回调内读取，脚本不会通过 URL 参数传递，也不会自动执行。分享必须带 App Group 签名；没有权限时明确提供复制退路。由 ShareInboxTests 覆盖排序、重复转移、重启保留、安全校验和实际 NSItemProvider 读取；外部 App 分享面板仍需真机验证。

新增 GM_addValueChangeListener / GM_removeValueChangeListener 及 GM.* 对应接口；本地和远端事件含旧值、新值、remote，删除与 null 区分；同步镜像随原生事件更新。按脚本、身份、无痕隔离；Swift 写盘成功才发送事件。ScriptEventTests 验证真实页面、第二标签、iframe 和无痕，Node 覆盖重叠写入、重复值、取消监听及隔离。以对应 CI 结果为验收，不以测试源码存在代替运行通过。

GM 存储增加带版本的 tagged codec，继续读取旧版纯 JSON 数据；新写入支持 undefined、NaN/±Infinity/-0、BigInt、Date、RegExp、Map、Set、ArrayBuffer 和常见 TypedArray，跨标签 value-change 事件保持这些类型。循环引用、函数、Symbol 和未知宿主对象明确报错，不静默转成空对象。

GM XHR 新增原生 URLSessionDataTask 取消、总超时、下载进度与 readyState、text/URLSearchParams/FormData/Blob/ArrayBuffer 正文、JSON/blob/arraybuffer/document 响应。请求正文最多 2 MB、响应最多 8 MB、每页最多 16 个在途请求；导航/关闭/禁用脚本清理请求；@connect self 精确比较 scheme/host/port，逐跳验证重定向。仍不自动附带浏览器登录 Cookie；stream、同步请求、cookiePartition/proxy 等不支持选项明确报错。ScriptNetworkTests 和 ScriptEventTests 验证真实服务器、桥接与页面，Node 验证序列化和回调。

扩展增加独立可横向滚动的工具栏动作条（图标/标题/徽标/启用状态），点击直接打开原生 popup；无痕不展示。详情页可查看运行时与原始 manifest.json。固定测试扩展增加 document_start/end + CSS、background messaging/Port、storage、popup 当前标签、scripting.executeScript、host permissions、DNR 实际阻断；UI 验证实际效果。后台沿用普通证书非持久页面，不宣称完整 Worker 生命周期。

静态 DNR 改为独立宿主规则列表执行：每个扩展单独编译、挂载和卸载 block/allow 规则，支持优先级、URL/glob/可编译正则和资源类型；关闭扩展/切换身份释放规则，无痕不挂载。真实测试确认原生扩展 API 接受静态规则但没有拦截，因此不再仅依赖原生声明。每个扩展最多 5000 条静态规则；redirect/modifyHeaders、request/initiator domains、WithHostAccess 等未实现条件会阻止加载并展示具体原因，绝不丢弃条件扩大拦截。原生 declarativeNetRequest JavaScript 命名空间整体隐藏（查询接口、动态/session 修改、运行时启停规则集均不提供）；只执行 manifest 声明的启用静态规则，不能报告成功却不生效。不是完整 DNR 兼容。

新增“真机验收诊断”：检查实际运行环境、主 App App Group 容器读写、Share Extension 是否嵌入、普通/无痕 WKWebsiteDataStore、扩展载入/DNR/内容拦截/下载及标签资源状态，并可导出脱敏 JSON。报告明确不读取 Cookie、历史、书签、脚本源码、页面 URL/标题或下载地址；系统默认浏览器 entitlement 仍以系统列表为准。真机分享往返仍需要用户在真实系统 Share Sheet 验证。

## 0.3.0 已交付

| 规格/缺口 | 实现 | 验证入口 |
| --- | --- | --- |
| 活跃/近期标签保留，内存压力允许挂起 | 元数据懒加载；普通切换保留同一 WKWebView；内存警告保留当前、可见 iPad 窗口与一个最近标签。播放、采集和下载中页面不主动回收 | BrowserLifecycleTests：200 标签懒加载；切换 JS 状态；挂起恢复前后历史 |
| 挂起恢复 | 使用公开 interactionState 保存进程内历史/页面/表单/滚动状态；敏感状态不写磁盘和备份 | BrowserLifecycleTests；表单/滚动和实际内存压力另需真机验收 |
| 无痕边界 | 弹窗、上下文菜单、GM_openInTab、复制标签继承无痕；GM 存储使用内存隔离区，最后一个无痕标签关闭时清空 | BrowserLifecycleTests：无痕 GM 不读写普通 GM，网址不进入备份 |
| 备份版本迁移 | v3 格式标识；旧 v2 自动迁移；标签/分组/父文件夹引用、循环、重复 ID、设置范围、网址/路径校验；保留预览/合并/替换和恢复副本 | BackupMigrationTests、CoreTests |
| 脚本更新和重装 | updateURL 检查版本，downloadURL 获取正文；拒绝元数据空壳和版本倒退；重装继续使用原 UUID/开关/GM 存储 | ScriptUpdateTests；安装仍需预览确认 |
| 脚本站点和 SPA | 匹配最具体站点规则；允许/禁用站点之间导航与 iframe 继续校验；多个页面环境脚本各自保留 SPA URL hook；document-body 等待 body 插入 | scripts/test_runtime.cjs |
| 下载 | 导航与媒体统一 WKDownload；使用发起页面的 Cookie store；中心持有 delegate；进度/暂停/续传/取消；HTTP 失败不能标成功；按原身份归档 | BrowserLifecycleTests 的认证/Range 下载；DownloadPolicyTests |
| 下载重启 | 普通续传令牌受文件保护写盘；重启恢复为暂停或明确失败；无痕令牌不写盘 | DownloadPolicyTests；实际杀进程后续传另需设备验收 |
| 无痕下载结束 | 最后一个无痕标签关闭/身份切换时取消未完成下载，释放持有的网页与临时 Cookie 容器；已保存文件保留 | BrowserLifecycleTests 的私密下载清理测试 |
| 广告拦截真实运行 | 修复 WebKit 不支持的正则和白名单排序；保留白名单类型条件；不把不支持的排除规则倒转；原生规则负责网络及元素隐藏，主页面跳转前应用目标站点开关 | ContentBlockerTests：真实规则编译、请求阻断/放行及 CSS 隐藏 |
| 可交付证据 | IPA 先上传；测试后打包 tests.zip、manifest、源码/夹具/日志/xcresult 与 SHA256SUMS；仅成功主分支发布 prerelease | .github/workflows/build.yml |

`tests.zip/manifest.json` 写入真实 commit、run ID、测试步骤结果。测试源码存在不等于测试通过，以对应 Actions 结果为准。

## 已有能力，保持而非重复实现

独立 Web Font Engine（全局/站点覆盖、系统/描述文件可见字体、字体文件导入、图标/符号/代码避让）；标签分组及备份；WebExtension 权限预览、ZIP/CRX/目录、popup/options、原生 messaging/storage；普通证书 MV3 非持久后台页面适配；隔离用户脚本、依赖/资源缓存；页面工具和基础广告规则。无痕页不连接普通扩展 controller，也不向扩展枚举/事件提供无痕标签信息；本版本不提供扩展无痕授权开关。

最小 Background Runtime 仍属于 P0。现有后台模式保留原生 WebExtension API 与独立扩展上下文，不是把扩展转成用户脚本。完整 Service Worker 生命周期、importScripts/clients/fetch 拦截没有模拟，不能标成完整 MV3 兼容。

## 尚未关闭的验收项

- Share Extension 的源码/文件读取和队列已实现；外部 App→真实分享面板→带 App Group 证书的主 App 链路仍需设备验收。
- 第三方扩展逐个兼容验收、完整 Worker 语义、更多 Chrome API/规则语法不能承诺；不是所有桌面扩展都能运行。
- 长期真实内存压力、跨窗口交互、无痕页所有外部打开入口、图片保存/视频/PiP/AirPlay、权限和证书 App Group 行为需要真机验证。
- 页面 JS 堆不会在挂起后恢复；App 被系统杀死后仅恢复持久化普通标签资料；媒体/下载没有无限后台运行保证。
- GM 流式响应（stream）、完整 Cookie/代理/分区语义、循环引用/函数/Symbol/未知宿主对象存储尚未实现；不支持项保持明确错误/Partial。

PlayCover 仅可作部分启动/UI 冒烟测试，不能代替以上真实 iOS 验收。
