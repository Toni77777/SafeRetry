# SafeRetry

[![Swift 6.4+](https://img.shields.io/badge/Swift-6.4%2B-F05138.svg)](https://swift.org)
[![iOS 16+](https://img.shields.io/badge/iOS-16%2B-blue.svg)](https://developer.apple.com/ios/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Composable resilience policies for Swift Concurrency — **retry**, **circuit breaker**, **timeout**, and **fallback** — with zero dependencies.

Built for Swift 6 strict concurrency. Inspired by [Resilience4j](https://resilience4j.readme.io) from the JVM world.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Toni77777/SafeRetry.git", branch: "main")
]
```

> **Note:** no version has been tagged yet, so depend on `branch: "main"` for now.
> Once `1.0.0` is tagged, switch to `from: "1.0.0"`.

Then add the `SafeRetry` product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SafeRetry", package: "SafeRetry")
    ]
)
```

## Table of contents

- [30-second tour](#30-second-tour)
- [Retry](#retry)
- [Circuit breaker](#circuit-breaker)
- [Timeout](#timeout)
- [Fallback](#fallback)
- [Composing policies](#composing-policies)
- [URLSession integration](#urlsession-integration)
- [Observability](#observability)
- [Policy registry](#policy-registry)
- [Cancellation](#cancellation)
- [Recipes](#recipes)
- [Feature matrix](#feature-matrix)
- [Documentation](#documentation)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [Releasing](#releasing)
- [License](#license)

## 30-second tour

```swift
import SafeRetry

// Retry a flaky call with exponential backoff.
let user = try await SafeRetry.retry(
    attempts: 3,
    delay: .exponential(base: .seconds(1))
) {
    try await api.fetchUser(id: 42)
}

// Protect a dependency with a circuit breaker.
let payments = CircuitBreaker(failureThreshold: 5, timeout: .seconds(30))
let receipt = try await payments.execute {
    try await paymentGateway.charge(amount: total)
}

// Compose policies end-to-end and fall back to a cached value on failure.
let content = CircuitBreaker(failureThreshold: 5, timeout: .seconds(30))
let article = try await PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)), jitter: .equal)
    .circuitBreaker(content)
    .timeout(.seconds(10))
    .fallback(Article.cached)
    .execute { try await api.fetchArticle(slug: "hello") }
```

The timeout sits **inside** the breaker on purpose — see
[Choosing an order](#choosing-an-order).

## Retry

The basics:

```swift
// `SafeRetry.retry` defaults to exponential backoff with a 1 s base, so this
// waits ~1 s then ~2 s between attempts.
try await SafeRetry.retry(attempts: 3) {
    try await api.fetchSettings()
}

// Pass `.immediate` explicitly for an in-process resource, where backing off
// buys nothing.
try await SafeRetry.retry(attempts: 3, delay: .immediate) {
    try await cache.load(key: "session")
}

// Exponential backoff with jitter — the right default for remote calls.
let policy = RetryPolicy(
    maxAttempts: 5,
    delay: .exponential(base: .seconds(1), multiplier: 2, maxDelay: .seconds(30)),
    jitter: .equal
)

let response = try await policy.execute {
    try await api.post(endpoint: "/orders", body: order)
}
```

### Only retry what makes sense

Not every failure is worth retrying. A 4xx response means the client is wrong; retrying won't help. Without a predicate, a policy retries every error except `CircuitBreakerError` (see [Choosing an order](#choosing-an-order)). Use `shouldRetry` to filter — it replaces that default rather than adding to it:

```swift
enum APIError: Error {
    case badRequest, unauthorized, serverError, networkDown
    var isTransient: Bool {
        switch self {
        case .serverError, .networkDown: return true
        case .badRequest, .unauthorized: return false
        }
    }
}

let result = try await policy.execute(
    shouldRetry: { error, _ in (error as? APIError)?.isTransient == true }
) {
    try await api.fetch()
}
```

### Backoff strategies

| Strategy | When to use |
|---|---|
| `.immediate` | In-process retries; no contended resource (e.g. cache, in-memory state). |
| `.fixed(.seconds(1))` | Predictable, low-frequency background tasks. |
| `.linear(initial:, increment:, maxDelay:)` | Smooth ramp-up when servers are warming up. |
| `.exponential(base:, multiplier:, maxDelay:)` | Default for external APIs and DBs. Prevents hammering. |
| `.custom { attempt in … }` | Anything you need: Fibonacci, deadline-aware, etc. |

Pair exponential backoff with jitter to avoid a thundering herd when many clients retry at the same time:

```swift
// Without jitter: 1s, 2s, 4s, 8s — every client retries at exactly the same moment.
// With .equal jitter: 0.5–1s, 1–2s, 2–4s, 4–8s — spreads load evenly.
let policy = RetryPolicy(
    maxAttempts: 5,
    delay: .exponential(base: .seconds(1)),
    jitter: .equal
)
```

## Circuit breaker

A circuit breaker short-circuits calls to a failing dependency, giving it time to recover instead of piling on requests. States:

- **closed** — normal operation, failures are counted within a rolling window
- **open** — all calls are rejected immediately with `CircuitBreakerError.open(retryAfter:)`
- **half-open** — a limited number of trial calls probe for recovery

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,        // 5 failures in rollingWindow → open
    successThreshold: 2,        // 2 successes in half-open → close
    halfOpenMaxCalls: 1,        // only one probe call at a time
    timeout: .seconds(30),      // stay open for 30s before probing
    rollingWindow: .seconds(60) // count failures over a 60s window
)

do {
    let quote = try await breaker.execute {
        try await stockApi.quote(symbol: "AAPL")
    }
} catch CircuitBreakerError.open(let retryAfter) {
    // Fast-fail; tell the UI to show a friendly message.
    showBanner("Market data unavailable. Retry in \(retryAfter).")
}

// Inspect or force-reset. `state` reports `.halfOpen` once the open window has
// elapsed, which is what the next call will actually encounter — so a status
// view polling it never shows a recovered dependency as still rejecting.
let state = await breaker.state
await breaker.reset()
```

### Not every error is the dependency's fault

By default the breaker counts every thrown error as evidence that the
dependency is unhealthy. That is wrong for errors that are the *caller's*
problem — a validation rejection, a decoded `404`, a business-rule failure.
Pass `isFailure` to exclude them; they still propagate to the caller, they just
don't move the breaker toward `.open`:

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    isFailure: { error in
        // A 404 means we asked for the wrong thing, not that the service is down.
        !(error is NotFoundError) && !(error is ValidationError)
    }
)
```

Cancellation is always exempt, whatever `isFailure` returns. Like `onEvent`,
the predicate runs synchronously on the breaker's actor executor, so keep it to
type checks and cheap property reads — blocking in it blocks every call through
the breaker.

### Bound the probe

Only the **open** state has a deadline (`timeout`). Half-open has none: it ends
when a trial call completes, one way or the other. So an operation that never
returns holds the trial slot indefinitely, and with the default
`halfOpenMaxCalls: 1` every later call is rejected with `.halfOpenRejected` —
whose `retryAfter` is `nil`, because there is no deadline to report. Short of
`reset()`, the breaker never leaves that state.

Give the breaker a bounded operation, with the timeout *inside* it so the
breaker sees a `TimeoutError` rather than the cancellation it ignores:

```swift
let chain = PolicyChain
    .circuitBreaker(breaker)
    .timeout(.seconds(5))
```

`CircuitBreakerError` also exposes a uniform `retryAfter` so callers can back
off without switching on the case (`nil` for `.halfOpenRejected`, whose slot
frees when the in-flight probe completes rather than at a deadline):

```swift
} catch let error as CircuitBreakerError {
    try await Task.sleep(for: error.retryAfter ?? .seconds(1))
}
```

**One breaker per dependency.** Treat the breaker as a long-lived instance (e.g. stored on a service), not as something constructed per call — it must accumulate failure history to be useful.

## Timeout

Cancel operations that exceed a deadline. Uses `withThrowingTaskGroup` under the hood, so cancellation is structured and clean.

```swift
let policy = TimeoutPolicy(duration: .seconds(5))

do {
    let data = try await policy.execute {
        try await URLSession.shared.data(from: url).0
    }
} catch is TimeoutError {
    // Operation exceeded 5s and was cancelled.
}
```

The deadline is enforced by cancelling the operation, so it has to be
cancellation-aware (`URLSession`, `Task.sleep`, `Task.checkCancellation()`); one
that ignores cancellation delays the `TimeoutError` until it finishes. Each call
also spawns a task group with two child tasks — negligible next to a network
request, but far more than an in-memory read, so keep timeouts off hot
in-process paths.

## Fallback

Return a graceful default when an operation fails:

```swift
// Constant fallback — useful for defaults.
let prefs = try await FallbackPolicy(value: UserPreferences.defaults).execute {
    try await api.loadPreferences()
}

// Handler fallback — inspect the error, route, or transform. The handler can
// itself throw a different error instead of producing a value.
let article = try await FallbackPolicy(handler: { error in
    logger.warning("Primary failed: \(error). Serving from disk cache.")
    return try await diskCache.load(.article) ?? .empty
}).execute {
    try await api.fetchArticle()
}
```

Cancellation is never swallowed — `CancellationError` and `URLError(.cancelled)` propagate unchanged so structured concurrency stays correct.

`PolicyChain.fallback(_:)` / `.fallback(onEvent:_:)` mirror this: the handler
form can throw, and both accept an optional `onEvent` to observe `.fallbackUsed`
(see [Observing a chain](#observing-a-chain)).

## Composing policies

Real systems need several policies together. `PolicyChain` composes them in **outermost-first** order: the first policy you add wraps everything after it.

```swift
let chain = PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)))  // outermost policy
    .circuitBreaker(sharedBreaker)
    .timeout(.seconds(5))                                        // innermost policy
    .fallback(Article.cached)                                    // terminates the chain

// Execution flow per call:
//   retry (up to 3 attempts) ─▶ breaker ─▶ timeout (5s per attempt) ─▶ operation
//   on failure anywhere:     ─▶ fallback (throws only for cancellation, or if the handler itself throws)

let article = try await chain.execute {
    try await api.fetchArticle(slug: slug)
}
```

`fallback` is not a layer in the wrapping order — it terminates the builder and
returns a `FallbackChain` that catches whatever escapes the whole chain. So it
always sees the *outermost* error, whichever policy produced it.

The order above is the one to reach for when a chain contains a breaker: the
timeout is innermost, so a hung call reaches the breaker as a `TimeoutError`
that counts. Wrapping the breaker in the timeout instead — a natural way to ask
for a total budget — hides exactly those failures from it, for the reason
described below.

### Choosing an order

A working mental model: **outer policies see aggregate behaviour; inner policies see individual attempts.**

- `timeout` **outside** `retry` — bounds the *entire* operation including all retries. Often what you want.
- `timeout` **inside** `retry` — bounds *each individual attempt*. Useful when one attempt can hang but you still want 2 more tries.
- `circuitBreaker` **inside** `retry` — every attempt goes through the breaker, so a tripped breaker rejects the attempt immediately without touching the dependency, and the retry gives up there: without a `shouldRetry`, a `CircuitBreakerError` is not retried, so no backoff is waited out against a breaker that would only reject again. A predicate you pass decides for `CircuitBreakerError` too, so one that returns `true` for it runs every attempt and waits out every backoff delay between the rejections:
  ```swift
  .retry(attempts: 3, delay: .exponential(base: .seconds(1))) { _, _ in true }
  ```
- `circuitBreaker` **outside** `retry` — the breaker sees one call per *whole* retry sequence, so an exhausted 3-attempt sequence records a single failure. The dependency still takes all 3 attempts, which defeats the point of a breaker; keep it inside.

### Put the timeout inside the breaker

This one is easy to get backwards. `TimeoutPolicy` enforces its deadline by
**cancelling** the operation, and a circuit breaker deliberately ignores
cancellation — it says nothing about the dependency's health. So with the
timeout on the outside, the breaker's in-flight call is cancelled and the
failure is never recorded:

```swift
// ✗ A dependency that always hangs never trips this breaker.
PolicyChain.timeout(.seconds(5)).circuitBreaker(breaker)

// ✓ The breaker sees a TimeoutError and counts it.
PolicyChain.circuitBreaker(breaker).timeout(.seconds(5))
```

Hanging is one of the main things a breaker is there to catch, so unless you
specifically want timeouts excluded from the failure count, the timeout belongs
inside. The same ordering protects half-open recovery: see
[Bound the probe](#bound-the-probe).

### Presets

Ready-made chains for the common shapes:

```swift
PolicyChain.Preset.default       // 3 attempts, exponential backoff (1s base)
PolicyChain.Preset.aggressive    // 10 attempts, exponential backoff (500ms base)
PolicyChain.Preset.conservative  // 2 attempts @ fixed 2s delay, 5s timeout per attempt

let data = try await PolicyChain.Preset.default
    .execute { try await api.fetchData() }

// Layer a shared breaker onto a preset.
let chain = PolicyChain.Preset.default.circuitBreaker(myBreaker)
```

Attempt counts include the first call, so `.default` retries at most twice.
A preset's retry carries no `shouldRetry`, so it retries every error except
`CircuitBreakerError`: against an open breaker it gives up at the first
rejection instead of waiting out its backoff.

`.conservative` puts the timeout *inside* the retry so a slow first attempt
cannot consume the whole budget. Presets deliberately exclude a circuit
breaker — a breaker must be a long-lived shared instance to accumulate failure
history, so you append your own.

Appending always adds the *innermost* layer, so `.conservative.circuitBreaker(b)`
lands the breaker inside that preset's timeout — the ordering that hides
timed-out calls from the breaker. Build the chain yourself when you want both:

```swift
let chain = PolicyChain
    .retry(attempts: 2, delay: .fixed(.seconds(2)))
    .circuitBreaker(sharedBreaker)
    .timeout(.seconds(5))
```

## URLSession integration

A batteries-included extension that plugs resilience straight into `URLSession`:

```swift
// Retry on transient URLError + HTTP 5xx; 4xx passes through for the caller to inspect.
let policy = RetryPolicy(
    maxAttempts: 3,
    delay: .exponential(base: .seconds(1)),
    jitter: .equal
)
let (data, response) = try await URLSession.shared.data(
    for: URLRequest(url: url),
    retrying: policy
)

// Full chain (retry + breaker + timeout) wrapping a request.
let chain = PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
    .circuitBreaker(sharedBreaker)
    .timeout(.seconds(10))

let (body, http) = try await URLSession.shared.data(
    for: request,
    resilience: chain
)
```

HTTP 5xx responses are mapped to `ServerError(statusCode:)` so retry policies can treat them uniformly with network errors.

**The two entry points retry different things.** `retrying:` filters through a
transient-error allowlist (the `URLError` codes above plus `ServerError`), so a
`badURL` fails once. `resilience:` retries whatever the chain's retry policy
retries — and the `retry(attempts:)` shorthand and the presets carry no
`shouldRetry`, so they retry every error except `CircuitBreakerError`,
transient or not. Pass a predicate when you want the filtered behaviour:

```swift
let chain = PolicyChain
    .timeout(.seconds(10))
    .retry(attempts: 3, delay: .exponential(base: .seconds(1))) { error, _ in
        (error as? URLError)?.code != .badURL
    }
```

HTTP 4xx responses — including `429 Too Many Requests` — are returned normally
rather than retried, so inspect the response for them yourself.

## Observability

Every policy can emit `PolicyEvent`s — attempt started/succeeded/failed, retry scheduled, circuit state changed, call rejected, timeout exceeded, fallback used. Use them for logging, metrics, or analytics.

> **Callbacks are synchronous.** They run inline with policy execution, in the order events occur, so keep them fast. For async work (writing to disk, hitting an HTTP endpoint), spawn a `Task` inside the closure — but tasks spawned per event run concurrently and can finish out of order. When the consumer needs the sequence (a breaker's state history, say), forward into an [`EventStream`](#event-stream) and drain it from one task instead.

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    timeout: .seconds(30),
    onEvent: { event in
        switch event {
        case .circuitStateChanged(let from, let to):
            metrics.counter("breaker.state", tags: ["from": "\(from)", "to": "\(to)"]).increment()
        case .circuitCallRejected:
            metrics.counter("breaker.rejected").increment()
        default:
            break
        }
    }
)

// Retry policy with the same observer surface.
let retry = RetryPolicy(
    maxAttempts: 3,
    delay: .exponential(base: .seconds(1)),
    onEvent: { event in
        if case .attemptFailed(let attempt, let error, _) = event {
            logger.warning("attempt \(attempt) failed: \(error)")
        }
    }
)
```

### Observing a chain

The `PolicyChain` shorthands — `.retry(attempts:…)` and `.timeout(_ duration:)`
— build policies with **no** `onEvent` callback, so their events are invisible.
Pass a pre-built policy instead:

```swift
let chain = PolicyChain
    .retry(RetryPolicy(maxAttempts: 3, delay: .exponential(base: .seconds(1)), onEvent: {
        logger.debug("retry: \($0)")
    }))
    .timeout(TimeoutPolicy(duration: .seconds(5), onEvent: {
        logger.warning("timeout: \($0)")
    }))
```

`.fallback(…)` on a chain emits `.fallbackUsed` too, but only if you pass an
`onEvent` callback to it directly — it has no `onEvent` of its own by default:

```swift
let chain = PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
    .fallback(onEvent: { logger.warning("fallback: \($0)") }) { _ in Article.cached }
```

### Event stream

When you want to consume events as an `AsyncSequence` (one consumer), use `EventStream`:

```swift
let stream = EventStream<PolicyEvent>()

let breaker = CircuitBreaker(failureThreshold: 5, onEvent: { event in
    stream.emit(event)   // synchronous, non-blocking
})

let consumer = Task {
    for await event in stream {
        await telemetry.record(event)
    }
}
```

Call `stream.finish()` when the producer is done — it ends the `for await` loop
once the buffer drains, so calling it right after you start the consumer
delivers nothing, and never calling it leaves the consumer suspended forever:

```swift
stream.finish()
await consumer.value
```

`EventStream` is a `final class` whose `deinit` finishes the stream, so a
dropped stream terminates anything still reading it. Treat that as a backstop
rather than a teardown strategy: the consumer above holds a reference of its
own — `for await event in stream` captures `stream` in the task's closure — so
while that loop is suspended the object cannot be deinitialised and the
backstop never fires. Producers hold one too: the breaker's `onEvent` closure
above keeps `stream` alive for as long as the breaker lives. (If that closure
reached the stream through `self` on an object that also stores the breaker, it
would close a reference cycle — capture the stream, not `self`.) The backstop
covers the narrower case where only an iterator outlives the stream:

```swift
var iterator = makeStreamAndEmit()              // the EventStream goes out of scope
while let event = await iterator.next() { … }   // terminates
```

Cancelling the consumer is the other way out, and the one to use when the
stream should stay alive for other consumers or producers:

```swift
deinit {
    consumer.cancel()
}
```

## Policy registry

For apps with many resilient call-sites, register policies once at startup and resolve them by name:

```swift
// At app launch.
await SafeRetry.registry.register(
    "payments",
    chain: PolicyChain
        .retry(attempts: 3, delay: .exponential(base: .seconds(1)), jitter: .equal)
        .circuitBreaker(CircuitBreaker(failureThreshold: 3, timeout: .seconds(60)))
        .timeout(.seconds(15))
)

await SafeRetry.registry.register(
    "analytics",
    chain: PolicyChain.retry(attempts: 2, delay: .fixed(.seconds(1)))
)

// Anywhere in your codebase.
let chain = try await SafeRetry.registry.chain(for: "payments")
let receipt = try await chain.execute {
    try await paymentGateway.charge(amount: total)
}
```

The registry is an `actor`, so registration and lookup are safe from any isolation domain.

## Cancellation

Cooperation with Swift's structured cancellation is a first-class concern:

- `Task.cancel()` on the calling task stops retries at the next checkpoint — no further attempts are scheduled.
- Every policy checks on entry: a task that is already cancelled when it reaches a retry, breaker, timeout, or fallback gets `CancellationError` without the operation running — no request is sent on behalf of a caller who has gone away, and no half-open trial slot is taken.
- Cancellation always propagates unchanged — fallback/retry do not swallow it.
- The circuit breaker does not count cancellations as dependency failures.
- `TimeoutPolicy` cancels the wrapped operation's child task when the timer fires.
- Cancellation is not a policy outcome, so no policy emits an event for it. A cancelled attempt's `attemptStarted` has no matching `attemptSucceeded`/`attemptFailed`/`retryExhausted`, and a cancelled operation produces no `fallbackUsed`.

**Two spellings count as cancellation.** Swift's own is `CancellationError`, but
`URLSession` reports a cancelled task as `URLError(.cancelled)`. Every policy
recognises both — otherwise cancelling a screen's in-flight requests would burn
retry attempts, trip circuit breakers, and quietly hand back fallback values:

```swift
// Both of these propagate untouched: no retry, no fallback substitution,
// and no failure recorded against the breaker.
throw CancellationError()
throw URLError(.cancelled)
```

```swift
let task = Task {
    try await PolicyChain.Preset.aggressive
        .execute { try await api.longPoll() }
}

// Later — user navigated away.
task.cancel()   // retries stop, in-flight call is cancelled.
```

## Recipes

### Idempotent GET with caching fallback

```swift
func loadFeed() async -> [Post] {
    let chain = PolicyChain
        .timeout(.seconds(8))
        .retry(attempts: 3, delay: .exponential(base: .milliseconds(500)), jitter: .full)
        .fallback { _ in (try? await cache.posts()) ?? [] }

    return (try? await chain.execute { try await api.fetchFeed() }) ?? []
}
```

### Non-idempotent POST — retry carefully

Only retry on network-level errors; never on server-side ambiguous failures.

```swift
let policy = RetryPolicy(
    maxAttempts: 3,
    delay: .exponential(base: .seconds(1)),
    jitter: .equal
)

let receipt = try await policy.execute(
    shouldRetry: { error, _ in
        // Retry only if the request definitely didn't reach the server.
        (error as? URLError)?.code == .notConnectedToInternet ||
        (error as? URLError)?.code == .networkConnectionLost
    }
) {
    try await api.submitOrder(order, idempotencyKey: key)
}
```

### Shared circuit breaker per remote service

```swift
enum Services {
    static let payments = CircuitBreaker(failureThreshold: 3, timeout: .seconds(30))
    static let search   = CircuitBreaker(failureThreshold: 10, timeout: .seconds(10))
    static let images   = CircuitBreaker(failureThreshold: 20, timeout: .seconds(5))
}

// Anywhere you call that service:
try await Services.payments.execute { try await paymentGateway.charge(amount) }
```

### Graceful degradation with tiered fallback

```swift
let article = try await PolicyChain
    .timeout(.seconds(5))
    .retry(attempts: 2, delay: .fixed(.seconds(1)))
    .fallback { error in
        if let cached = await cache.article(slug) { return cached }
        if let staleDisk = try? await disk.staleArticle(slug) { return staleDisk }
        return .placeholder
    }
    .execute { try await api.fetchArticle(slug: slug) }
```

### Per-attempt timeout inside an overall budget

```swift
let chain = PolicyChain
    .timeout(.seconds(20))                              // total budget
    .retry(attempts: 4, delay: .exponential(base: .seconds(1)))
    .timeout(.seconds(5))                               // per-attempt cap

let result = try await chain.execute { try await api.query() }
```

## Feature matrix

| Feature | SafeRetry | swift-retry | Kitura CircuitBreaker |
|---|:---:|:---:|:---:|
| Swift 6 / strict concurrency | ✅ | Partial | ❌ |
| async/await native | ✅ | ✅ | ❌ (callback) |
| Retry with backoff | ✅ | ✅ | ❌ |
| Exponential + jitter | ✅ | Limited | ❌ |
| Circuit breaker | ✅ | ❌ | ✅ |
| Timeout policy | ✅ | ❌ | ❌ |
| Fallback policy | ✅ | ❌ | ❌ |
| Policy composition | ✅ | ❌ | ❌ |
| Named policy registry | ✅ | ❌ | ❌ |
| AsyncStream observability | ✅ | ❌ | ❌ |
| URLSession extension | ✅ | ❌ | ❌ |
| Zero dependencies | ✅ | ✅ | ❌ |
| iOS 16+ / macOS 13+ | ✅ | ✅ | macOS only |

## Components

| Component | Description |
|---|---|
| **RetryPolicy** | Retry with configurable max attempts, delay strategy, and jitter |
| **DelayStrategy** | `.immediate`, `.fixed`, `.linear`, `.exponential`, `.custom` |
| **JitterStrategy** | `.none`, `.full`, `.equal` |
| **CircuitBreaker** | Three-state machine (closed/open/half-open) with rolling window |
| **TimeoutPolicy** | Cancels operations exceeding a duration via structured concurrency |
| **FallbackPolicy** | Returns a constant value or handler result on failure |
| **PolicyChain** | Fluent builder composing any combination of policies |
| **PolicyChain.Preset** | `.default`, `.aggressive`, `.conservative` ready-made chains |
| **FallbackChain** | Chain terminated with a fallback; throws only on cancellation or a throwing handler |
| **PolicyRegistry** | Actor-isolated named storage for reusable policies |
| **EventStream** | `AsyncSequence`-based event delivery (`final class`, single consumer, bounded buffer, ended by `finish()`) |
| **PolicyEvent** | Shared event vocabulary for retry, circuit breaker, timeout, fallback |
| **URLSession+SafeRetry** | `data(for:retrying:)` and `data(for:resilience:)` extensions |
| **ServerError** | Typed error for HTTP 5xx responses (retried by `data(for:retrying:)`) |

## Documentation

Full DocC documentation is available in the `Sources/SafeRetry/Documentation.docc` catalog. Build it locally:

```bash
SAFERETRY_BUILD_DOCS=1 swift package generate-documentation --target SafeRetry
```

The environment variable opts into `swift-docc-plugin`, which is a build-time
plugin only. Gating it this way keeps the package dependency-free for anything
that depends on SafeRetry.

Articles included:

- **Getting Started** — SPM setup, first retry, first circuit breaker, composition
- **Observability** — AsyncStream events, logging, and alerting integration
- **Migrating from RxSwift** — Side-by-side comparisons and 5-step migration guide

## Requirements

- Swift 6.4+ (Xcode 27+)
- iOS 16.0+ / macOS 13.0+ / tvOS 16.0+ / watchOS 9.0+

Swift 6.4 is the oldest toolchain the test suite and CI are verified on.
`Package.swift` declares tools version 6.0, so an earlier Swift 6 compiler will
attempt the build, but that combination is untested.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Ensure all tests pass (`swift test`)
4. Commit your changes with a descriptive message
5. Push to your branch and open a Pull Request

Please ensure:
- All public API has DocC documentation
- New features include tests using Swift Testing framework
- Code compiles under Swift 6 strict concurrency checking
- No external dependencies are added

## Releasing

Swift Package Manager resolves **git tags**, so publishing a version is just
pushing a semver tag — no automation involved:

```bash
git checkout main && git pull
git tag 1.0.0
git push origin 1.0.0
```

From that moment consumers can depend on it:

```swift
.package(url: "https://github.com/Toni77777/SafeRetry.git", from: "1.0.0")
```

The tag has to be semver — `1.0.0` or `v1.0.0`, both are understood — and point
at a commit with `Package.swift` at the repository root.

Before tagging, move the `## [Unreleased]` entries in [CHANGELOG.md](CHANGELOG.md)
under a `## [X.Y.Z] - YYYY-MM-DD` heading and merge that to `main`, so the tag
names a commit whose changelog describes it.

> **Don't move a published tag.** Repointing a tag someone has already resolved
> breaks their build in a way that is hard to diagnose, because the version
> number no longer matches what their `Package.resolved` recorded. Ship a new
> patch version instead.

A tag is all SPM needs. A GitHub Release is a separate, optional thing: pushing
a tag does not create one, and nothing in this repository does either. Make one
by hand (`gh release create 1.0.0 --notes-file notes.md`, or the web UI) if you
want a page to announce from.

## License

SafeRetry is available under the MIT License. See [LICENSE](LICENSE) for details.
