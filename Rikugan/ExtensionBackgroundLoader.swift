import Foundation
import WebKit

enum ExtensionBackgroundError: LocalizedError {
    case timeout(String)
    var errorDescription: String? {
        switch self { case .timeout(let details): return details }
    }
}

/// WebKit can report a background error without completing its load callback.
/// Always resolve our continuation exactly once and retain useful diagnostics.
@MainActor final class ExtensionBackgroundLoader {
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?

    // A cold simulator can spend over ten seconds merely launching WebContent.
    // Do not tear down a valid load just as its navigation begins.
    static func load(_ context: WKWebExtensionContext, timeout: TimeInterval = 45) async throws {
        let loader = ExtensionBackgroundLoader()
        try await withCheckedThrowingContinuation { continuation in
            loader.continuation = continuation
            NSLog("Rikugan extension background starting: %@ / %@", context.uniqueIdentifier, context.baseURL.absoluteString)
            context.loadBackgroundContent { error in
                Task { @MainActor in loader.finish(error) }
            }
            loader.deadline = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, loader.continuation != nil else { return }
                let details = context.errors.map { ($0 as NSError).description }.joined(separator: "\n")
                loader.finish(ExtensionBackgroundError.timeout("扩展后台在 \(Int(timeout)) 秒内未能启动。\n" + (details.isEmpty ? "WebKit 没有返回错误详情。" : details)))
            }
        }
    }
    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        if let error {
            NSLog("Rikugan extension background failed: %@", (error as NSError).description)
            continuation.resume(throwing: error)
        } else {
            NSLog("Rikugan extension background ready")
            continuation.resume()
        }
    }
}
