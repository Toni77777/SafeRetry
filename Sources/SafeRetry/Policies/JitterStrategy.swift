// JitterStrategy.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - JitterStrategy

/// Adds randomness to a computed delay to prevent thundering-herd effects.
///
/// Apply a jitter strategy to a delay produced by ``DelayStrategy`` so that
/// multiple clients don't retry at the exact same instant.
///
/// ```swift
/// let base = DelayStrategy.exponential(base: .seconds(1))
/// let delay = base.delay(forAttempt: 3)          // 4 s
/// let jittered = JitterStrategy.full.apply(to: delay) // random in [0, 4] s
/// ```
public enum JitterStrategy: Sendable, Equatable {

    /// No jitter — the delay is used as-is.
    case none

    /// Full jitter — the result is a random duration in `[0, delay]`.
    case full

    /// Equal jitter — the result is `delay / 2` plus a random duration
    /// in `[0, delay / 2]`, guaranteeing at least half the original delay.
    case equal

    // MARK: - Application

    /// Applies this jitter strategy to the given delay.
    ///
    /// Uses `SystemRandomNumberGenerator` internally.
    ///
    /// A negative delay is meaningless as a sleep duration, so it is clamped to
    /// `Duration.zero` before jitter is applied. Without the clamp, ``full``
    /// and ``equal`` would build a reversed `Double` range and trap with
    /// *"Range requires lowerBound <= upperBound"*.
    /// ``DelayStrategy/delay(forAttempt:)`` already clamps negative results at
    /// the source, so this is defence in depth for callers who apply jitter to
    /// a duration computed some other way.
    ///
    /// - Parameter delay: The base delay to jitter.
    /// - Returns: A new duration with jitter applied, never less than zero.
    public func apply(to delay: Duration) -> Duration {
        guard delay > .zero else {
            return .zero
        }

        switch self {
        case .none:
            return delay

        case .full:
            let seconds = durationToSeconds(delay)
            return .seconds(Double.random(in: 0...seconds))

        case .equal:
            let seconds = durationToSeconds(delay)
            let half = seconds / 2.0
            return .seconds(half + Double.random(in: 0...half))
        }
    }
}
