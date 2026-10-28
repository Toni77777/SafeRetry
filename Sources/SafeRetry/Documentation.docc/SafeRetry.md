# ``SafeRetry``

A composable resilience library for Swift Concurrency.

## Overview

SafeRetry provides production-ready retry, circuit breaker, timeout, and fallback policies for async/await Swift code. Every type is built on structured concurrency, fully `Sendable`, and compiles under Swift 6 strict concurrency checking. Compose policies into chains with a fluent builder API, observe circuit breaker transitions, and integrate with `URLSession` in a single line.

## Getting Started

Add SafeRetry to your project with Swift Package Manager, then wrap any failable call in a retry policy:

```swift
import SafeRetry

let user = try await SafeRetry.retry(attempts: 3) {
    try await api.fetchUser(id: 42)
}
```

For a step-by-step walkthrough, see <doc:GettingStarted>.

## Topics

### Policies

- ``RetryPolicy``
- ``CircuitBreaker``
- ``TimeoutPolicy``
- ``FallbackPolicy``

### Composition

- ``PolicyChain``
- ``FallbackChain``

### Registry

- ``PolicyRegistry``
- ``RegistryError``

### Observability Types

<!-- Deliberately not "### Observability": that anchor collides with the
     <doc:Observability> article at the same path, and DocC reports
     "'Observability' is ambiguous at '/SafeRetry'" for every link to it. -->

- ``PolicyEvent``
- ``CircuitState``
- ``EventStream``

### Error Types

- ``CircuitBreakerError``
- ``TimeoutError``
- ``ServerError``

### Strategies

- ``DelayStrategy``
- ``JitterStrategy``

### Namespace

- ``SafeRetry``

### Articles

- <doc:GettingStarted>
- <doc:Observability>
- <doc:MigratingFromRxSwift>
