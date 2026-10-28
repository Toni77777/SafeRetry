// EventStream.swift
// SafeRetry — A composable resilience library for Swift.

// MARK: - EventStream

/// A thread-safe, single-consumer stream of `Sendable` events backed by `AsyncStream`.
///
/// Events are produced via ``emit(_:)`` and consumed by iterating with `for await`.
/// Call ``finish()`` to signal that no more events will be produced.
///
/// ## Lifetime
///
/// This is a reference type, and dropping the *last* reference terminates the
/// stream. That is a backstop, not a teardown strategy: a consumer written the
/// usual way holds a reference of its own, because `for await event in stream`
/// captures `stream` in the enclosing task's closure. While that loop is
/// suspended the object cannot be deinitialised, so the backstop never fires
/// and the loop waits for a producer that is already gone.
///
/// Call ``finish()`` when the producer is done. It is the only thing that ends
/// a consumer reliably:
///
/// ```swift
/// let stream = EventStream<PolicyEvent>()
/// let consumer = Task {
///     for await event in stream { await telemetry.record(event) }
/// }
///
/// // When the producer is done — not before, or the consumer sees nothing.
/// stream.finish()
/// await consumer.value
/// ```
///
/// The backstop covers the narrower case where nothing but an iterator outlives
/// the stream:
///
/// ```swift
/// var iterator = makeStreamAndEmit()   // the EventStream itself goes out of scope
/// while let event = await iterator.next() { … }   // terminates
/// ```
///
/// Cancelling the consumer task is the other way out, and the one to reach for
/// when the stream should stay alive for other consumers or producers.
///
/// A producer holds a reference too. A policy built with
/// `onEvent: { stream.emit($0) }` keeps the stream alive for as long as the
/// policy lives — and a circuit breaker is long-lived by design — so dropping
/// your own reference ends nothing; ``finish()`` still does. And if the
/// closure reaches the stream through `self` — `onEvent: { self.events.emit($0) }`
/// on an object that also stores the policy — it closes a reference cycle
/// (object → policy → closure → object), so neither is ever freed. Capture the
/// stream itself instead (`let events = self.events`, then
/// `onEvent: { events.emit($0) }`).
///
/// ## Consumers
///
/// Like `AsyncStream`, this type is **single-consumer**. Iterating the same
/// stream from two `for await` loops will cause events to be split between them
/// nondeterministically. If you need multiple subscribers, fan out manually by
/// wrapping the stream with your own broadcaster.
///
/// ## Buffering
///
/// By default, the stream buffers the most recent 1024 events. When the buffer
/// is full the oldest events are dropped so the producer is never blocked. Pass
/// a custom `AsyncStream.Continuation.BufferingPolicy` to ``init(bufferingPolicy:)``
/// if you need different behaviour (for example, `.unbounded`
/// when every event must be retained).
///
/// ```swift
/// let stream = EventStream<PolicyEvent>()
/// stream.emit(.fallbackUsed)
/// stream.finish()
///
/// for await event in stream {
///     print(event)
/// }
/// ```
public final class EventStream<Event: Sendable>: AsyncSequence, Sendable {

    // MARK: - AsyncSequence

    /// The type of event produced by this stream.
    public typealias Element = Event

    // MARK: - Properties

    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    // MARK: - Initialisation

    /// Creates a new event stream ready to emit and consume events.
    ///
    /// - Parameter bufferingPolicy: How the underlying `AsyncStream` handles
    ///   events produced faster than they are consumed. Defaults to
    ///   `.bufferingNewest(1024)` to bound memory usage.
    public init(
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .bufferingNewest(1024)
    ) {
        (self.stream, self.continuation) = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: bufferingPolicy
        )
    }

    deinit {
        // Terminates any consumer still iterating. Without this, a stream
        // dropped without an explicit `finish()` would leave a `for await`
        // loop suspended for the lifetime of the process.
        continuation.finish()
    }

    // MARK: - Iteration

    /// Returns an iterator over the events in this stream.
    ///
    /// Only one iterator should be created per stream; see the type-level
    /// discussion of single-consumer semantics.
    public func makeAsyncIterator() -> AsyncStream<Event>.Iterator {
        stream.makeAsyncIterator()
    }

    // MARK: - Producing Events

    /// Emits an event into the stream.
    ///
    /// Safe to call from any isolation domain, including from synchronous
    /// contexts inside an actor. The call does not suspend.
    ///
    /// - Parameter event: The event to send to the consumer.
    public func emit(_ event: Event) {
        continuation.yield(event)
    }

    /// Signals that no more events will be emitted, terminating the stream.
    ///
    /// After calling this method, any `for await` loop consuming the stream
    /// will finish once all buffered events have been delivered. Safe to call
    /// from any isolation domain; the call does not suspend.
    public func finish() {
        continuation.finish()
    }
}
