import SwiftUI

/// Black panel, hairlines, thin mono numerals, one functional color per provider.
enum Theme {
    static let panel = Color.black
    static let hairline = Color.white.opacity(0.14)
    static let dim = Color.white.opacity(0.45)
    static let text = Color.white.opacity(0.92)
    static let accent = Color(hex: 0xFFB13D)

    static func color(for id: String) -> Color {
        switch id {
        case "claude": return Color(hex: 0xFFB13D)
        case "codex": return Color(hex: 0x00E08F)
        case "gemini": return Color(hex: 0x6E8EFF)
        case "antigravity": return Color(hex: 0x3D9BFF)
        case "cursor": return Color(hex: 0xB18CFF)
        // A second Claude account: Claude's family, but coral so the two can be told apart.
        case let s where s.hasPrefix("claude-"): return Color(hex: 0xFF7F5C)
        default: return Color(hex: 0xFF4A5E)
        }
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let label = Font.system(size: 9, weight: .medium)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct MicroLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(1.6).foregroundStyle(Theme.dim)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

struct LineButton: View {
    let title: String
    var color: Color = Theme.text
    let action: () -> Void
    init(_ title: String, color: Color = Theme.text, action: @escaping () -> Void) {
        self.title = title; self.color = color; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(Theme.label).tracking(1.2).foregroundStyle(color)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
