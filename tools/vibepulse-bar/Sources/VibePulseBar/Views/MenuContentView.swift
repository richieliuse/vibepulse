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
            Group {
                switch self.selection {
                case .overview:
                    OverviewView(snapshot: self.snapshot, now: self.now, actions: self.actions,
                                 onSelect: self.onSelect)
                case let .provider(provider):
                    ProviderCardView(provider: provider, snapshot: self.snapshot, now: self.now)
                }
            }
            .padding(.horizontal, MenuMetrics.cardPadding)
            .padding(.top, 10)
            .padding(.bottom, 6)
            MenuSeparator()
            ServiceRows(service: self.snapshot.service, actions: self.actions)
            MenuSeparator()
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,", action: self.actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(title: "About VibePulse Bar", symbol: "info.circle", action: self.actions.about)
            MenuRow(title: self.quitTitle, symbol: "power", shortcut: "⌘Q", action: self.actions.quit)
                .keyboardShortcut("q", modifiers: .command)
                .padding(.bottom, 6)
        }
        .frame(width: MenuMetrics.width)
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
        case .running, .starting, .unresponsive, .stopping:
            MenuRow(title: "Pause Monitoring", symbol: "pause.fill",
                    isEnabled: self.service.ownsProcess && self.service.phase != .stopping,
                    action: self.actions.pause)
        case .crashed:
            MenuRow(title: "Pause Monitoring", symbol: "pause.fill", action: self.actions.pause)
        case .idle, .checking, .misconfigured:
            MenuRow(title: "Start Monitoring", symbol: "play.fill",
                    isEnabled: self.service.phase != .checking,
                    action: self.actions.start)
        }
        MenuRow(title: "Restart Service", symbol: "arrow.clockwise",
                isEnabled: self.service.ownsProcess || self.service.phase == .launchAgent
                    || self.service.phase == .crashed,
                action: self.actions.restart)
        MenuRow(title: "Open Log", symbol: "doc.text.magnifyingglass", action: self.actions.openLog)
        MenuRow(title: "Open Diagnostics", symbol: "stethoscope",
                isEnabled: self.service.isServing, action: self.actions.openDiagnostics)
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
        .onAppear { self.model.isMenuVisible = true }
        .onDisappear { self.model.isMenuVisible = false }
    }
}
