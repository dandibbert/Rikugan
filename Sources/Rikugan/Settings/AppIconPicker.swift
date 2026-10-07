import SwiftUI
import UIKit

/// App icons shipped in the asset catalog. `AppIcon` is the primary icon; the others are
/// alternate icons declared via ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES (project.yml).
enum AppIconOption: String, CaseIterable, Identifiable {
    case pulse, orbit, nova

    var id: String { rawValue }

    /// Name passed to `setAlternateIconName` (nil = primary icon).
    var alternateName: String? {
        switch self {
        case .pulse: return nil
        case .orbit: return "AppIconOrbit"
        case .nova: return "AppIconNova"
        }
    }

    var title: String {
        switch self {
        case .pulse: return "脉冲（默认）"
        case .orbit: return "星轨"
        case .nova: return "新星"
        }
    }

    /// Alternate app icons cannot be loaded with UIImage(named:), so each has a preview image.
    var previewImage: String {
        switch self {
        case .pulse: return "IconPreviewPulse"
        case .orbit: return "IconPreviewOrbit"
        case .nova: return "IconPreviewNova"
        }
    }

    @MainActor static var current: AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.alternateName == name } ?? .pulse
    }

    /// Every alternate name must be declared in the built Info.plist (CFBundleIcons), otherwise
    /// setAlternateIconName fails at runtime. Used by the core self-test.
    static var declaredAlternateNames: Set<String> {
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
        return Set(alternates?.keys.map { $0 } ?? [])
    }
}

struct AppIconPickerView: View {
    @State private var selected = AppIconOption.current
    @State private var changing = false
    @State private var errorMessage: String?
    @State private var currentAttempt: UUID?

    var body: some View {
        Form {
            Section {
                ForEach(AppIconOption.allCases) { option in
                    Button { apply(option) } label: {
                        HStack(spacing: 14) {
                            Image(option.previewImage)
                                .resizable()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 13.5, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
                            Text(option.title).foregroundStyle(.primary)
                            Spacer()
                            if option == selected { Image(icon: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                        }
                    }
                    .disabled(changing)
                    .accessibilityIdentifier("appicon-\(option.rawValue)")
                }
            } footer: {
                if !UIApplication.shared.supportsAlternateIcons {
                    Text("当前环境不支持更换 App 图标（例如部分侧载或 PlayCover 环境）。")
                } else {
                    Text("更换后系统会弹出确认提示。")
                }
            }
        }
        .navigationTitle("App 图标")
        .onAppear { selected = AppIconOption.current }
        .alert("无法更换图标", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func apply(_ option: AppIconOption) {
        guard option != selected else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "系统报告当前环境不支持更换 App 图标（supportsAlternateIcons = false）。"
            return
        }
        changing = true
        let attempt = UUID()
        currentAttempt = attempt
        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            Task { @MainActor in
                guard currentAttempt == attempt else { return }
                currentAttempt = nil
                changing = false
                if let error {
                    let ns = error as NSError
                    errorMessage = "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
                    ErrorLog.shared.record("setAlternateIconName(\(option.alternateName ?? "nil")): \(ns.domain) \(ns.code) \(ns.localizedDescription)", source: "App 图标")
                } else {
                    selected = AppIconOption.current
                }
            }
        }
        // The system sometimes never calls back (e.g. its confirmation alert could not be shown):
        // never leave the buttons disabled, and say what happened.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard currentAttempt == attempt else { return }
            currentAttempt = nil
            changing = false
            selected = AppIconOption.current
            if selected != option {
                errorMessage = "系统没有回应更换图标的请求。请回到主屏幕再打开 Rikugan 后重试。"
                ErrorLog.shared.record("setAlternateIconName(\(option.alternateName ?? "nil")): no callback after 8 s", source: "App 图标")
            }
        }
    }
}
