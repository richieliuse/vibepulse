import Foundation

/// Crash backoff. Failure must slow the loop down (lesson 2026-08-13): the
/// delay doubles per early death, capped at launchd's own fence, and a run
/// that stayed up long enough counts as healthy again.
public struct RestartPolicy: Sendable, Equatable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    /// A process that lived this long before dying starts a fresh ladder.
    public var stableRuntime: TimeInterval

    public init(initialDelay: TimeInterval = 5, maximumDelay: TimeInterval = 60,
                stableRuntime: TimeInterval = 120) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.stableRuntime = stableRuntime
    }

    /// Next attempt number after a crash that followed `runtime` seconds of life.
    public func nextAttempt(previous: Int, runtime: TimeInterval) -> Int {
        runtime >= self.stableRuntime ? 1 : previous + 1
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        return min(self.maximumDelay, self.initialDelay * pow(2, exponent))
    }
}
