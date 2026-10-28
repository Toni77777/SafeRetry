// DelayStrategy.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation

// MARK: - DelayStrategy

/// Determines the delay between consecutive retry attempts.
///
/// Each case implements a different backoff algorithm. Use
/// ``delay(forAttempt:)`` to compute the concrete delay for a given
/// 1-based attempt number.
///
/// ```swift
/// let strategy = DelayStrategy.exponential(base: .seconds(1))
/// strategy.delay(forAttempt: 1) // 1 s
/// strategy.delay(forAttempt: 2) // 2 s
/// strategy.delay(forAttempt: 3) // 4 s
/// ```
public enum DelayStrategy: Sendable {

    /// No delay between retries — the next attempt starts immediately.
    case immediate

    /// A constant delay applied before every retry.
    ///
    /// - Parameter interval: The fixed delay duration.
    case fixed(_ interval: Duration)

    /// A linearly increasing delay.
    ///
    /// Formula: `min(initial + increment * (attempt - 1), maxDelay)`. The
    /// returned value is computed with exact `Duration` arithmetic — not
    /// round-tripped through `Double` — so it never drifts from the
    /// analytical value. (A `Double` pre-check is used internally only to
    /// detect, without overflowing, whether the result would already exceed
    /// `maxDelay` or fall below zero — the result is then `maxDelay` or
    /// `.zero` respectively; it never contributes to the returned duration
    /// itself.)
    ///
    /// - Parameters:
    ///   - initial: The delay for the first retry.
    ///   - increment: The additional delay added on each subsequent retry.
    ///   - maxDelay: Upper bound for the computed delay.
    case linear(initial: Duration, increment: Duration, maxDelay: Duration)

    /// An exponentially increasing delay.
    ///
    /// Formula: `min(base * pow(multiplier, attempt - 1), maxDelay)`.
    ///
    /// `pow` is inherently a floating-point operation, so `base` is converted
    /// to `Double` seconds to compute the exponent; the result may differ from
    /// the mathematically exact value by a negligible (sub-nanosecond) amount.
    /// `maxDelay` itself is compared as a `Duration`, not converted, so the
    /// cap is always exact. Don't rely on exact `Duration` equality against a
    /// hand-computed expectation for this case — compare the derived seconds
    /// with a small tolerance instead.
    ///
    /// - Parameters:
    ///   - base: The delay for the first retry.
    ///   - multiplier: The growth factor applied on each subsequent retry.
    ///   - maxDelay: Upper bound for the computed delay.
    case exponential(base: Duration, multiplier: Double = 2.0, maxDelay: Duration = .seconds(60))

    /// A caller-provided closure that computes the delay for each attempt.
    ///
    /// - Parameter closure: A `@Sendable` closure receiving the 1-based attempt
    ///   index and returning the desired delay.
    case custom(@Sendable (_ attempt: Int) -> Duration)

    // MARK: - Delay Computation

    /// Computes the delay for the given retry attempt.
    ///
    /// Clamped to `.zero` — a negative delay is meaningless as a sleep
    /// duration. ``JitterStrategy`` relies on this: it only ever receives a
    /// non-negative delay from here, so it doesn't need its own clamp for
    /// values coming through the normal call path.
    ///
    /// - Parameter attempt: The 1-based attempt index (first retry = 1).
    /// - Returns: The computed delay duration, never negative.
    public func delay(forAttempt attempt: Int) -> Duration {
        max(.zero, rawDelay(forAttempt: attempt))
    }

    /// Computes the delay without clamping. A negative result can reach here
    /// from a ``custom(_:)`` closure, a negative ``fixed(_:)`` interval, or
    /// ``linear(initial:increment:maxDelay:)`` with a negative `increment`.
    /// ``exponential(base:multiplier:maxDelay:)`` with a negative `base` or
    /// `multiplier` short-circuits to `.zero` instead, because its value is
    /// built from `Double` seconds that may not fit in a `Duration` at all.
    private func rawDelay(forAttempt attempt: Int) -> Duration {
        switch self {
        case .immediate:
            return .zero

        case .fixed(let interval):
            return interval

        case .linear(let initial, let increment, let maxDelay):
            // Exact Duration arithmetic — no Double round trip, so the result
            // never drifts from `initial + increment * (attempt - 1)`.
            //
            // Guard first: `increment * n` can overflow Duration's fixed-point
            // representation for pathologically large attempt counts, even
            // though the result would immediately be clamped to maxDelay
            // anyway. Double doesn't trap on overflow (it saturates to
            // infinity), so it's safe to use purely as a "will this be capped"
            // pre-check without touching the actual returned value.
            //
            // The same overflow exists in the other direction: a negative
            // `increment` drives `increment * n` towards Duration's minimum,
            // and that result would be clamped to `.zero` anyway.
            let n = attempt - 1
            let initialSec = durationToSeconds(initial)
            let incrementSec = durationToSeconds(increment)
            let maxSec = durationToSeconds(maxDelay)
            let projectedSec = initialSec + incrementSec * Double(n)
            guard projectedSec < maxSec else {
                return maxDelay
            }
            guard projectedSec > 0 else {
                return .zero
            }
            return initial + increment * n

        case .exponential(let base, let multiplier, let maxDelay):
            // `pow` requires floating point; only `base` goes through Double.
            // The cap must be applied *before* constructing a Duration from
            // the computed seconds — pow() can produce a value so large that
            // converting it to Duration's fixed-point attosecond
            // representation overflows, even though it would immediately be
            // clamped down to maxDelay anyway.
            //
            // The cap only guards the top. A negative `base` or `multiplier`
            // can make `computedSec` hugely negative (or `-infinity`), which
            // traps just the same in `.seconds(_:)`, so non-positive results
            // — and `NaN`, e.g. a zero base times an infinite power — return
            // `.zero` before conversion, matching the clamp in `delay(forAttempt:)`.
            let baseSec = durationToSeconds(base)
            let maxSec = durationToSeconds(maxDelay)
            let computedSec = baseSec * pow(multiplier, Double(attempt - 1))
            guard computedSec > 0 else {
                return .zero
            }
            guard computedSec < maxSec else {
                return maxDelay
            }
            return .seconds(computedSec)

        case .custom(let closure):
            return closure(attempt)
        }
    }
}

// MARK: - Internal Helpers

/// Converts a `Duration` to its equivalent value in seconds as a `Double`.
internal func durationToSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) * 1e-18
}
