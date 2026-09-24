import SwiftUI
import VibePulseBarCore

/// The whole menu, rendered from one value snapshot.
struct MenuContentView: View {
    let snapshot: DashboardSnapshot
    let selection: MenuTab
    let now: Date
    let actions: ServiceActions
    let onSelect: (MenuTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSwitcher(selection: self.selection, snapshot: self.snapshot, onSelect: self.onSelect)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
            Divider().padding(.horizontal, MenuMetrics.cardPadding)
            // Every page stays in the layout, so the menu's frame is the tallest
            // page. Apple sizes a menu from the view frame and does not support
            // resizing it while it is open; CodexBar keeps the switcher frame fixed
            // for the same reason.
            ZStack(alignment: .topLeading) {
                self.page(.overview) {
                    OverviewView(snapshot: self.snapshot, now: self.now, actions: self.actions,
                                 onSelect: self.onSelect)
                }
                ForEach(Provider.allCases) { provider in
                    self.page(.provider(provider)) {
                        ProviderCardView(provider: provider, snapshot: self.snapshot, now: self.now)
                    }
                }
            }
            .padding(.horizontal, MenuMetrics.cardPadding)
            .padding(.top, 10)
            .padding(.bottom, 6)
            MenuSeparator()
            ServiceRows(service: self.snapshot.service, actions: self.actions)
            MenuSeparator()
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,", action: self.actions.openSettings)
            MenuRow(title: "About VibePulse Bar", symbol: "info.circle", action: self.actions.about)
            MenuRow(title: self.quitTitle, symbol: "power", shortcut: "⌘Q", action: self.actions.quit)
                .padding(.bottom, 6)
        }
        .frame(width: MenuMetrics.width, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
    }

    private func page<Content: View>(_ tab: MenuTab, @ViewBuilder content: () -> Content) -> some View {
        let selected = self.selection == tab
        return content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }

    private var quitTitle: String {
        self.snapshot.service.ownsProcess ? "Quit and Stop Service" : "Quit"
    }
}

private struct ServiceRows: View {
    let service: ServiceSnapshot
    let actions: ServiceActions

    var body: some View {
        switch self.service.phase {
        case .external:
            MenuRow(title: "Take Over Service", symbol: "arrow.down.to.line.circle",
                    isEnabled: self.service.foreign?.looksLikeTokenServer == true,
                    action: self.actions.takeOverExternal)
        case .launchAgent:
            MenuRow(title: "Take Over from launchd", symbol: "arrow.down.to.line.circle",
                    action: self.actions.takeOverLaunchAgent)
        case .running, .starting, .stopping:
            MenuRow(title: "Pause Monitoring", symbol: "pause.fill",
                    isEnabled: self.service.ownsProcess && self.service.phase != .stopping,
                    action: self.actions.pause)
        case .idle, .checking, .failed:
            MenuRow(title: "Start Monitoring", symbol: "play.fill",
                    isEnabled: self.service.phase != .checking,
                    action: self.actions.start)
        }
        MenuRow(title: "Restart Service", symbol: "arrow.clockwise",
                isEnabled: self.service.ownsProcess,
                action: self.actions.restart)
    }
}

/// Binds the live model to the value-driven menu.
struct LiveMenuView: View {
    @Bindable var model: AppModel
    let actions: ServiceActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            MenuContentView(
                snapshot: self.model.snapshot(now: context.date),
                selection: self.model.selectedTab,
                now: context.date,
                actions: self.actions,
                onSelect: { self.model.selectedTab = $0 })
        }

    }
}
