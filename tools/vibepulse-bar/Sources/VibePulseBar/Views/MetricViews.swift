import SwiftUI
import VibePulseBarCore

/// Static capsule fill, drawn in one Canvas like CodexBar's bar (no
/// implicit animation, no compositing modifiers inside a menu window).
struct UsageBar: View {
    /// 0...100, or `nil` for honest absence: an empty track, never a zero fill.
    let percent: Double?
    let tint: Color
    var height: CGFloat = 6
    var dimmed = false

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let radius = size.height / 2
            context.fill(
                Path(roundedRect: rect, cornerRadius: radius),
                with: .color(Color.primary.opacity(0.1)))
            guard let percent else { return }
            let clamped = min(100, max(0, percent))
            // A sliver stays visible for a non-zero reading.
            let width = clamped <= 0 ? 0 : max(size.height, size.width * clamped / 100)
            guard width > 0 else { return }
            let fill = CGRect(x: 0, y: 0, width: min(width, size.width), height: size.height)
            context.fill(
                Path(roundedRect: fill, cornerRadius: radius),
                with: .color(self.tint.opacity(self.dimmed ? 0.45 : 1)))
        }
        .frame(height: self.height)
        .accessibilityElement()
        .accessibilityLabel(self.percent.map { "\(Int($0.rounded())) percent" } ?? "No data")
    }
}

struct MetricRowView: View {
    let metric: QuotaMetric
    let tint: Color
    let display: UsageDisplay
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.metric.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if self.metric.window.stale || self.stale {
                    StaleTag()
                }
                Spacer(minLength: 8)
                if let delta = self.metric.delta, let caption = self.metric.deltaCaption, delta > 0 {
                    Text("+\(Format.percent(delta)) \(caption)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            UsageBar(percent: self.barPercent, tint: self.tint, dimmed: self.metric.window.stale || self.stale)
            HStack(alignment: .firstTextBaseline) {
                Text(self.valueText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                Spacer(minLength: 8)
                if let reset = self.resetText {
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let pace = self.paceText {
                Text(pace.text)
                    .font(.system(size: 11))
                    .foregroundStyle(pace.warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
        }
    }

    private var barPercent: Double? {
        self.display == .used ? self.metric.usedPercent : self.metric.remainingPercent
    }

    private var valueText: String {
        guard let used = self.metric.usedPercent else { return "– · usage unavailable" }
        switch self.display {
        case .used: return "\(Format.percent(used)) used"
        case .remaining: return "\(Format.percent(100 - used)) left"
        }
    }

    private var resetText: String? {
        guard self.metric.window.hasData, let minutes = self.metric.window.resetMinutes else { return nil }
        return "Resets in \(Format.duration(minutes: minutes))"
    }

    private var paceText: (text: String, warning: Bool)? {
        switch self.metric.pace {
        case let .runsOutEarly(before, fromNow):
            let when = fromNow.map { "in \(Format.duration(minutes: $0))" } ?? "before reset"
            return ("Pace: runs out \(when) · \(Format.duration(minutes: before)) before reset", true)
        case let .lastsToReset(projected):
            return ("Pace: lasts to reset · ~\(projected)% at reset", false)
        case .collecting:
            return ("Pace: collecting data", false)
        case .none:
            return nil
        }
    }
}

struct StaleTag: View {
    var body: some View {
        Text("CACHED")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(self.color).frame(width: self.size, height: self.size)
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 13, weight: .medium))
    }
}

struct CardDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}
