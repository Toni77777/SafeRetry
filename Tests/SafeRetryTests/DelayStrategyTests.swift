// DelayStrategyTests.swift
// SafeRetry — A composable resilience library for Swift.

import Testing
@testable import SafeRetry

// MARK: - DelayStrategyTests

@Suite("DelayStrategy")
struct DelayStrategyTests {

    // MARK: - Immediate

    @Test("immediate always returns zero")
    func immediateReturnsZero() {
        let strategy = DelayStrategy.immediate
        #expect(strategy.delay(forAttempt: 1) == .zero)
        #expect(strategy.delay(forAttempt: 2) == .zero)
        #expect(strategy.delay(forAttempt: 3) == .zero)
        #expect(strategy.delay(forAttempt: 10) == .zero)
    }

    // MARK: - Fixed

    @Test("fixed returns constant delay for every attempt")
    func fixedReturnsConstant() {
        let strategy = DelayStrategy.fixed(.seconds(2))
        #expect(strategy.delay(forAttempt: 1) == .seconds(2))
        #expect(strategy.delay(forAttempt: 2) == .seconds(2))
        #expect(strategy.delay(forAttempt: 3) == .seconds(2))
        #expect(strategy.delay(forAttempt: 10) == .seconds(2))
    }

    // MARK: - Linear

    @Test("linear increases by increment for attempts 1, 2, 3, 10")
    func linearIncreases() {
        let strategy = DelayStrategy.linear(
            initial: .seconds(1),
            increment: .seconds(2),
            maxDelay: .seconds(30)
        )
        #expect(strategy.delay(forAttempt: 1) == .seconds(1))   // 1 + 2*0
        #expect(strategy.delay(forAttempt: 2) == .seconds(3))   // 1 + 2*1
        #expect(strategy.delay(forAttempt: 3) == .seconds(5))   // 1 + 2*2
        #expect(strategy.delay(forAttempt: 10) == .seconds(19)) // 1 + 2*9
    }

    @Test("linear caps at maxDelay")
    func linearCapsAtMax() {
        let strategy = DelayStrategy.linear(
            initial: .seconds(1),
            increment: .seconds(2),
            maxDelay: .seconds(5)
        )
        // 1 + 2*9 = 19 → capped to 5
        #expect(strategy.delay(forAttempt: 10) == .seconds(5))
    }

    @Test("linear is bit-exact for sub-second values (no Double round trip)")
    func linearIsExactForSubSecondValues() {
        // Regression test: initial/increment values that don't survive a
        // Duration -> Double -> Duration round trip exactly (e.g. 0.03s can't
        // be represented precisely in binary floating point). `.linear` must
        // compute these with exact Duration arithmetic.
        let strategy = DelayStrategy.linear(
            initial: .milliseconds(30),
            increment: .milliseconds(20),
            maxDelay: .seconds(1)
        )
        #expect(strategy.delay(forAttempt: 1) == .milliseconds(30))
        #expect(strategy.delay(forAttempt: 2) == .milliseconds(50))
        #expect(strategy.delay(forAttempt: 3) == .milliseconds(70))
    }

    @Test("linear does not overflow for pathologically large attempt counts")
    func linearDoesNotOverflowForHugeAttempts() {
        // Regression test: `increment * (attempt - 1)` must not be computed
        // exactly when it would overflow Duration's fixed-point
        // representation — it should short-circuit to maxDelay instead.
        let strategy = DelayStrategy.linear(
            initial: .seconds(1),
            increment: .seconds(2),
            maxDelay: .seconds(10)
        )
        #expect(strategy.delay(forAttempt: 1_000_000_000) == .seconds(10))
        #expect(strategy.delay(forAttempt: .max) == .seconds(10))
    }

    // MARK: - Exponential

    @Test("exponential doubles by default for attempts 1, 2, 3, 10")
    func exponentialDoubles() {
        let strategy = DelayStrategy.exponential(base: .seconds(1))
        #expect(strategy.delay(forAttempt: 1) == .seconds(1))  // 1 * 2^0
        #expect(strategy.delay(forAttempt: 2) == .seconds(2))  // 1 * 2^1
        #expect(strategy.delay(forAttempt: 3) == .seconds(4))  // 1 * 2^2
        // 1 * 2^9 = 512 → capped at default maxDelay of 60
        #expect(strategy.delay(forAttempt: 10) == .seconds(60))
    }

    @Test("exponential with custom multiplier for attempts 1, 2, 3, 10")
    func exponentialCustomMultiplier() {
        let strategy = DelayStrategy.exponential(
            base: .seconds(1),
            multiplier: 3.0,
            maxDelay: .seconds(100)
        )
        #expect(strategy.delay(forAttempt: 1) == .seconds(1))  // 1 * 3^0
        #expect(strategy.delay(forAttempt: 2) == .seconds(3))  // 1 * 3^1
        #expect(strategy.delay(forAttempt: 3) == .seconds(9))  // 1 * 3^2
        // 1 * 3^9 = 19683 → capped at 100
        #expect(strategy.delay(forAttempt: 10) == .seconds(100))
    }

    @Test("exponential never exceeds maxDelay over many attempts")
    func exponentialNeverExceedsMax() {
        let maxDelay = Duration.seconds(10)
        let strategy = DelayStrategy.exponential(
            base: .seconds(1),
            multiplier: 2.0,
            maxDelay: maxDelay
        )
        for attempt in 1...100 {
            #expect(strategy.delay(forAttempt: attempt) <= maxDelay)
        }
    }

    @Test("exponential does not overflow for pathologically large attempt counts")
    func exponentialDoesNotOverflowForHugeAttempts() {
        // Regression test: pow(multiplier, attempt - 1) can produce a value
        // so large that converting it to Duration would overflow — must
        // short-circuit to maxDelay instead of ever constructing that Duration.
        let strategy = DelayStrategy.exponential(
            base: .seconds(1),
            multiplier: 2.0,
            maxDelay: .seconds(10)
        )
        #expect(strategy.delay(forAttempt: 1_000_000) == .seconds(10))
        #expect(strategy.delay(forAttempt: .max) == .seconds(10))
    }

    // MARK: - Custom

    @Test("custom invokes closure for attempts 1, 2, 3, 10")
    func customInvokesClosure() {
        let strategy = DelayStrategy.custom { attempt in
            .seconds(attempt * 5)
        }
        #expect(strategy.delay(forAttempt: 1) == .seconds(5))
        #expect(strategy.delay(forAttempt: 2) == .seconds(10))
        #expect(strategy.delay(forAttempt: 3) == .seconds(15))
        #expect(strategy.delay(forAttempt: 10) == .seconds(50))
    }
}

// MARK: - JitterStrategyTests

@Suite("JitterStrategy")
struct JitterStrategyTests {

    // MARK: - None

    @Test("none returns delay unchanged")
    func nonePassesThrough() {
        #expect(JitterStrategy.none.apply(to: .seconds(5)) == .seconds(5))
        #expect(JitterStrategy.none.apply(to: .zero) == .zero)
    }

    // MARK: - Full

    @Test("full jitter is always within [0, delay] over 1000 iterations")
    func fullJitterRange() {
        let delay = Duration.seconds(10)
        for _ in 0..<1000 {
            let result = JitterStrategy.full.apply(to: delay)
            #expect(result >= .zero)
            #expect(result <= delay)
        }
    }

    @Test("full jitter with zero delay returns zero")
    func fullJitterZero() {
        #expect(JitterStrategy.full.apply(to: .zero) == .zero)
    }

    // MARK: - Equal

    @Test("equal jitter is always within [delay/2, delay] over 1000 iterations")
    func equalJitterRange() {
        let delay = Duration.seconds(10)
        let half = Duration.seconds(5)
        for _ in 0..<1000 {
            let result = JitterStrategy.equal.apply(to: delay)
            #expect(result >= half)
            #expect(result <= delay)
        }
    }

    @Test("equal jitter with zero delay returns zero")
    func equalJitterZero() {
        #expect(JitterStrategy.equal.apply(to: .zero) == .zero)
    }

    // MARK: - Negative Delays

    @Test("negative delays are clamped to zero instead of trapping")
    func negativeDelayClampsToZero() {
        // Before the clamp, `full` and `equal` built the reversed range
        // `0 ... -1` and trapped with "Range requires lowerBound <= upperBound".
        let negative = Duration.seconds(-1)
        #expect(JitterStrategy.none.apply(to: negative) == .zero)
        #expect(JitterStrategy.full.apply(to: negative) == .zero)
        #expect(JitterStrategy.equal.apply(to: negative) == .zero)
    }

    @Test("a custom strategy returning a negative delay clamps to zero")
    func negativeCustomDelayClampsToZero() {
        let strategy = DelayStrategy.custom { _ in .milliseconds(-250) }
        let delay = strategy.delay(forAttempt: 1)
        #expect(delay == .zero)
        #expect(JitterStrategy.full.apply(to: delay) == .zero)
        #expect(JitterStrategy.equal.apply(to: delay) == .zero)
    }

    @Test("a linear strategy with a negative increment clamps to zero")
    func negativeLinearIncrementClampsToZero() {
        let strategy = DelayStrategy.linear(
            initial: .seconds(1),
            increment: .seconds(-1),
            maxDelay: .seconds(60)
        )
        // Attempt 4 computes 1 s + (-1 s × 3) = -2 s, clamped to zero at the source.
        let delay = strategy.delay(forAttempt: 4)
        #expect(delay == .zero)
        #expect(JitterStrategy.full.apply(to: delay) == .zero)
    }

    @Test("a linear strategy with a negative increment does not overflow downward")
    func negativeLinearIncrementDoesNotOverflow() {
        // Regression test: the overflow pre-check used to guard only the
        // `maxDelay` end, so `increment * (attempt - 1)` was still computed
        // exactly — and trapped — when it overflowed towards Duration's minimum.
        // -100 s × (Int.max - 1) ≈ -9.2e20 s, past Duration's ±1.7e20 s range.
        let strategy = DelayStrategy.linear(
            initial: .seconds(1),
            increment: .seconds(-100),
            maxDelay: .seconds(10)
        )
        #expect(strategy.delay(forAttempt: .max) == .zero)
    }

    @Test("an exponential strategy with a negative base clamps to zero instead of trapping")
    func negativeExponentialBaseClampsToZero() {
        // Regression test: -1 s × 2^69 ≈ -5.9e20 s is outside Duration's range,
        // and the `maxDelay` cap only guarded the positive end, so `.seconds(_:)`
        // trapped with "Overflow in multiplication".
        let strategy = DelayStrategy.exponential(base: .seconds(-1))
        #expect(strategy.delay(forAttempt: 2) == .zero)
        #expect(strategy.delay(forAttempt: 70) == .zero)
        #expect(strategy.delay(forAttempt: .max) == .zero)
    }

    @Test("an exponential strategy with a negative multiplier clamps to zero instead of trapping")
    func negativeExponentialMultiplierClampsToZero() {
        // Odd powers of a negative multiplier are negative; -1e308 s cannot be
        // converted to Duration's Int128 attoseconds and used to trap.
        let strategy = DelayStrategy.exponential(base: .seconds(1), multiplier: -1e308)
        #expect(strategy.delay(forAttempt: 1) == .seconds(1))   // multiplier^0
        #expect(strategy.delay(forAttempt: 2) == .zero)          // -1e308 s
        #expect(strategy.delay(forAttempt: 3) == .seconds(60))   // +infinity → maxDelay
    }

    @Test("an exponential strategy with a zero base yields zero, not maxDelay")
    func zeroExponentialBaseYieldsZero() {
        // 0 × pow(1e308, 2) is 0 × infinity = NaN, which the cap's `<` comparison
        // used to read as "too large" and answer with the full maxDelay.
        let strategy = DelayStrategy.exponential(base: .zero, multiplier: 1e308)
        #expect(strategy.delay(forAttempt: 3) == .zero)
    }

    // MARK: - Equatable

    @Test("JitterStrategy cases are equatable")
    func equatable() {
        #expect(JitterStrategy.none == JitterStrategy.none)
        #expect(JitterStrategy.full == JitterStrategy.full)
        #expect(JitterStrategy.equal == JitterStrategy.equal)
        #expect(JitterStrategy.none != JitterStrategy.full)
        #expect(JitterStrategy.full != JitterStrategy.equal)
    }
}
