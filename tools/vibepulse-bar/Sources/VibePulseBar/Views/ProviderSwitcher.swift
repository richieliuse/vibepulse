import SwiftUI
import VibePulseBarCore

struct ProviderSwitcher: View {
    let selection: MenuTab
    let snapshot: DashboardSnapshot
    let onSelect: (MenuTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MenuTab.all, id: \.self) { tab in
                SwitcherSegment(
                    tab: tab,
                    isSelected: tab == self.selection,
                    indicator: self.indicator(for: tab),
                    badge: self.badge(for: tab),
                    action: { self.onSelect(tab) })
            }
        }
    }

    /// CodexBar's under-tab quota line: what is left of the primary window.
    private func indicator(for tab: MenuTab) -> (fraction: Double, color: Color)? {
        guard case let .provider(provider) = tab,
              let used = self.snapshot.usage(provider).primary?.usedPercent
        else { return nil }
        return ((100 - used) / 100, provider.accent)
    }

    private func badge(for tab: MenuTab) -> Color? {
        switch tab {
        case .overview:
            return self.snapshot.agents?.totalWaiting ?? 0 > 0 ? .orange : nil
        case let .provider(provider):
            guard let agents = self.snapshot.agents(provider) else { return nil }
            if agents.waitingCount > 0 { return .orange }
            if agents.workingCount > 0 { return .green }
            return nil
        }
    }
}

private struct SwitcherSegment: View {
    let tab: MenuTab
    let isSelected: Bool
    let indicator: (fraction: Double, color: Color)?
    let badge: Color?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            VStack(spacing: 3) {
                Image(systemName: self.tab.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 16)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Circle().fill(badge)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(Color.white.opacity(self.isSelected ? 0.9 : 0), lineWidth: 1))
                                .offset(x: 5, y: -2)
                        }
                    }
                Text(self.tab.title)
                    .font(.system(size: 10.5, weight: self.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                self.indicatorBar
            }
            .foregroundStyle(self.isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(self.background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityLabel(self.tab.title)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }

    private var background: Color {
        if self.isSelected { return .accentColor }
        return self.isHovered ? Color.primary.opacity(0.07) : .clear
    }

    @ViewBuilder private var indicatorBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(self.indicator == nil ? 0 : 0.12))
                if let indicator {
                    Capsule()
                        .fill(self.isSelected ? Color.white : indicator.color)
                        .frame(width: max(0, proxy.size.width * indicator.fraction))
                }
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 8)
    }
}
