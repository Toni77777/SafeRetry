# Observability

Subscribe to real-time policy events for logging, metrics, and alerting.

## Overview

SafeRetry exposes ``PolicyEvent`` as a shared event vocabulary for resilience workflows. Every built-in policy — ``RetryPolicy``, ``CircuitBreaker``, ``TimeoutPolicy``, and ``FallbackPolicy`` — accepts an `onEvent` callback at initialisation. You can also emit ``PolicyEvent`` values manually through ``EventStream`` to build your own observability pipeline.

## The `onEvent` Contract

All `onEvent` callbacks are **synchronous** (`@Sendable (PolicyEvent) -> Void`). They run inline with policy execution:

- On ``CircuitBreaker``, the closure runs on the actor's executor. Blocking the closure blocks every call through the breaker.
- On ``RetryPolicy``, ``TimeoutPolicy``, and ``FallbackPolicy``, the closure runs on the calling task. Blocking the closure blocks the operation itself.

Callbacks are invoked in the order events occur — the synchronous contract exists precisely to guarantee that state transitions and the events that describe them are delivered in the same order they happen.

Keep callbacks fast. If you need asynchronous work (writing to disk, sending an HTTP request, hitting a remote metrics service), the order guarantee decides how to hand it off. Spawning a `Task` per event is fine when each event stands alone, such as incrementing a counter:

```swift
onEvent: { event in
    Task {
        await telemetry.record(event)
    }
}
```

But those tasks run concurrently, so they can finish in any order — a breaker's `closed → open` may reach `telemetry` after the `open → halfOpen` that followed it. When the consumer needs the sequence, forward events into an ``EventStream`` and drain it from a single task, which preserves the order they were emitted in (see <doc:Observability#Fanning-Policy-Events-into-a-Shared-Stream>).

``CircuitBreaker``'s `isFailure` predicate shares the contract: it too runs synchronously on the breaker's actor executor, so blocking in it blocks every call through the breaker.

## Cancellation Emits Nothing

Cancellation is not a policy outcome, so no policy reports one. In ``RetryPolicy`` that means a cancelled attempt's ``PolicyEvent/attemptStarted(attempt:)`` has no matching ``PolicyEvent/attemptSucceeded(attempt:duration:)``, ``PolicyEvent/attemptFailed(attempt:error:nextDelay:)``, or ``PolicyEvent/retryExhausted(totalAttempts:lastError:)`` — the error is rethrown before any event is emitted. ``FallbackPolicy`` likewise emits no ``PolicyEvent/fallbackUsed`` for a cancelled operation, and ``CircuitBreaker`` records no failure.

An observer that pairs starts with terminal events — an in-flight gauge, a latency histogram — has to read an unmatched start as a cancelled attempt rather than a leak:

```swift
onEvent: { event in
    switch event {
    case .attemptStarted:
        inFlight.increment()
    case .attemptSucceeded, .attemptFailed:
        inFlight.decrement()
    default:
        break
    }
}
// Cancelling the task leaves `inFlight` high; reconcile it where you cancel.
```

## Observing a PolicyChain

The ``PolicyChain`` shorthand factories build their policies for you, and those policies have **no** `onEvent` callback — so their events are silently dropped. To observe a chain, construct the policy yourself and pass the instance:

```swift
let chain = PolicyChain
    .retry(RetryPolicy(maxAttempts: 3, delay: .exponential(base: .seconds(1)), onEvent: { event in
        logger.debug("retry: \(event)")
    }))
    .circuitBreaker(sharedBreaker)   // breaker keeps whatever callback it was built with
    .timeout(TimeoutPolicy(duration: .seconds(5), onEvent: { event in
        logger.warning("timeout: \(event)")
    }))
```

The timeout sits inside the breaker deliberately — see Step 4 of
<doc:GettingStarted> for why that ordering matters.

A chain's fallback emits ``PolicyEvent/fallbackUsed`` only when you hand it a
callback directly — the resulting ``FallbackChain`` has none of its own:

```swift
let chain = PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
    .fallback(onEvent: { logger.warning("fallback: \($0)") }) { _ in Article.cached }

// The constant-value form takes the same callback.
let other = PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
    .fallback(Article.cached, onEvent: { logger.warning("fallback: \($0)") })
```

## Circuit Breaker Events

The simplest way to observe a circuit breaker is to pass an `onEvent` closure at initialisation:

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    timeout: .seconds(30),
    onEvent: { event in
        print("[CircuitBreaker] \(event)")
    }
)
```

The callback fires on every state change and call rejection:

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    timeout: .seconds(30),
    onEvent: { event in
        switch event {
        case .circuitStateChanged(let from, let to):
            logger.info("Circuit: \(from) -> \(to)")
        case .circuitCallRejected(let state):
            logger.warning("Call rejected in state: \(state)")
        default:
            break
        }
    }
)
```

## Retry Events

``RetryPolicy`` emits a richer lifecycle: attempt start, success, failure with next-delay hint, scheduled retry, and final exhaustion.

```swift
let policy = RetryPolicy(
    maxAttempts: 5,
    delay: .exponential(base: .seconds(1)),
    onEvent: { event in
        switch event {
        case .attemptStarted(let attempt):
            logger.debug("attempt \(attempt) starting")
        case .attemptFailed(let attempt, let error, let nextDelay):
            logger.warning("attempt \(attempt) failed: \(error); next in \(nextDelay ?? .zero)")
        case .retryExhausted(let totalAttempts, let lastError):
            logger.error("all \(totalAttempts) attempts exhausted: \(lastError)")
        default:
            break
        }
    }
)
```

## EventStream

``EventStream`` wraps an `AsyncStream` in a `Sendable` `final class` that can be shared across tasks. It is generic over any `Sendable` event type and — like the built-in `onEvent` surface — emits synchronously so callers inside actors can publish without suspension:

```swift
let stream = EventStream<PolicyEvent>()

// Producer
stream.emit(.attemptStarted(attempt: 1))
stream.emit(.attemptSucceeded(attempt: 1, duration: .milliseconds(200)))
stream.finish()

// Consumer
for await event in stream {
    print(event)
}
```

Use a single consumer task for deterministic delivery. If you need fan-out, forward events from that consumer to your own broadcaster. Under backpressure the default policy (`.bufferingNewest(1024)`) drops the oldest buffered events; pass a custom `AsyncStream.Continuation.BufferingPolicy` to `EventStream.init(bufferingPolicy:)` if you need different behaviour.

### Ending a Stream

``EventStream/finish()`` is what ends a consumer. Being a reference type, the
stream also finishes itself in `deinit` when its last reference goes away — but
that is a backstop, not a teardown strategy. A consumer written the usual way
holds a reference of its own, because `for await event in stream` captures
`stream` in the enclosing task's closure, so while the loop is suspended the
object cannot be deinitialised and the backstop never fires:

```swift
let stream = EventStream<PolicyEvent>()
let consumer = Task {
    for await event in stream { await telemetry.record(event) }
}

// Required — without it the consumer stays suspended for the process lifetime.
stream.finish()
await consumer.value
```

Cancelling the consumer task is the alternative, and the right choice when the
stream must stay alive for other consumers or producers.

Producers hold a reference as well: a policy built with
`onEvent: { stream.emit($0) }` keeps the stream alive for the policy's whole
lifetime, so dropping your own reference ends nothing — ``EventStream/finish()``
still does. If the closure reaches the stream through `self` on an object that
also stores the policy, it closes a reference cycle; capture the stream itself
(`let events = self.events`) rather than `self`.

### Fanning Policy Events into a Shared Stream

A common pattern: route events from several policies into a single stream that your metrics layer consumes.

```swift
let events = EventStream<PolicyEvent>()

let breaker = CircuitBreaker(failureThreshold: 5, onEvent: { events.emit($0) })
let retry   = RetryPolicy(maxAttempts: 3, onEvent: { events.emit($0) })

Task {
    for await event in events {
        await telemetry.record(event)
    }
}
```

## Real-World Example: Logging Integration

Route policy events to your structured logger:

```swift
import OSLog

let logger = Logger(subsystem: "com.app", category: "Resilience")

let breaker = CircuitBreaker(
    failureThreshold: 5,
    timeout: .seconds(30),
    onEvent: { event in
        switch event {
        case .circuitStateChanged(let from, let to):
            logger.notice("Circuit transitioned from \(from) to \(to)")

        case .circuitCallRejected(let state):
            logger.warning("Request rejected in circuit state: \(state)")

        default:
            break
        }
    }
)
```

## Real-World Example: Metrics and Alerting

Feed events into a metrics SDK and fire alerts when circuits open:

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    timeout: .seconds(30),
    onEvent: { event in
        switch event {
        case .circuitStateChanged(_, let to):
            Metrics.gauge("circuit_breaker.state").set(to.description)
            if case .open = to {
                Alerting.fire(
                    title: "Circuit Breaker Opened",
                    message: "Payment service circuit is open. Calls are being rejected."
                )
            }

        case .circuitCallRejected:
            Metrics.counter("circuit_breaker.rejected").increment()

        default:
            break
        }
    }
)
```

## PolicyEvent Reference

``PolicyEvent`` defines the full resilience event vocabulary. Every case is emitted by the policy listed below via its `onEvent` callback, and any case can be emitted manually through ``EventStream``.

| Event | Built-in source |
|---|---|
| `attemptStarted(attempt:)` | ``RetryPolicy`` |
| `attemptSucceeded(attempt:duration:)` | ``RetryPolicy`` |
| `attemptFailed(attempt:error:nextDelay:)` | ``RetryPolicy`` |
| `retryExhausted(totalAttempts:lastError:)` | ``RetryPolicy`` |
| `retryScheduled(attempt:delay:)` | ``RetryPolicy`` |
| `circuitStateChanged(from:to:)` | ``CircuitBreaker`` |
| `circuitCallRejected(state:)` | ``CircuitBreaker`` |
| `timeoutExceeded(duration:)` | ``TimeoutPolicy`` |
| `fallbackUsed` | ``FallbackPolicy``, ``FallbackChain`` (when given `onEvent`) |
