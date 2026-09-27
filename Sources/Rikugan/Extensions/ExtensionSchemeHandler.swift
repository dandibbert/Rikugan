import Foundation
import WebKit

/// Serves `chrome-extension://<id>/<path>` from the unpacked extension directory, giving extension
/// pages a stable logical origin (spec §17). Web pages may only load `web_accessible_resources`.
final class ExtensionSchemeHandler: NSObject, WKURLSchemeHandler {
    static let backgroundPagePath = "_generated_background_page.html"
    private weak var runtime: ExtensionRuntime?
    private var stopped = Set<ObjectIdentifier>()
    private let lock = NSLock()

    init(runtime: ExtensionRuntime) { self.runtime = runtime }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        MainActor.assumeIsolated { self.serve(webView, urlSchemeTask) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock(); stopped.insert(ObjectIdentifier(urlSchemeTask)); lock.unlock()
    }

    @MainActor private func serve(_ webView: WKWebView, _ task: WKURLSchemeTask) {
        guard let url = task.request.url, let id = url.host, let runtime, let ext = runtime.loaded[id] else {
            fail(task, code: NSURLErrorFileDoesNotExist); return
        }
        let path = url.path.isEmpty ? "/" : url.path
        let background = ext.background?.webView === webView ? ext.background : nil
        background?.note("serve \(path)")
        // Requests initiated by web pages must target web accessible resources.
        if let document = task.request.mainDocumentURL, document.scheme != runtime.scheme,
           !ext.manifest.isWebAccessible(path, from: document) {
            fail(task, code: NSURLErrorNoPermissionsToReadFile); return
        }
        let data: Data
        let mime: String
        if path == "/" + Self.backgroundPagePath {
            data = Data(backgroundPage(ext).utf8)
            mime = "text/html"
        } else if let fileURL = ext.fileURL(path), let contents = try? Data(contentsOf: fileURL) {
            data = contents
            mime = MIME.type(forExtension: fileURL.pathExtension)
        } else {
            background?.note("missing \(path)")
            fail(task, code: NSURLErrorFileDoesNotExist); return
        }
        let headers = [
            "Content-Type": mime + (mime.hasPrefix("text/") || mime.hasSuffix("javascript") || mime.hasSuffix("json") ? "; charset=utf-8" : ""),
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        lock.lock(); let cancelled = stopped.remove(ObjectIdentifier(task)) != nil; lock.unlock()
        guard !cancelled else { background?.note("cancelled \(path)"); return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        lock.lock(); let cancelled = stopped.remove(ObjectIdentifier(task)) != nil; lock.unlock()
        guard !cancelled else { return }
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    /// Page hosting the MV3 service worker (or MV2-style background scripts / page).
    @MainActor private func backgroundPage(_ ext: LoadedExtension) -> String {
        let manifest = ext.manifest
        if let page = manifest.backgroundPage, let html = ext.text(page) { return html }
        var scripts = ""
        if let worker = manifest.serviceWorker {
            let type = manifest.backgroundType == "module" ? " type=\"module\"" : ""
            scripts = "<script\(type) src=\"/\(worker.hasPrefix("/") ? String(worker.dropFirst()) : worker)\"></script>"
        } else {
            scripts = manifest.backgroundScripts.map { "<script src=\"/\($0)\"></script>" }.joined()
        }
        let lifecycle = "<script>setTimeout(function(){try{self.dispatchEvent(new Event('install'));self.dispatchEvent(new Event('activate'));}catch(e){}},0);</script>"
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(ext.displayName) background</title></head><body>\(scripts)\(lifecycle)</body></html>"
    }
}
