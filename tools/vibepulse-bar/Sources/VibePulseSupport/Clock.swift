import Foundation

/// Wall time is epoch seconds. Monotonic time is for cadence and backoff.
public protocol Clock: Sendable {
    func wall() -> TimeInterval
    func monotonic() -> TimeInterval
}

public struct SystemClock: Clock {
    public init() {}
    public func wall() -> TimeInterval { Date().timeIntervalSince1970 }
    public func monotonic() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public struct FixedClock: Clock, @unchecked Sendable {
    public var wallTime: TimeInterval
    public var monotonicTime: TimeInterval
    public init(wall: TimeInterval = 1_700_000_000, monotonic: TimeInterval = 1_000) {
        self.wallTime = wall
        self.monotonicTime = monotonic
    }
    public func wall() -> TimeInterval { self.wallTime }
    public func monotonic() -> TimeInterval { self.monotonicTime }
}
