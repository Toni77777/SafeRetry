# Migrating from RxSwift

Replace RxSwift retry and circuit breaker patterns with SafeRetry's async/await API.

## Overview

If your project uses RxSwift for retry logic or third-party circuit breaker operators, SafeRetry offers a direct replacement built on Swift Concurrency. This guide walks through the key differences and a step-by-step migration plan.

## Side-by-Side: Retry

### RxSwift

Core RxSwift's `retry(_:)` resubscribes immediately; exponential backoff usually
comes from RxSwiftExt's `retry(_:scheduler:)`:

```swift
api.fetchUser(id: 42)
    .retry(.exponentialDelayed(maxCount: 3, initial: 1, multiplier: 2),
           scheduler: MainScheduler.instance)
    .subscribe(onNext: { user in
        print(user)
    }, onError: { error in
        print("Failed after retries: \(error)")
    })
    .disposed(by: disposeBag)
```

### SafeRetry

```swift
do {
    let user = try await SafeRetry.retry(attempts: 3) {
        try await api.fetchUser(id: 42)
    }
    print(user)
} catch {
    print("Failed after retries: \(error)")
}
```

**Key differences:**

| Aspect | RxSwift | SafeRetry |
|---|---|---|
| Concurrency model | Reactive streams | async/await |
| Backoff | RxSwiftExt or a hand-written `retry(when:)` | Built-in ``DelayStrategy`` |
| Jitter | Not built in | ``JitterStrategy/full`` / ``JitterStrategy/equal`` |
| Cancellation | `DisposeBag` | Cooperative `Task` cancellation |
| Thread safety | `Scheduler` | `Sendable` + actor isolation |

## Side-by-Side: Circuit Breaker

### RxSwift (typical third-party pattern)

```swift
let breaker = RxCircuitBreaker(
    maxFailures: 5,
    resetTimeout: 30
)

breaker.call {
    api.fetchPayment(id: paymentId)
}
.subscribe(onNext: { payment in
    process(payment)
}, onError: { error in
    handleCircuitOpen(error)
})
.disposed(by: disposeBag)
```

### SafeRetry

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    timeout: .seconds(30)
)

do {
    let payment = try await breaker.execute {
        try await api.fetchPayment(id: paymentId)
    }
    process(payment)
} catch let error as CircuitBreakerError {
    handleCircuitOpen(error)      // .open(retryAfter:) or .halfOpenRejected
} catch {
    handleRequestFailure(error)   // the dependency's own error
}
```

**Key differences:**

| Aspect | RxSwift | SafeRetry |
|---|---|---|
| State machine | Internal, no direct access | `await breaker.state` |
| Half-open control | Implicit | Configurable `successThreshold`, `halfOpenMaxCalls` |
| Rolling window | Rarely supported | Built-in `rollingWindow` parameter |
| Events | `.do(onNext:)` side effects | ``PolicyEvent`` via `onEvent` callback |
| Typed errors | Erased to `Error` | ``CircuitBreakerError`` with associated values |

## Side-by-Side: Composition

### RxSwift

```swift
api.fetchUser(id: 42)
    .timeout(.seconds(10), scheduler: MainScheduler.instance)
    .retry(3)
    .catchAndReturn(CachedUser.default)
    .subscribe(onNext: { user in
        display(user)
    })
    .disposed(by: disposeBag)
```

Each Rx operator wraps everything *above* it, so `retry(3)` resubscribes to the
timed-out source: every attempt gets a fresh 10-second timeout.

### SafeRetry

```swift
let user = try await PolicyChain
    .retry(attempts: 3, delay: .exponential(base: .seconds(1)))
    .timeout(.seconds(10))
    .fallback(CachedUser.default)
    .execute {
        try await api.fetchUser(id: 42)
    }
display(user)
```

A ``PolicyChain`` reads the other way round — the first policy added is the
outermost — so the retry and timeout swap places. Keeping the Rx order,
`.timeout(.seconds(10)).retry(…)`, would turn the per-attempt timeout into a
single 10-second budget for all three attempts and their backoff delays.

## Migration Guide

### Step 1: Add SafeRetry as a Dependency

Add the package to your `Package.swift` or Xcode project. SafeRetry and RxSwift can coexist — you don't need to remove RxSwift immediately.

```swift
dependencies: [
    .package(url: "https://github.com/Toni77777/SafeRetry.git", branch: "main")
]
```

> Important: no version has been tagged yet, so depend on `branch: "main"`.
> Once `1.0.0` is tagged, switch to `from: "1.0.0"`.

### Step 2: Convert Retry Calls

Find every `.retry()` operator in your Rx chains. Replace each with a `SafeRetry.retry` call or a ``RetryPolicy``:

```swift
// Before
observable.retry(3).subscribe(...)

// After
let result = try await SafeRetry.retry(attempts: 3) {
    try await asyncVersion()
}
```

If the retried call is not yet `async`, wrap it using `withCheckedThrowingContinuation` first, or migrate the networking layer.

### Step 3: Replace Circuit Breakers

Create a ``CircuitBreaker`` actor for each service endpoint. Store them at the app level or in a ``PolicyRegistry``:

```swift
await SafeRetry.registry.register("payments", circuitBreaker:
    CircuitBreaker(failureThreshold: 5, timeout: .seconds(30))
)
```

### Step 4: Migrate Composition Chains

Replace chained Rx operators with ``PolicyChain``, **reversing their order**. An
Rx chain reads innermost-first — each operator wraps the ones above it — while a
``PolicyChain`` reads outermost-first. Translate the operators from the bottom
of the Rx chain up, with one exception: the fallback terminates the chain in
both, so it stays last.

| RxSwift operator | PolicyChain equivalent |
|---|---|
| `.timeout(.seconds(10), scheduler:)` | `.timeout(.seconds(10))` |
| `.retry(3)` | `.retry(attempts: 3)` — immediate, like Rx; pass `delay:` for backoff |
| `.catchAndReturn(v)` | `.fallback(v)` (terminal; catches non-cancellation errors) |

### Step 5: Migrate Observability

Replace `.do(onNext:onError:)` side effects with ``PolicyEvent`` callbacks:

```swift
// Before
observable
    .do(onError: { error in
        logger.error("Request failed: \(error)")
    })
    .retry(3)

// After — the equivalent hook is RetryPolicy's own attemptFailed event.
let policy = RetryPolicy(
    maxAttempts: 3,
    delay: .exponential(base: .seconds(1)),
    onEvent: { event in
        if case .attemptFailed(let attempt, let error, _) = event {
            logger.error("Attempt \(attempt) failed: \(error)")
        }
    }
)
```

A circuit breaker has its own vocabulary — state changes and rejections rather
than per-attempt failures:

```swift
let breaker = CircuitBreaker(
    failureThreshold: 5,
    onEvent: { event in
        if case .circuitCallRejected(let state) = event {
            logger.error("Request rejected in state: \(state)")
        }
    }
)
```

Once all Rx retry/circuit-breaker usage is migrated, remove the RxSwift dependencies from the affected modules.
