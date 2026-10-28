# Getting Started

Add SafeRetry to your project and start protecting calls in minutes.

## Step 1: Add the Package

Add SafeRetry as a dependency in your `Package.swift` or via Xcode's
**File > Add Package Dependencies**:

```swift
dependencies: [
    .package(url: "https://github.com/Toni77777/SafeRetry.git", branch: "main")
]
```

> Important: no version has been tagged yet, so depend on `branch: "main"`.
> Once `1.0.0` is tagged, switch to `from: "1.0.0"`.

Then add the `SafeRetry` product to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SafeRetry", package: "SafeRetry")
    ]
)
```

Import the module wherever you need it:

```swift
import SafeRetry
```

## Step 2: Your First Retry

Wrap any async call in ``SafeRetry/retry(attempts:delay:_:)`` to automatically retry on failure with exponential backoff:

```swift
let user = try await SafeRetry.retry(attempts: 3) {
    try await api.fetchUser(id: 42)
}
```

For finer control, create a ``RetryPolicy`` directly:

```swift
let policy = RetryPolicy(
    maxAttempts: 5,
    delay: .exponential(base: .seconds(1), multiplier: 2.0, maxDelay: .seconds(30)),
    jitter: .full
)

let data = try await policy.execute {
    try await urlSession.data(from: url)
}
```

## Step 3: Your First Circuit Breaker

A ``CircuitBreaker`` prevents cascading failures by short-circuiting calls to a service that is down:

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    successThreshold: 2,
    timeout: .seconds(30)
)

do {
    let payment = try await breaker.execute {
        try await paymentGateway.charge(amount: total)
    }
} catch let error as CircuitBreakerError {
    switch error {
    case .open(let retryAfter):
        print("Service down. Retry after \(retryAfter).")
    case .halfOpenRejected:
        print("Recovery in progress, try again shortly.")
    }
}
```

Inspect the breaker's current state at any time:

```swift
let state = await breaker.state // .closed, .open(until:), or .halfOpen
```

## Step 4: Compose Policies

Use ``PolicyChain`` to stack multiple policies with a fluent API. Policies wrap from outermost (first) to innermost (last):

```swift
let result = try await PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1))) // outermost
    .circuitBreaker(breaker)                                    // middle
    .timeout(.seconds(5))                                       // innermost
    .execute {
        try await api.fetchUser(id: 42)
    }
```

Each attempt passes through the circuit breaker, and the 5-second timeout bounds
each attempt individually.

> Important: When a chain contains a ``CircuitBreaker``, put the ``TimeoutPolicy``
> *inside* it, as above. ``TimeoutPolicy`` enforces its deadline by cancelling the
> operation, and the breaker deliberately ignores cancellation — so
> `.timeout(…).circuitBreaker(breaker)` hides every timed-out call from the
> breaker's failure count, and a dependency that only ever hangs would never trip
> it. Reverse that to `.circuitBreaker(breaker).timeout(…)` and the breaker sees a
> ``TimeoutError`` it counts.

Add a fallback to return a value for non-cancellation failures:

```swift
let user = try await PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
    .fallback(CachedUser.default)
    .execute {
        try await api.fetchUser(id: 42)
    }
```

Or use a built-in preset:

```swift
let data = try await PolicyChain.Preset.default
    .execute { try await api.fetchData() }
```

## Step 5: Register Policies for Reuse

Register policies once at launch and retrieve them anywhere using ``PolicyRegistry``:

```swift
// At app startup
await SafeRetry.registry.register("payments", chain:
    PolicyChain
        .retry(attempts: 5, delay: .exponential(base: .seconds(1)))
        .circuitBreaker(CircuitBreaker(failureThreshold: 3, timeout: .seconds(60)))
)

// Anywhere in the app
let chain = try await SafeRetry.registry.chain(for: "payments")
let receipt = try await chain.execute {
    try await paymentGateway.charge(amount: total)
}
```

## Step 6: Resilient URLSession Requests

The `URLSession` extension comes in two forms, and they differ in **which
errors they retry** — pick deliberately.

`data(for:retrying:)` retries only failures that are plausibly transient:
`URLError.networkConnectionLost`, `.timedOut`, `.cannotConnectToHost`,
`.notConnectedToInternet`, `.dnsLookupFailed`, `.cannotFindHost`, and HTTP 5xx
(mapped to ``ServerError``). A bad URL or an unsupported scheme fails once and
propagates, because retrying would reproduce it:

```swift
let (data, response) = try await URLSession.shared.data(
    for: request,
    retrying: RetryPolicy(maxAttempts: 3, delay: .exponential(base: .seconds(1)))
)
```

`data(for:resilience:)` applies a whole ``PolicyChain`` instead, and retries
whatever that chain's retry policy retries — which, for a chain built with the
`retry(attempts:…)` shorthand or a ``PolicyChain/Preset``, means **every**
error, transient or not. Supply a `shouldRetry` predicate when you want the
filtered behaviour:

```swift
let chain = PolicyChain
    .timeout(.seconds(10))
    .retry(attempts: 3, delay: .exponential(base: .seconds(1))) { error, _ in
        (error as? URLError)?.code != .badURL
    }

let (data, response) = try await URLSession.shared.data(
    for: request,
    resilience: chain
)
```

> Note: HTTP 4xx responses — including `429 Too Many Requests` — are returned
> normally rather than retried, so inspect `response` for them yourself.

## Next Steps

- Learn about real-time observability in <doc:Observability>.
- Coming from RxSwift? See <doc:MigratingFromRxSwift>.
