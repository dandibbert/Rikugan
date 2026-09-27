# Chrome 扩展 API 兼容性矩阵

> 由 `scripts/gen_api_matrix.py` 从 `Sources/Rikugan/Resources/JS/chrome-api-matrix.json` 生成，请勿手改。
> CI（`scripts/test_js.cjs`）逐方法校验：标为 Supported / Partial 的方法必须在 JS shim 中是真实实现，且（除标注 JS-only 的方法）在
> `ChromeAPIBridge.swift` 中有原生分支；标为 Unsupported 的方法必须是调用即以 `Unsupported API` 拒绝并上报到诊断页的桩函数。

## 总览

| 命名空间 | 级别 | 已实现 / 方法数 | 说明 |
|---|---|---|---|
| `chrome.runtime` | ✅ Supported | 18/22 | Messaging, ports, lifecycle events and manifest/URL helpers work in content scripts, popup, options and the background runtime. |
| `chrome.storage` | ✅ Supported | 17/17 | Per-extension native storage (not page localStorage). |
| `chrome.scripting` | ✅ Supported | 7/7 | Runs in the extension's isolated WKContentWorld or the page world (MAIN). |
| `chrome.tabs` | 🟡 Partial | 28/35 | Core tab control works; tab moving, discarding, zoom and groups are not available. |
| `chrome.permissions` | ✅ Supported | 6/7 | Optional permissions and host permissions with a user prompt. |
| `chrome.action` | ✅ Supported | 17/17 | Toolbar button with popup, badge, title and icon (per tab or global). |
| `chrome.contextMenus` | 🟡 Partial | 5/5 | Items appear in the link long-press menu and the page menu. |
| `chrome.cookies` | 🟡 Partial | 5/6 | Reads and writes the profile's WKHTTPCookieStore; requires host permissions. |
| `chrome.downloads` | 🟡 Partial | 11/15 | Uses Rikugan's download manager. |
| `chrome.webNavigation` | 🟡 Partial | 9/11 | Main-frame navigation events from WKNavigationDelegate; sub-frame navigations are not observable. |
| `chrome.declarativeNetRequest` | 🟡 Partial | 10/14 | Rules are compiled to WKContentRuleList. WebKit evaluates rules by list order, not DNR priority. |
| `chrome.webRequest` | ⛔ Unsupported | 0/10 | WKWebView's public API cannot observe or intercept arbitrary network requests. Rikugan does not use private WebKit API. |
| `chrome.i18n` | ✅ Supported | 4/4 |  |
| `chrome.alarms` | 🟡 Partial | 6/6 | Timers run while the app is in the foreground; iOS suspends them in the background. |
| `chrome.notifications` | 🟡 Partial | 8/8 | In-app banner, local notification when the app is in the background. |
| `chrome.windows` | 🟡 Partial | 9/10 | Each browser window (scene) is a chrome window. |
| `chrome.commands` | 🟡 Partial | 2/2 | No global keyboard shortcuts on iOS. |
| `chrome.extension` | 🟡 Partial | 5/5 | Legacy helpers. |
| `chrome.bookmarks` | ⛔ Unsupported | — |  |
| `chrome.browsingData` | ⛔ Unsupported | — |  |
| `chrome.contentSettings` | ⛔ Unsupported | — |  |
| `chrome.debugger` | ⛔ Unsupported | — | No DevTools protocol in WKWebView |
| `chrome.declarativeContent` | ⛔ Unsupported | — |  |
| `chrome.devtools` | ⛔ Unsupported | — |  |
| `chrome.enterprise` | ⛔ Unsupported | — |  |
| `chrome.fontSettings` | 🟡 Partial | 1/17 | getFontList returns the system, profile-installed and imported font families; per-page font settings are Rikugan's web-font feature. |
| `chrome.gcm` | ⛔ Unsupported | — |  |
| `chrome.history` | ⛔ Unsupported | — |  |
| `chrome.identity` | ⛔ Unsupported | — |  |
| `chrome.idle` | ⛔ Unsupported | — |  |
| `chrome.management` | ⛔ Unsupported | — |  |
| `chrome.offscreen` | ⛔ Unsupported | — |  |
| `chrome.power` | ⛔ Unsupported | — |  |
| `chrome.privacy` | ⛔ Unsupported | — |  |
| `chrome.proxy` | ⛔ Unsupported | — |  |
| `chrome.readingList` | ⛔ Unsupported | — |  |
| `chrome.search` | ⛔ Unsupported | — |  |
| `chrome.sessions` | ⛔ Unsupported | — |  |
| `chrome.sidePanel` | ⛔ Unsupported | — | No side panel UI |
| `chrome.system` | ⛔ Unsupported | — |  |
| `chrome.tabGroups` | ⛔ Unsupported | — | Rikugan tab groups are not exposed to extensions yet. |
| `chrome.topSites` | ⛔ Unsupported | — |  |
| `chrome.tts` | ⛔ Unsupported | — |  |
| `chrome.userScripts` | ⛔ Unsupported | — | Use Rikugan's built-in userscript manager |

方法合计：✅ 109 · 🟡 59 · ⛔ 50

## chrome.runtime — ✅ Supported

Messaging, ports, lifecycle events and manifest/URL helpers work in content scripts, popup, options and the background runtime.

与 Chrome 的语义差异：
- getPlatformInfo().os is "ios" (not a Chrome enum value)
- External messaging (other extensions / web pages) is not available

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `connect` | ✅ Supported | 原生桥 | Messages posted before the receiver connects are queued |
| `connectNative` | ⛔ Unsupported | — | No native messaging hosts on iOS |
| `getBackgroundPage` | ⛔ Unsupported | — | MV3 has no background page |
| `getContexts` | 🟡 Partial | 原生桥 | Returns background / popup / tab contexts without documentId |
| `getManifest` | ✅ Supported | JS shim |  |
| `getPlatformInfo` | 🟡 Partial | JS shim | os = 'ios', arch = 'arm64' |
| `getURL` | ✅ Supported | JS shim |  |
| `openOptionsPage` | ✅ Supported | 原生桥 |  |
| `reload` | ✅ Supported | 原生桥 |  |
| `requestUpdateCheck` | 🟡 Partial | JS shim | Always resolves {status: 'no_update'}; updates are checked from the extension manager |
| `restart` | ⛔ Unsupported | — | Chrome OS only |
| `sendMessage` | ✅ Supported | 原生桥 | Queued until the background runtime is ready; explicit error if it fails to start |
| `sendNativeMessage` | ⛔ Unsupported | — | No native messaging hosts on iOS |
| `setUninstallURL` | 🟡 Partial | JS shim | Accepted but never opened |
| `onConnect` | ✅ Supported | JS shim |  |
| `onConnectExternal` | 🟡 Partial | JS shim | Never fires (no external senders) |
| `onInstalled` | ✅ Supported | JS shim | Fired on install / update after the background is ready |
| `onMessage` | ✅ Supported | JS shim | sendResponse, return true and returned Promises are supported |
| `onMessageExternal` | 🟡 Partial | JS shim | Never fires (no external senders) |
| `onStartup` | ✅ Supported | JS shim | Fired once per app launch |
| `onSuspend` | ✅ Supported | JS shim | Fired before the idle background runtime is suspended |
| `onUpdateAvailable` | 🟡 Partial | JS shim | Never fires |

## chrome.storage — ✅ Supported

Per-extension native storage (not page localStorage).

与 Chrome 的语义差异：
- storage.sync is stored locally and not synchronised across devices
- storage.managed is always empty

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `local.clear` | ✅ Supported | 原生桥 |  |
| `local.get` | ✅ Supported | 原生桥 |  |
| `local.getBytesInUse` | ✅ Supported | 原生桥 |  |
| `local.getKeys` | ✅ Supported | 原生桥 |  |
| `local.remove` | ✅ Supported | 原生桥 |  |
| `local.set` | ✅ Supported | 原生桥 |  |
| `managed.get` | 🟡 Partial | 原生桥 | Always empty |
| `session.clear` | ✅ Supported | 原生桥 |  |
| `session.get` | ✅ Supported | 原生桥 | In memory |
| `session.remove` | ✅ Supported | 原生桥 |  |
| `session.set` | ✅ Supported | 原生桥 | In memory |
| `session.setAccessLevel` | 🟡 Partial | JS shim | Accepted; session storage is always visible to content scripts |
| `sync.clear` | 🟡 Partial | 原生桥 | Local only |
| `sync.get` | 🟡 Partial | 原生桥 | Local only |
| `sync.remove` | 🟡 Partial | 原生桥 | Local only |
| `sync.set` | 🟡 Partial | 原生桥 | Local only, 100 KB quota enforced |
| `onChanged` | ✅ Supported | JS shim | Delivered to background, extension pages and content scripts |

## chrome.scripting — ✅ Supported

Runs in the extension's isolated WKContentWorld or the page world (MAIN).

与 Chrome 的语义差异：
- injectImmediately is ignored
- documentIds targets are not supported

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `executeScript` | ✅ Supported | 原生桥 | func + args, files, world ISOLATED/MAIN, allFrames, frameIds |
| `getRegisteredContentScripts` | ✅ Supported | 原生桥 |  |
| `insertCSS` | ✅ Supported | 原生桥 | Constructed stylesheets (not blocked by page CSP) |
| `registerContentScripts` | 🟡 Partial | 原生桥 | Takes effect on the next navigation; always persisted |
| `removeCSS` | ✅ Supported | 原生桥 |  |
| `unregisterContentScripts` | ✅ Supported | 原生桥 |  |
| `updateContentScripts` | ✅ Supported | 原生桥 |  |

## chrome.tabs — 🟡 Partial

Core tab control works; tab moving, discarding, zoom and groups are not available.

与 Chrome 的语义差异：
- Private tabs are invisible to extensions
- audible / mutedInfo are always false

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `captureVisibleTab` | 🟡 Partial | 原生桥 | Active tab of the focused window only |
| `connect` | ✅ Supported | JS shim | Implemented through the runtime port router |
| `create` | ✅ Supported | 原生桥 |  |
| `detectLanguage` | ✅ Supported | 原生桥 |  |
| `discard` | ⛔ Unsupported | — |  |
| `duplicate` | ✅ Supported | 原生桥 |  |
| `executeScript` | 🟡 Partial | JS shim | MV2 compatibility wrapper around scripting.executeScript |
| `get` | ✅ Supported | 原生桥 |  |
| `getCurrent` | ✅ Supported | 原生桥 |  |
| `getZoom` | 🟡 Partial | JS shim | Always 1 |
| `getZoomSettings` | 🟡 Partial | JS shim | Static defaults |
| `goBack` | ✅ Supported | 原生桥 |  |
| `goForward` | ✅ Supported | 原生桥 |  |
| `group` | ⛔ Unsupported | — |  |
| `highlight` | ⛔ Unsupported | — |  |
| `insertCSS` | 🟡 Partial | JS shim | MV2 compatibility wrapper around scripting.insertCSS |
| `move` | ⛔ Unsupported | — |  |
| `query` | ✅ Supported | 原生桥 | active, currentWindow, lastFocusedWindow, windowId, url, title, status, pinned, index |
| `reload` | ✅ Supported | 原生桥 |  |
| `remove` | ✅ Supported | 原生桥 |  |
| `sendMessage` | ✅ Supported | 原生桥 |  |
| `setZoom` | ⛔ Unsupported | — | Page zoom is not exposed to extensions |
| `setZoomSettings` | ⛔ Unsupported | — |  |
| `ungroup` | ⛔ Unsupported | — |  |
| `update` | 🟡 Partial | 原生桥 | url, active, pinned; muted / highlighted / openerTabId ignored |
| `onActivated` | ✅ Supported | JS shim |  |
| `onAttached` | 🟡 Partial | JS shim | Never fires |
| `onCreated` | ✅ Supported | JS shim |  |
| `onDetached` | 🟡 Partial | JS shim | Never fires |
| `onHighlighted` | 🟡 Partial | JS shim | Never fires |
| `onMoved` | 🟡 Partial | JS shim | Never fires |
| `onRemoved` | ✅ Supported | JS shim |  |
| `onReplaced` | 🟡 Partial | JS shim | Never fires |
| `onUpdated` | 🟡 Partial | JS shim | status / url / title changes only |
| `onZoomChange` | 🟡 Partial | JS shim | Never fires |

## chrome.permissions — ✅ Supported

Optional permissions and host permissions with a user prompt.

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `addHostAccessRequest` | ⛔ Unsupported | — |  |
| `contains` | ✅ Supported | 原生桥 |  |
| `getAll` | ✅ Supported | 原生桥 |  |
| `remove` | ✅ Supported | 原生桥 |  |
| `request` | ✅ Supported | 原生桥 | Shows a native confirmation sheet |
| `onAdded` | ✅ Supported | JS shim |  |
| `onRemoved` | ✅ Supported | JS shim |  |

## chrome.action — ✅ Supported

Toolbar button with popup, badge, title and icon (per tab or global).

与 Chrome 的语义差异：
- On iPhone the actions are grouped in the toolbar extension menu

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `disable` | ✅ Supported | 原生桥 |  |
| `enable` | ✅ Supported | 原生桥 |  |
| `getBadgeBackgroundColor` | ✅ Supported | 原生桥 |  |
| `getBadgeText` | ✅ Supported | 原生桥 |  |
| `getBadgeTextColor` | ✅ Supported | 原生桥 |  |
| `getPopup` | ✅ Supported | 原生桥 |  |
| `getTitle` | ✅ Supported | 原生桥 |  |
| `getUserSettings` | 🟡 Partial | JS shim | isOnToolbar is always true |
| `isEnabled` | ✅ Supported | 原生桥 |  |
| `openPopup` | ✅ Supported | 原生桥 |  |
| `setBadgeBackgroundColor` | ✅ Supported | 原生桥 |  |
| `setBadgeText` | ✅ Supported | 原生桥 |  |
| `setBadgeTextColor` | ✅ Supported | 原生桥 |  |
| `setIcon` | ✅ Supported | 原生桥 | path or imageData |
| `setPopup` | ✅ Supported | 原生桥 |  |
| `setTitle` | ✅ Supported | 原生桥 |  |
| `onClicked` | ✅ Supported | JS shim |  |

## chrome.contextMenus — 🟡 Partial

Items appear in the link long-press menu and the page menu.

与 Chrome 的语义差异：
- Only page / link / selection / frame / all contexts are shown
- Nested sub-menus are shown flat

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `create` | 🟡 Partial | 原生桥 | See differences |
| `remove` | ✅ Supported | 原生桥 |  |
| `removeAll` | ✅ Supported | 原生桥 |  |
| `update` | ✅ Supported | 原生桥 |  |
| `onClicked` | ✅ Supported | JS shim |  |

## chrome.cookies — 🟡 Partial

Reads and writes the profile's WKHTTPCookieStore; requires host permissions.

与 Chrome 的语义差异：
- Only the default cookie store
- partitionKey is ignored

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `get` | ✅ Supported | 原生桥 |  |
| `getAll` | ✅ Supported | 原生桥 |  |
| `getAllCookieStores` | 🟡 Partial | 原生桥 | Single store '0' |
| `remove` | ✅ Supported | 原生桥 |  |
| `set` | ✅ Supported | 原生桥 |  |
| `onChanged` | ⛔ Unsupported | — | WKHTTPCookieStore observer changes are not forwarded |

## chrome.downloads — 🟡 Partial

Uses Rikugan's download manager.

与 Chrome 的语义差异：
- saveAs / conflictAction are ignored
- Downloads made by Rikugan are not subject to DNR rules

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `cancel` | ✅ Supported | 原生桥 |  |
| `download` | 🟡 Partial | 原生桥 | url, filename, headers |
| `erase` | ✅ Supported | 原生桥 |  |
| `getFileIcon` | ⛔ Unsupported | — |  |
| `open` | ✅ Supported | 原生桥 |  |
| `pause` | ✅ Supported | 原生桥 |  |
| `removeFile` | ⛔ Unsupported | — |  |
| `resume` | ✅ Supported | 原生桥 |  |
| `search` | 🟡 Partial | 原生桥 | id and state filters only |
| `setUiOptions` | 🟡 Partial | JS shim | No-op |
| `show` | 🟡 Partial | 原生桥 | Opens the file preview |
| `showDefaultFolder` | 🟡 Partial | JS shim | No-op |
| `onChanged` | 🟡 Partial | JS shim | Fired on completion only |
| `onCreated` | ⛔ Unsupported | — | Not fired |
| `onErased` | ⛔ Unsupported | — | Not fired |

## chrome.webNavigation — 🟡 Partial

Main-frame navigation events from WKNavigationDelegate; sub-frame navigations are not observable.

与 Chrome 的语义差异：
- frameId is always 0 in events
- processId is always -1

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `getAllFrames` | 🟡 Partial | 原生桥 | Frames known to content scripts / page tools only |
| `getFrame` | 🟡 Partial | 原生桥 | Frames known to content scripts / page tools only |
| `onBeforeNavigate` | 🟡 Partial | JS shim | Main frame only |
| `onCommitted` | 🟡 Partial | JS shim | Main frame only |
| `onCompleted` | 🟡 Partial | JS shim | Main frame only |
| `onCreatedNavigationTarget` | 🟡 Partial | JS shim | window.open / target=_blank only |
| `onDOMContentLoaded` | 🟡 Partial | JS shim | Main frame only |
| `onErrorOccurred` | 🟡 Partial | JS shim | Main frame only |
| `onHistoryStateUpdated` | ✅ Supported | JS shim | pushState / replaceState / popstate / hashchange |
| `onReferenceFragmentUpdated` | ⛔ Unsupported | — | Hash changes are reported through onHistoryStateUpdated |
| `onTabReplaced` | ⛔ Unsupported | — |  |

## chrome.declarativeNetRequest — 🟡 Partial

Rules are compiled to WKContentRuleList. WebKit evaluates rules by list order, not DNR priority.

与 Chrome 的语义差异：
- allow / allowAllRequests use WebKit ignore-previous-rules (ordering, not priority)
- redirect and modifyHeaders rules are skipped and listed in Diagnostics: WebKit does not execute them for app content rule lists (re-verified by the dnr CI suite on every run)
- regexFilter must be expressible in WebKit's regex subset
- Rules do not apply to Rikugan's native downloads / GM_xmlhttpRequest

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `getAvailableStaticRuleCount` | 🟡 Partial | JS shim | Static value |
| `getDisabledRuleIds` | ✅ Supported | JS shim | updateStaticRules is unsupported, so none are disabled |
| `getDynamicRules` | ✅ Supported | 原生桥 |  |
| `getEnabledRulesets` | ✅ Supported | 原生桥 |  |
| `getMatchedRules` | ⛔ Unsupported | — | WKContentRuleList does not report matches |
| `getSessionRules` | ✅ Supported | 原生桥 |  |
| `isRegexSupported` | ✅ Supported | 原生桥 | Reports WebKit regex support |
| `setExtensionActionOptions` | 🟡 Partial | JS shim | Accepted; no badge counts |
| `testMatchOutcome` | ⛔ Unsupported | — |  |
| `updateDynamicRules` | ✅ Supported | 原生桥 |  |
| `updateEnabledRulesets` | ✅ Supported | 原生桥 |  |
| `updateSessionRules` | ✅ Supported | 原生桥 |  |
| `updateStaticRules` | ⛔ Unsupported | — |  |
| `onRuleMatchedDebug` | ⛔ Unsupported | — | WKContentRuleList does not report matches |

| 规则动作 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `allow` | 🟡 Partial | 原生桥 | Ordering-based |
| `allowAllRequests` | 🟡 Partial | 原生桥 | Domain-level only |
| `block` | ✅ Supported | 原生桥 |  |
| `modifyHeaders` | ⛔ Unsupported | — | WebKit does not accept modify-headers content rules for apps; rules are skipped |
| `redirect` | ⛔ Unsupported | — | WebKit compiles redirect content rules but does not execute them for app WKContentRuleLists (measured in CI); rules are skipped |
| `upgradeScheme` | ✅ Supported | 原生桥 |  |

## chrome.webRequest — ⛔ Unsupported

WKWebView's public API cannot observe or intercept arbitrary network requests. Rikugan does not use private WebKit API.

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `handlerBehaviorChanged` | ⛔ Unsupported | — |  |
| `onAuthRequired` | ⛔ Unsupported | — |  |
| `onBeforeRedirect` | ⛔ Unsupported | — |  |
| `onBeforeRequest` | ⛔ Unsupported | — |  |
| `onBeforeSendHeaders` | ⛔ Unsupported | — |  |
| `onCompleted` | ⛔ Unsupported | — |  |
| `onErrorOccurred` | ⛔ Unsupported | — |  |
| `onHeadersReceived` | ⛔ Unsupported | — |  |
| `onResponseStarted` | ⛔ Unsupported | — |  |
| `onSendHeaders` | ⛔ Unsupported | — |  |

## chrome.i18n — ✅ Supported



| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `detectLanguage` | ✅ Supported | 原生桥 | NaturalLanguage framework |
| `getAcceptLanguages` | ✅ Supported | JS shim |  |
| `getMessage` | ✅ Supported | JS shim |  |
| `getUILanguage` | ✅ Supported | JS shim |  |

## chrome.alarms — 🟡 Partial

Timers run while the app is in the foreground; iOS suspends them in the background.

与 Chrome 的语义差异：
- Minimum period 30 s
- Alarms are not persisted across app launches

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `clear` | ✅ Supported | 原生桥 |  |
| `clearAll` | ✅ Supported | 原生桥 |  |
| `create` | 🟡 Partial | 原生桥 | See differences |
| `get` | ✅ Supported | 原生桥 |  |
| `getAll` | ✅ Supported | 原生桥 |  |
| `onAlarm` | ✅ Supported | JS shim |  |

## chrome.notifications — 🟡 Partial

In-app banner, local notification when the app is in the background.

与 Chrome 的语义差异：
- No buttons / images / progress

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `clear` | ✅ Supported | 原生桥 |  |
| `create` | 🟡 Partial | 原生桥 |  |
| `getAll` | ✅ Supported | 原生桥 |  |
| `getPermissionLevel` | ✅ Supported | JS shim |  |
| `update` | 🟡 Partial | 原生桥 |  |
| `onButtonClicked` | 🟡 Partial | JS shim | Never fires |
| `onClicked` | ✅ Supported | JS shim |  |
| `onClosed` | 🟡 Partial | JS shim | Only fired by clear() |

## chrome.windows — 🟡 Partial

Each browser window (scene) is a chrome window.

与 Chrome 的语义差异：
- create opens tabs in the focused window
- Window bounds are read-only

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `create` | 🟡 Partial | 原生桥 | Opens tabs in the focused window |
| `get` | ✅ Supported | 原生桥 |  |
| `getAll` | ✅ Supported | 原生桥 |  |
| `getCurrent` | ✅ Supported | 原生桥 |  |
| `getLastFocused` | ✅ Supported | 原生桥 |  |
| `remove` | ⛔ Unsupported | — |  |
| `update` | 🟡 Partial | 原生桥 | Returns the window unchanged |
| `onCreated` | 🟡 Partial | JS shim | Never fires |
| `onFocusChanged` | 🟡 Partial | JS shim | Never fires |
| `onRemoved` | 🟡 Partial | JS shim | Never fires |

## chrome.commands — 🟡 Partial

No global keyboard shortcuts on iOS.

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `getAll` | ✅ Supported | 原生桥 |  |
| `onCommand` | 🟡 Partial | JS shim | Never fires |

## chrome.extension — 🟡 Partial

Legacy helpers.

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `getBackgroundPage` | 🟡 Partial | JS shim | Always null |
| `getURL` | ✅ Supported | JS shim |  |
| `getViews` | 🟡 Partial | JS shim | Always [] |
| `isAllowedFileSchemeAccess` | ✅ Supported | JS shim | Always false |
| `isAllowedIncognitoAccess` | ✅ Supported | JS shim | Always false (extensions do not run in private tabs) |

## chrome.fontSettings — 🟡 Partial

getFontList returns the system, profile-installed and imported font families; per-page font settings are Rikugan's web-font feature.

与 Chrome 的语义差异：
- fontId equals the family name

| 方法 / 事件 | 级别 | 实现位置 | 说明 |
|---|---|---|---|
| `clearDefaultFixedFontSize` | ⛔ Unsupported | — |  |
| `clearDefaultFontSize` | ⛔ Unsupported | — |  |
| `clearFont` | ⛔ Unsupported | — |  |
| `clearMinimumFontSize` | ⛔ Unsupported | — |  |
| `getDefaultFixedFontSize` | ⛔ Unsupported | — |  |
| `getDefaultFontSize` | ⛔ Unsupported | — |  |
| `getFont` | ⛔ Unsupported | — |  |
| `getFontList` | ✅ Supported | 原生桥 | System + profile + imported families |
| `getMinimumFontSize` | ⛔ Unsupported | — |  |
| `setDefaultFixedFontSize` | ⛔ Unsupported | — |  |
| `setDefaultFontSize` | ⛔ Unsupported | — |  |
| `setFont` | ⛔ Unsupported | — |  |
| `setMinimumFontSize` | ⛔ Unsupported | — |  |
| `onDefaultFixedFontSizeChanged` | ⛔ Unsupported | — |  |
| `onDefaultFontSizeChanged` | ⛔ Unsupported | — |  |
| `onFontChanged` | ⛔ Unsupported | — |  |
| `onMinimumFontSizeChanged` | ⛔ Unsupported | — |  |

