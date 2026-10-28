// EventStreamAdvancedTests.swift
// SafeRetry — A composable resilience library for Swift.

import Foundation
import Testing
@testable import SafeRetry

// MARK: - EventStreamAdvancedTests

@Suite("EventStream — Advanced")
struct EventStreamAdvancedTests {

    @Test("finish before consuming delivers buffered events then terminates")
    func finishBeforeConsuming() async {
        let stream = EventStream<Int>()

        stream.emit(1)
        stream.emit(2)
        stream.finish()

        var collected: [Int] = []
        for await value in stream {
            collected.append(value)
        }

        #expect(collected == [1, 2])
    }

    @Test("empty stream terminates immediately after finish")
    func emptyStreamFinishes() async {
        let stream = EventStream<String>()
        stream.finish()

        var count = 0
        for await _ in stream {
            count += 1
        }

        #expect(count == 0)
    }

    @Test("stream works with PolicyEvent type")
    func policyEventStream() async {
        let stream = EventStream<PolicyEvent>()

        stream.emit(.fallbackUsed)
        stream.emit(.timeoutExceeded(duration: .seconds(5)))
        stream.finish()

        var collected: [PolicyEvent] = []
        for await event in stream {
            collected.append(event)
        }

        #expect(collected.count == 2)
    }

    @Test("all PolicyEvent cases are constructible and streamable")
    func allPolicyEventCases() async {
        struct Err: Error {}

        let allEvents: [PolicyEvent] = [
            .attemptStarted(attempt: 1),
            .attemptSucceeded(attempt: 1, duration: .milliseconds(200)),
            .attemptFailed(attempt: 2, error: Err(), nextDelay: .seconds(1)),
            .retryExhausted(totalAttempts: 3, lastError: Err()),
            .retryScheduled(attempt: 2, delay: .seconds(1)),
            .circuitStateChanged(from: .closed, to: .open(until: ContinuousClock().now)),
            .circuitCallRejected(state: .open(until: ContinuousClock().now)),
            .timeoutExceeded(duration: .seconds(10)),
            .fallbackUsed,
        ]

        let stream = EventStream<PolicyEvent>()
        for event in allEvents {
            stream.emit(event)
        }
        stream.finish()

        var count = 0
        for await _ in stream {
            count += 1
        }

        #expect(count == allEvents.count)
    }
}

// MARK: - EventStreamLifetimeTests

/// A stream that is dropped without an explicit ``EventStream/finish()`` must
/// still terminate its consumer. Without that, a `for await` loop over it stays
/// suspended forever — and if the loop is the body of a `Task` someone awaits,
/// the await never returns.
@Suite("EventStream — Lifetime")
struct EventStreamLifetimeTests {

    /// Emits, hands back an iterator, and lets the stream go out of scope.
    private func emitThenDrop() -> AsyncStream<Int>.Iterator {
        let stream = EventStream<Int>()
        stream.emit(1)
        stream.emit(2)
        return stream.makeAsyncIterator()
    }

    @Test("dropping the last reference terminates the stream", .timeLimit(.minutes(1)))
    func droppingLastReferenceTerminatesStream() async {
        var iterator = emitThenDrop()

        var received: [Int] = []
        while let value = await iterator.next() {
            received.append(value)
        }

        #expect(received == [1, 2])
    }

    @Test("an explicit finish is still honoured")
    func explicitFinishStillWorks() async {
        let stream = EventStream<Int>()
        stream.emit(1)
        stream.finish()
        stream.emit(2)   // after finish — dropped

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [1])
    }
}
