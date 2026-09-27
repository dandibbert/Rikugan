import SwiftUI
import WebKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import PhotosUI

/// Experimental in-app Web Inspector (spec §43): console, JS evaluation, DOM source, resources,
/// storage. Safari Remote Inspector (isInspectable) remains the primary debugging path.
struct WebInspectorView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var pane = 0
    @State private var input = ""
    @State private var output: [(String, String)] = []
    @State private var source = ""
    @State private var resources: [String] = []
    @State private var storage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $pane) {
                    Text("控制台").tag(0); Text("元素").tag(1); Text("资源").tag(2); Text("存储").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(8)
                switch pane {
                case 0: console
                case 1: ScrollView { Text(source).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                        .task { source = (try? await tab.webView?.rkCall("return document.documentElement.outerHTML.slice(0, 400000);", world: Worlds.tools)) as? String ?? "" }
                case 2: List(resources, id: \.self) { Text($0).font(.caption2.monospaced()).lineLimit(3) }
                        .task {
                            resources = (try? await tab.webView?.rkCall("return performance.getEntriesByType('resource').map(e => e.initiatorType + '  ' + Math.round(e.duration) + 'ms  ' + e.name).slice(0, 800);", world: Worlds.tools)) as? [String] ?? []
                        }
                default: ScrollView { Text(storage).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                        .task { await loadStorage() }
                }
            }
            .navigationTitle("网页检查器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("捕获 console（下次加载生效）", isOn: $services.prefs.consoleCaptureEnabled)
                        Toggle("允许 Safari 远程检查", isOn: $services.prefs.webInspectorEnabled)
                        Button("清空") { tab.consoleEntries.removeAll(); output.removeAll() }
                    } label: { Image(systemName: "gearshape") }
                }
            }
        }
    }

    private var console: some View {
        VStack(spacing: 0) {
            List {
                if !services.prefs.consoleCaptureEnabled {
                    Text("console 捕获未开启：在左上角菜单开启后刷新页面。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(tab.consoleEntries) { entry in
                    Text(entry.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(color(entry.level)).textSelection(.enabled)
                }
                ForEach(Array(output.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("› " + line.0).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(line.1).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .listStyle(.plain)
            HStack {
                TextField("JavaScript", text: $input).font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(run)
                Button("运行", action: run).disabled(input.isEmpty)
            }
            .padding(8)
            .background(.bar)
        }
    }

    private func run() {
        let code = input
        input = ""
        guard let webView = tab.webView else { return }
        webView.evaluateJavaScript(code, in: nil, in: .page) { result in
            Task { @MainActor in
                switch result {
                case .success(let value): output.append((code, String(describing: value)))
                case .failure(let error): output.append((code, "⚠︎ " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)))
                }
            }
        }
    }

    private func loadStorage() async {
        guard let webView = tab.webView else { return }
        let local = (try? await webView.rkCall("try { return JSON.stringify(Object.fromEntries(Object.entries(localStorage)), null, 1).slice(0, 100000); } catch (e) { return String(e); }", world: .page)) as? String ?? ""
        let cookies = await (tab.isPrivate ? tab.profile.privateDataStore() : tab.profile.dataStore).httpCookieStore.allCookies()
            .filter { DomainTools.host(tab.host ?? "", isWithin: $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        storage = "localStorage:\n\(local)\n\nCookies (\(cookies.count)):\n" + cookies.map { "\($0.name)=\($0.value.prefix(80))  [\($0.domain)\($0.path)]" }.joined(separator: "\n")
    }

    private func color(_ level: String) -> Color {
        switch level { case "error": return .red; case "warn": return .orange; case "debug": return .secondary; default: return .primary }
    }
}

// MARK: - QR (spec §45)

struct QRCodeSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280).padding()
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3).padding(.horizontal)
                    Button { Presenter.share([image]) } label: { Label("分享二维码", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct QRScannerSheet: View {
    @EnvironmentObject private var manager: TabManager
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var result: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                QRCameraView { value in handle(value) }.ignoresSafeArea()
                VStack(spacing: 12) {
                    if let result {
                        Text(result).font(.footnote).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label("从相册识别", systemImage: "photo") }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 40)
            }
            .navigationTitle("扫描二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = CIImage(data: data) else { return }
                    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
                    let message = (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
                    if let message { handle(message) } else { result = "图片中没有二维码" }
                }
            }
        }
    }

    private func handle(_ value: String) {
        if let url = URL(string: value), url.scheme?.hasPrefix("http") == true {
            dismiss()
            manager.newTab(url: url)
        } else {
            result = value
            UIPasteboard.general.string = value
            ToastCenter.shared.show("已拷贝二维码内容", symbol: "doc.on.doc")
        }
    }
}

struct QRCameraView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) { coordinator.session.stopRunning() }
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onCode: (String) -> Void
        private var fired = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func start(in view: PreviewView) {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !fired, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            fired = true
            session.stopRunning()
            onCode(value)
        }
    }
}
