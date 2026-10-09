import AppKit
import SwiftUI

struct RecorderButtonStyle: ButtonStyle {
    enum Tone {
        case primary, secondary, destructive
        case row(Bool)
        case dark
    }
    var tone: Tone = .secondary
    var height: CGFloat = 44
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: height)
            .contentShape(Rectangle())
            .foregroundStyle(foreground)
            .background(
                background.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 9)
            )
            .opacity(enabled ? 1 : 0.4)
            .modifier(HandCursor(enabled: enabled))
    }

    private var foreground: Color {
        switch tone {
        case .primary, .dark: return .white
        case .destructive: return Color(red: 0.72, green: 0.20, blue: 0.20)
        default: return Color(red: 0.12, green: 0.34, blue: 0.29)
        }
    }
    private var background: Color {
        switch tone {
        case .primary: return Color(red: 0.14, green: 0.43, blue: 0.37)
        case .destructive: return .red.opacity(0.07)
        case .row(let selected): return selected ? Color.green.opacity(0.09) : .clear
        case .dark: return .white.opacity(0.12)
        default: return Color(red: 0.90, green: 0.94, blue: 0.91)
        }
    }
}

private struct HandCursor: ViewModifier {
    let enabled: Bool
    @State private var pushed = false
    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside && enabled && !pushed {
                NSCursor.pointingHand.push()
                pushed = true
            } else if (!inside || !enabled) && pushed {
                NSCursor.pop()
                pushed = false
            }
        }
        .onChange(of: enabled) { _, value in if !value { release() } }
        .onDisappear { release() }
    }
    private func release() {
        if pushed {
            NSCursor.pop()
            pushed = false
        }
    }
}
