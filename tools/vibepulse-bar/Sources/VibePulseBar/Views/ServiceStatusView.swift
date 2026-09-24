import SwiftUI
import VibePulseBarCore

struct ServiceActions {
    var start: () -> Void = {}
    var pause: () -> Void = {}
    var restart: () -> Void = {}
    var takeOverExternal: () -> Void = {}
    var takeOverLaunchAgent: () -> Void = {}
    var openLog: () -> Void = {}
    var openDiagnostics: () -> Void = {}
    var openSettings: () -> Void = {}
    var about: () -> Void = {}
    var quit: () -> Void = {}
}

struct ServiceStatusView: View {
    let service: ServiceSnapshot
    let now: Date
    let actions: ServiceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusDot(color: self.service.tone.color)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text("Tokenserver")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(self.service.headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(self.service.tone == .healthy ? AnyShapeStyle(.secondary)
                                     : AnyShapeStyle(self.service.tone.color))
            }
            Text(self.service.detail(now: self.now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .monospacedDigit()
            if let footnote = self.service.footnote(now: self.now) {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            self.callout
        }
    }

    @ViewBuilder private var callout: some View {
        switch self.service.phase {
        case .external:
            Callout(
                text: self.service.foreign.map { "Port \(self.service.port) is in use by pid \($0.pid): \($0.command)" }
                    ?? (self.service.lastError ?? "Port \(self.service.port) is already in use."),
                buttonTitle: self.service.foreign?.looksLikeTokenServer == true ? "Take Over" : nil,
                action: self.actions.takeOverExternal)
        case .launchAgent:
            Callout(
                text: "launchd restarts se.torget.tokenserver by itself. Take over to run the server in this app; Settings can hand it back.",
                buttonTitle: "Take Over",
                action: self.actions.takeOverLaunchAgent)
        case .failed:
            Callout(text: self.service.lastError ?? "The server did not start.",
                    buttonTitle: "Settings…", action: self.actions.openSettings)
        default:
            if let error = self.service.lastError {
                Callout(text: error, buttonTitle: nil, action: {})
            }
        }
    }
}

private struct Callout: View {
    let text: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(self.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let buttonTitle {
                PillButton(title: buttonTitle, action: self.action)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .padding(.top, 4)
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(self.isHovered ? 0.85 : 1)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }
}

