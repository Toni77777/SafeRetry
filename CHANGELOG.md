# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `.spi.yml`, so the Swift Package Index builds and hosts the DocC
  documentation for the `SafeRetry` target.

### Documentation

- Corrected the README's feature matrix, which misstated the libraries it
  compares against. swift-retry does support exponential backoff with full
  jitter, but depends on swift-log. Kitura CircuitBreaker has a per-call timeout
  and a fallback callback, and supports Linux as well as macOS. The table now
  links both libraries and names the versions it was checked against.

## [1.0.0] - 2026-10-29

The first release. Everything below is new; the history of the work that led
up to it is in the git log.

### Added

#### Policies

- **`RetryPolicy`** — a `Sendable` value type that runs an operation up to
  `maxAttempts` times, the first call included, pausing between attempts
  according to a `DelayStrategy` and a `JitterStrategy`. A `shouldRetry`
  predicate receives the error and the 1-based attempt index. Without one,
  every error except `CircuitBreakerError` is retried, so a retry around an
  open breaker gives up at the first rejection instead of waiting out its
  backoff; a predicate you pass replaces that default.
- **`CircuitBreaker`** — an actor implementing closed / open / half-open with a
  rolling failure window: `failureThreshold`, `successThreshold`,
  `halfOpenMaxCalls`, `timeout` and `rollingWindow`, plus an `isFailure`
  predicate for errors that are the caller's problem rather than the
  dependency's. It rejects with `CircuitBreakerError.open(retryAfter:)` or
  `.halfOpenRejected`. `state` reports `.halfOpen` as soon as the open window
  has elapsed, and `reset()` forces the circuit closed.
- **`TimeoutPolicy`** — races the operation against a timer in a task group and
  throws `TimeoutError` once the deadline passes, cancelling the operation.
- **`FallbackPolicy`** — returns a constant value, or the result of a handler
  that may itself throw, when the operation fails.

#### Strategies

- **`DelayStrategy`** — `.immediate`, `.fixed`, `.linear`, `.exponential` (with
  a `multiplier` and a `maxDelay` cap) and `.custom`. Computed delays never go
  negative and never overflow `Duration`.
- **`JitterStrategy`** — `.none`, `.full` and `.equal`.

#### Composition

- **`PolicyChain`** — a fluent builder that nests retry, circuit breaker and
  timeout outermost-first. `retry(_:)` and `timeout(_:)` also accept a
  configured policy, so `onEvent` callbacks work inside a chain.
- **`FallbackChain`** — a chain terminated by `.fallback(_:onEvent:)` or
  `.fallback(onEvent:_:)`. It throws only on cancellation or when the handler
  throws.
- **`PolicyChain.Preset`** — `.default` (3 attempts, exponential backoff from
  1 s), `.aggressive` (10 attempts, from 500 ms) and `.conservative` (2 attempts
  2 s apart, each bounded by a 5 s timeout).

#### Registry

- **`PolicyRegistry`** — an actor that stores chains, circuit breakers and
  retry policies by name. Lookups throw `RegistryError.notFound(name:)` or
  `.typeMismatch(name:expected:found:)`; `unregister(_:)`, `unregisterAll()`
  and `registeredNames` manage the contents. A process-wide instance is
  available as `SafeRetry.registry`.

#### Observability

- **`PolicyEvent`** — nine events covering attempts, retries, circuit state,
  rejections, timeouts and fallbacks, delivered synchronously through each
  policy's `onEvent` callback in the order they occur.
- **`CircuitState`** — `.closed`, `.open(until:)` and `.halfOpen`.
- **`EventStream`** — a single-consumer `AsyncSequence` with synchronous
  `emit(_:)` and `finish()`, so producers inside actors publish without
  suspending. It buffers the newest 1024 events by default.

#### Errors

- `CircuitBreakerError` (with a uniform `retryAfter`), `TimeoutError`,
  `ServerError` (the HTTP 5xx status code) and `RegistryError`. All four are
  `Sendable`, `Equatable` and `LocalizedError`, and the structs have public
  initialisers for use in predicates, mocks and tests.

#### URLSession

- `data(for:retrying:)` retries only transient failures — six `URLError` codes
  and HTTP 5xx, mapped to `ServerError`. `data(for:resilience:)` runs the
  request through any `PolicyChain`. Both return 4xx responses untouched.

#### Namespace

- `SafeRetry.retry(attempts:delay:_:)` and `SafeRetry.withCircuitBreaker(_:_:)`
  for one-off calls.

#### Guarantees

- **Cancellation is never a failure.** `CancellationError` and
  `URLError(.cancelled)` are treated alike: never retried, never counted by a
  breaker, never replaced by a fallback, and they emit no event. Every policy
  checks for cancellation before running the operation.
- **Swift 6 strict concurrency** with no `@unchecked Sendable` or
  `nonisolated(unsafe)` in the library, and **no dependencies**.
- Requires Swift 6.4 (Xcode 27); supports iOS 16, macOS 13, tvOS 16 and
  watchOS 9 or later.

#### Documentation

- A DocC catalogue with Getting Started, Observability and Migrating from
  RxSwift articles, and DocC comments on every public symbol. The test suite
  mirrors the README and DocC examples, so an API change that breaks one fails
  the build.

[Unreleased]: https://github.com/Toni77777/SafeRetry/compare/1.0.0...HEAD
[1.0.0]: https://github.com/Toni77777/SafeRetry/releases/tag/1.0.0
