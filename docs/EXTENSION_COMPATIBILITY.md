# 第三方扩展

这里没有在 WKWebView 里安装或打开这些扩展。下面不是运行结果，不能写成 PASS。

| 扩展 | 这次做了什么 | 结果 |
|---|---|---|
| Dark Reader | 没有在 WebKit 中安装 | NOT RUN。安装、content script、popup、storage、background、实际暗色都没有执行 |
| uBlock Origin Lite | 没有在 WebKit 中安装 | NOT RUN。静态规则里的 redirect / modifyHeaders 在矩阵里是 Unsupported，block 仍由 WebKit 执行扩展自带规则 |
| Violentmonkey | 没有在 WebKit 中安装 | NOT RUN。不能用用户脚本引擎假装它已经跑起来 |
| Tampermonkey | 没有在 WebKit 中安装 | NOT RUN |
| Immersive Translate | 没有在 WebKit 中安装 | NOT RUN |

要得到真实矩阵，需要在 iPhone 上安装固定版本的 CRX，并记录缺的 API、manifest、CSP、background 或 WebKit 限制。CI 不从商店下载，避免网络波动把构建打红。

自带的 8 个 fixture 测试仍然只证明 Rikugan Demo，不证明上面这些扩展。
