import SwiftUI
import UIKit

/// The app's theme (tint) colour, chosen in Settings → 外观与工具栏 → 主题色.
@MainActor enum Theme {
    struct Preset: Identifiable, Hashable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let defaultHex = "#E07A5F"

    /// Warm, slightly muted colours that read well on light and dark backgrounds.
    static let presets: [Preset] = [
        Preset(name: "珊瑚", hex: "#E07A5F"),
        Preset(name: "陶土", hex: "#C2643F"),
        Preset(name: "琥珀", hex: "#D99A2B"),
        Preset(name: "抹茶", hex: "#6E9F5B"),
        Preset(name: "青瓷", hex: "#3F9A8F"),
        Preset(name: "雾蓝", hex: "#5A86B5"),
        Preset(name: "薰衣草", hex: "#8B78C9"),
        Preset(name: "樱粉", hex: "#D7799A"),
        Preset(name: "可可", hex: "#8C6A55"),
        Preset(name: "经典蓝", hex: "#007AFF"),
    ]

    static var uiColor: UIColor { UIColor(hex: AppServices.shared.prefs.themeColor) ?? UIColor(hex: defaultHex)! }
    static var color: Color { Color(uiColor: uiColor) }

    /// UIKit chrome (alerts, menus, context menus) follows the theme too.
    static func applyToWindows() {
        let tint = uiColor
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.tintColor = tint }
        }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // Colours from the system picker can be in an extended colour space: clamp to sRGB.
        let srgb = cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
            .map { UIColor(cgColor: $0) } ?? self
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

struct ThemeColorView: View {
    @EnvironmentObject private var services: AppServices
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 14)]

    private var custom: Binding<Color> {
        Binding(get: { Theme.color }, set: { services.prefs.themeColor = UIColor($0).hexString })
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Theme.presets) { preset in
                        let selected = services.prefs.themeColor.uppercased() == preset.hex.uppercased()
                        Button { services.prefs.themeColor = preset.hex } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle().fill(Color(uiColor: UIColor(hex: preset.hex)!)).frame(width: 40, height: 40)
                                    if selected {
                                        Circle().strokeBorder(Color(.systemBackground), lineWidth: 3).frame(width: 34, height: 34)
                                        Image(icon: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                                Text(preset.name).font(.caption).foregroundStyle(selected ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 8)
            } header: { Text("预设") }
            Section {
                ColorPicker("自选颜色", selection: custom, supportsOpacity: false)
            } footer: {
                Text("主题色用于按钮、图标、开关、进度条和选中状态。")
            }
            Section {
                HStack(spacing: 14) {
                    Image(icon: "puzzlepiece.extension").font(.title2).foregroundStyle(.tint)
                    Image(icon: "star").font(.title2).foregroundStyle(.tint)
                    Image(icon: "book").font(.title2).foregroundStyle(.tint)
                    Spacer()
                    Toggle("", isOn: .constant(true)).labelsHidden()
                }
                Button("按钮样式") {}.buttonStyle(.borderedProminent)
            } header: { Text("预览") }
        }
        .navigationTitle("主题色")
    }
}
