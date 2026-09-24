import SwiftUI
import VibePulseBarCore

struct OverviewView: View {
    let snapshot: DashboardSnapshot
    let now: Date
    let actions: ServiceActions
    let onSelect: (MenuTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ServiceStatusView(service: self.snapshot.service, now: self.now, actions: self.actions)
            CardDivider()
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Agents")
                Spacer()
                Text(DataAge.text(self.snapshot, now: self.now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(Provider.allCases) { provider in
                    OverviewProviderRow(
                        usage: self.snapshot.usage(provider),
                        agents: self.snapshot.agents(provider),
                        display: self.snapshot.usageDisplay,
                        stale: self.snapshot.tokensStale,
                        action: { self.onSelect(.provider(provider)) })
                }
            }
            .padding(.horizontal, -6)
            CardDivider()
            TotalsView(tokens: self.snapshot.tokens, stale: self.snapshot.tokensStale)
        }
    }
}

private struct OverviewProviderRow: View {
    let usage: ProviderUsage
    let agents: ProviderAgents?
    let display: UsageDisplay
    let stale: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: self.usage.provider.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(self.usage.provider.accent)
                        .frame(width: 14)
                    Text(self.usage.provider.displayName)
                        .font(.system(size: 13, weight: .medium))
                    if let agents {
                        AgentCountBadge(agents: agents)
                    }
                    Spacer(minLength: 6)
                    Text(self.valueText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                UsageBar(percent: self.barPercent, tint: self.usage.provider.accent, height: 5,
                         dimmed: self.stale || (self.metric?.window.stale ?? false))
            }
            .help(self.metric.map { "Tightest window: \($0.title)" } ?? "")
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.isHovered ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    /// The overview answers "how close am I to a wall", so it shows the
    /// tightest window rather than the tab's headline one.
    private var metric: QuotaMetric? { self.usage.mostConstrained }

    private var barPercent: Double? {
        guard let metric else { return nil }
        return self.display == .used ? metric.usedPercent : metric.remainingPercent
    }

    private var valueText: String {
        guard let metric, let used = metric.usedPercent else { return "–" }
        let value = self.display == .used ? "\(Format.percent(used)) used" : "\(Format.percent(100 - used)) left"
        guard let minutes = metric.window.resetMinutes else { return "\(metric.title) · \(value)" }
        return "\(value) · \(Format.duration(minutes: minutes))"
    }
}

struct AgentCountBadge: View {
    let agents: ProviderAgents

    var body: some View {
        if let content = self.content {
            Text(content.text)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(content.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(content.color.opacity(0.15)))
        }
    }

    private var content: (text: String, color: Color)? {
        if self.agents.waitingCount > 0 { return ("\(self.agents.waitingCount) NEEDS YOU", .orange) }
        if self.agents.errorCount > 0 { return ("\(self.agents.errorCount) ERROR", .red) }
        if self.agents.activeCount > 0 { return ("\(self.agents.activeCount) ACTIVE", .green) }
        return nil
    }
}

struct TotalsView: View {
    let tokens: TokensSnapshot?
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Claude Code volume")
                if self.stale, self.tokens != nil { StaleTag() }
            }
            ForEach(self.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var lines: [String] {
        guard let tokens else { return ["Today: – · This month: –"] }
        var lines: [String] = []
        if !tokens.claudeSourcePresent {
            lines.append("No Claude Code logs on this Mac — volume unknown")
        } else if !tokens.volumeIsMeasured {
            lines.append("Counting… the first history scan is still running")
        } else {
            var today = "Today: \(tokens.dayTokens.map(Format.tokens) ?? "–") tokens"
            if let sessions = tokens.daySessions { today += " · \(sessions) sessions" }
            if let rate = tokens.dayTokensPerHour, rate > 0 { today += " · \(Format.tokens(rate))/h" }
            lines.append(today)
            lines.append("This month: \(tokens.monthTokens.map(Format.tokens) ?? "–") tokens")
        }
        if let value = tokens.value, let usd = value.valueUSD {
            var line = "API-equivalent value: \(Format.usd(usd)) this month"
            if let multiple = value.multiple { line += String(format: " · %.1f× plan", multiple) }
            lines.append(line)
        }
        return lines
    }
}

enum DataAge {
    static func text(_ snapshot: DashboardSnapshot, now: Date) -> String {
        guard let fetched = snapshot.tokensFetchedAt else {
            return snapshot.service.isServing ? "Loading…" : "No data yet"
        }
        let age = Format.relative(since: fetched, now: now)
        return snapshot.tokensStale ? "Last data \(age)" : "Updated \(age)"
    }
}
