# Rikugan 实现规格对照 · 2026-09-27

以用户在 2026-09-27 上传的《Rikugan - Teak-like iOS Browser 功能规格》及随后修订为准。
保留现有 iOS 18.4 WKWebExtension 架构，不另造一套伪 chrome.*。

## 本轮 0.3.0

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
| 可交付证据 | IPA 先上传；测试后打包 tests.zip、manifest、源码/夹具/日志/xcresult 与 SHA256SUMS；仅成功主分支发布 prerelease | .github/workflows/build.yml |

`tests.zip/manifest.json` 写入真实 commit、run ID、测试步骤结果。测试源码存在不等于测试通过，以对应 Actions 结果为准。

## 已有能力，保持而非重复实现

独立 Web Font Engine（全局/站点覆盖、系统/描述文件可见字体、字体文件导入、图标/符号/代码避让）；标签分组及备份；WebExtension 权限预览、ZIP/CRX/目录、popup/options、原生 messaging/storage；普通证书 MV3 非持久后台页面适配；隔离用户脚本、依赖/资源缓存；页面工具和基础广告规则。无痕页不连接普通扩展 controller，也不向扩展枚举/事件提供无痕标签信息；本版本不提供扩展无痕授权开关。

最小 Background Runtime 仍属于 P0。现有后台模式保留原生 WebExtension API 与独立扩展上下文，不是把扩展转成用户脚本。完整 Service Worker 生命周期、importScripts/clients/fetch 拦截没有模拟，不能标成完整 MV3 兼容。

## 尚未关闭的验收项

- Share Extension 目前接收网页链接/文本；`.user.js` 文件的完整分享安装链路、连续多条分享队列仍缺少实现/设备验收。
- 第三方扩展逐个兼容验收、完整 Worker 语义、更多 Chrome API/规则语法不能承诺；不是所有桌面扩展都能运行。
- 长期真实内存压力、跨窗口交互、无痕页所有外部打开入口、图片保存/视频/PiP/AirPlay、权限和证书 App Group 行为需要真机验证。
- 页面 JS 堆不会在挂起后恢复；App 被系统杀死后仅恢复持久化普通标签资料；媒体/下载没有无限后台运行保证。
- 脚本跨标签 value-change listener、完整同步 XHR/FormData/流式事件尚未实现。

PlayCover 仅可作部分启动/UI 冒烟测试，不能代替以上真实 iOS 验收。
