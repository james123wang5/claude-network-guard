import AppKit
import SwiftUI

extension Color {
    private static func dynamic(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }

    /// 主色只用在选中和链接；绿、黄、红只表示状态。
    static let guardAccent = dynamic((0.22, 0.34, 0.74), (0.60, 0.71, 1.0))
    static let guardGreen = dynamic((0.03, 0.46, 0.35), (0.38, 0.85, 0.66))
    static let guardAmber = dynamic((0.64, 0.38, 0.02), (0.98, 0.75, 0.38))
    static let guardRed = dynamic((0.76, 0.20, 0.17), (1.0, 0.55, 0.49))
    static let guardInk = dynamic((0.34, 0.40, 0.52), (0.62, 0.69, 0.82))
    static let guardButton = dynamic((0.22, 0.34, 0.74), (0.31, 0.43, 0.86))
    static let paper = dynamic((0.961, 0.967, 0.980), (0.078, 0.092, 0.129))
    static let rail = dynamic((0.922, 0.933, 0.957), (0.057, 0.069, 0.102))
    static let panel = dynamic((1, 1, 1), (0.114, 0.132, 0.178))
    static let hairline = dynamic((0.868, 0.884, 0.916), (0.188, 0.212, 0.271))
    static let heroInk = dynamic((0.10, 0.13, 0.22), (0.10, 0.13, 0.22))

    /// 状态卡的底色。
    static func hero(_ tone: StatusTone) -> LinearGradient {
        let pair: ((Double, Double, Double), (Double, Double, Double))
        switch tone {
        case .positive: pair = ((0.06, 0.47, 0.37), (0.03, 0.31, 0.35))
        case .warning: pair = ((0.66, 0.41, 0.10), (0.50, 0.25, 0.11))
        case .failed: pair = ((0.76, 0.28, 0.22), (0.56, 0.14, 0.24))
        case .neutral, .off: pair = ((0.25, 0.33, 0.60), (0.16, 0.20, 0.40))
        }
        func color(_ v: (Double, Double, Double)) -> Color { Color(.sRGB, red: v.0, green: v.1, blue: v.2) }
        return LinearGradient(colors: [color(pair.0), color(pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum StatusTone {
    case positive, warning, failed, neutral, off

    var color: Color {
        switch self {
        case .positive: .guardGreen
        case .warning: .guardAmber
        case .failed: .guardRed
        case .neutral: .guardInk
        case .off: .secondary
        }
    }

    var icon: String {
        switch self {
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .neutral: "info.circle.fill"
        case .off: "circle"
        }
    }
}

struct StatusTag: View {
    let title: String
    let tone: StatusTone

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tone.color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// 一组内容：标题在外，内容在框里。rows 为真时框里是一行一行的表。
struct Panel<Content: View, Trailing: View>: View {
    var title: String?
    var note: String?
    var rows: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    init(title: String? = nil, note: String? = nil, rows: Bool = false, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.note = note
        self.rows = rows
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if title != nil || note != nil {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader) }
                        if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16).padding(.vertical, rows ? 0 : 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.hairline) }
        }
    }
}

extension Panel where Trailing == EmptyView {
    init(title: String? = nil, note: String? = nil, rows: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, rows: rows, content: content, trailing: { EmptyView() })
    }
}

struct PageHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

extension View {
    /// 表里的一行。分隔线画在上边，第一行的正好和框重合。
    func tableRow() -> some View {
        padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }
}

struct FactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).monospacedDigit().textSelection(.enabled).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .tableRow()
        .accessibilityElement(children: .combine)
    }
}

/// 页面上唯一的主操作。自己画，窗口不在最前时也看得出是主按钮。
struct PrimaryButtonStyle: ButtonStyle {
    var inverted = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: inverted ? 14 : 13, weight: .semibold))
            .foregroundStyle(inverted ? Color.heroInk : .white)
            .padding(.horizontal, inverted ? 20 : 14).padding(.vertical, inverted ? 10 : 7)
            .background(inverted ? Color.white : Color.guardButton, in: RoundedRectangle(cornerRadius: inverted ? 10 : 8))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// 深色底上的次要按钮。
struct HeroButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 15).padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.26 : 0.16), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

extension View {
    func primaryButton(inverted: Bool = false) -> some View { buttonStyle(PrimaryButtonStyle(inverted: inverted)) }
}

/// 界面局部状态。新 SDK 的 @State 是宏，只有完整 Xcode 带插件；这里保证只装命令行工具也能编译。
@MainActor
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
