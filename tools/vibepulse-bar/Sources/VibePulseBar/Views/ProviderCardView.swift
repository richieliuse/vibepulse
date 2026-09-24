import SwiftUI
import VibePulseBarCore

struct ProviderCardView: View {
    let provider: Provider
    let snapshot: DashboardSnapshot
    let now: Date

    var body: some View {
        let usage = self.snapshot.usage(self.provider)
        VStack(alignment: .leading, spacing: 10) {
            self.header
            CardDivider()
            if !usage.hasData, self.snapshot.tokens != nil {
                Text(self.noDataText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(usage.metrics.filter { $0.window.hasData || !usage.hasData }) { metric in
                MetricRowView(
                    metric: metric,
                    tint: self.provider.accent,
                    display: .remaining,
                    stale: self.snapshot.tokensStale)
            }
            if self.provider == .claude {
                CardDivider()
                TotalsView(tokens: self.snapshot.tokens, stale: self.snapshot.tokensStale)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            HStack(alignment: .firstTextBaseline) {
                Text(DataAge.text(self.snapshot, now: self.now))
                Spacer()
                if let probe = self.snapshot.service.diagnostics?.probes[self.provider] {
                    ProbeLabel(probe: probe)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var noDataText: String {
        switch self.provider {
        case .claude: "No Claude quota yet. The probe needs a signed-in Claude Code or Claude Desktop."
        case .codex: "No Codex quota yet. Sign in with `codex login`."
        case .grok: "No Grok credits yet. Sign in with `grok login`."
        case .cursor: "No Cursor plan data yet. Sign in to Cursor.app."
        }
    }
}

private struct ProbeLabel: View {
    let probe: ProbeStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: self.probe.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(self.probe.isHealthy ? Color.green : Color.orange)
                .font(.system(size: 9))
            Text(self.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(self.probe.status ?? "")
    }

    private var text: String {
        if self.probe.isHealthy {
            return self.probe.ageSeconds.map { "Source live · probed \(Format.relative(seconds: $0))" }
                ?? "Source live"
        }
        guard let status = self.probe.status, !status.isEmpty else { return "Source idle" }
        let reason = status.split(separator: ":").first.map(String.init) ?? status
        return reason.replacingOccurrences(of: "_", with: " ")
    }
}
