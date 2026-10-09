import SwiftUI
import DiskMapCore

enum Theme {
    static let background = Color(hex: 0x11131B)
    static let sidebar = Color(hex: 0x151821)
    static let panel = Color(hex: 0x191D28)
    static let line = Color.white.opacity(0.07)
    static let muted = Color(hex: 0x858C9F)
    static let accent = Color(hex: 0xA699FF)

    static func chartColor(_ branch: Int) -> Color {
        let palette: [UInt32] = [0xA291FF, 0x75BBF6, 0x6FCDB3, 0xFFB471, 0xF18CAB, 0x7D99EA, 0xD5C278, 0x9EC7D5]
        return Color(hex: palette[max(0, branch) % palette.count])
    }

    static func color(for category: FileCategory) -> Color {
        switch category {
        case .projects: Color(hex: 0xA291FF)
        case .downloads: Color(hex: 0xFFB471)
        case .movies: Color(hex: 0x75BBF6)
        case .documents: Color(hex: 0xF18CAB)
        case .pictures: Color(hex: 0x6FCDB3)
        case .other: Color(hex: 0x9DAAC1)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

struct Tag: View {
    let title: String
    var color: Color = Theme.accent
    var body: some View {
        Text(title).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}
