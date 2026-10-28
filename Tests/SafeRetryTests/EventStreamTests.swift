// EventStreamTests.swift
// SafeRetry — A composable resilience library for Swift.

import Testing
@testable import SafeRetry

// MARK: - EventStreamTests

@Suite("EventStream")
struct EventStreamTests {

    // MARK: - Ordering

    @Test("emitted events are received in order")
    func eventsReceivedInOrder() async {
        let stream = EventStream<Int>()

        stream.emit(1)
        stream.emit(2)
        stream.emit(3)
        stream.finish()

        var received: [Int] = []
        for await event in stream {
            received.append(event)
        }

        #expect(received == [1, 2, 3])
    }

    // MARK: - Termination

    @Test("finish terminates the stream")
    func finishTerminatesStream() async {
        let stream = EventStream<String>()

        stream.emit("hello")
        stream.finish()

        var count = 0
        for await _ in stream {
            count += 1
        }

        #expect(count == 1)
    }

    // MARK: - Concurrency

    @Test("concurrent emit calls deliver all events")
    func concurrentEmits() async {
        let stream = EventStream<Int>()
        let total = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask {
                    stream.emit(i)
                }
            }
        }
        stream.finish()

        var received: [Int] = []
        for await event in stream {
            received.append(event)
        }

        #expect(received.count == total)
        #expect(Set(received) == Set(0..<total))
    }
}
