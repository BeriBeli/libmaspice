import Foundation

/// A bounded, content-free latency summary used by display diagnostics.
public struct SpiceTimingSummary: Sendable, Equatable {
    public let sampleCount: UInt64
    public let p95Milliseconds: Double?
    public let maximumMilliseconds: Double?

    public init(
        sampleCount: UInt64,
        p95Milliseconds: Double?,
        maximumMilliseconds: Double?
    ) {
        self.sampleCount = sampleCount
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }

    public static let empty = SpiceTimingSummary(
        sampleCount: 0,
        p95Milliseconds: nil,
        maximumMilliseconds: nil
    )
}

