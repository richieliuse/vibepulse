import SwiftUI

/// A full-width row that highlights like an NSMenu item.
struct MenuRow: View {
    let title: String
    var symbol: String?
    var shortcut: String?
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .frame(width: 18)
                        .foregroundStyle(self.highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                }
                Text(self.title)
                    .font(.system(size: 13))
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(self.highlighted ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(self.foreground)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(self.highlighted ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .onHover { self.isHovered = $0 }
        .padding(.horizontal, MenuMetrics.rowInset)
    }

    private var highlighted: Bool { self.isHovered && self.isEnabled }

    private var foreground: AnyShapeStyle {
        if !self.isEnabled { return AnyShapeStyle(.tertiary) }
        return self.highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
    }
}

struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuMetrics.cardPadding)
            .padding(.vertical, 4)
    }
}
