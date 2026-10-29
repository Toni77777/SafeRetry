# SafeRetry — project rules

SafeRetry is a zero-dependency Swift 6 library of composable resilience
policies — retry, circuit breaker, timeout, fallback — built on Swift
Concurrency. These are the rules for working on it. They are not API
documentation.

**Sources of truth:**
- the public API: `README.md` and the DocC catalog in
  `Sources/SafeRetry/Documentation.docc`;
- the manifest: `Package.swift`;
- user-visible changes: `CHANGELOG.md`.

Don't copy any of these into this file — copies drift.

## Layout

- `Package.swift` sits at the repository root, and the targets use SwiftPM's
  default paths with no `path:`: `Sources/SafeRetry`, `Tests/SafeRetryTests`.
- `Sources/SafeRetry/` is organised as:
  - `Policies/` — the four policies, delay and jitter strategies, and their
    errors;
  - `Composition/` — `PolicyChain` (type-erased boxes, outermost-first) and
    `FallbackChain`;
  - `Observability/` — `PolicyEvent`, `CircuitState`, `EventStream`;
  - `Registry/` — `PolicyRegistry`;
  - `Errors/` — shared errors and `isCancellation(_:)`;
  - `Extensions/` — the `URLSession` integration.
- Tests come as `<Name>Tests.swift` plus `<Name>AdvancedTests.swift` where
  useful. Cross-cutting suites:
  - `CircuitBreakerGenerationTests` — counters across state epochs;
  - `CancellationSemanticsTests` — both cancellation spellings, `isFailure`,
    and entry cancellation;
  - `RetryPolicyEventTests` — exact event order;
  - `DocumentedUsageTests` — the README and DocC snippets, compiled and run.

## Commands

```bash
swift build
swift test
swift test --sanitize=thread
SAFERETRY_BUILD_DOCS=1 swift package generate-documentation --target SafeRetry
xcodebuild build -scheme SafeRetry -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation
```

- CI (`.github/workflows/ci.yml`) runs all of these, with tvOS and watchOS
  added, on pull requests to `main` only.
- CI fails on any compiler or DocC warning.
- The only verified toolchain is Xcode 27 / Swift 6.4. The README's
  Requirements section says so — update it whenever CI's Xcode changes.
- `swift-tools-version` stays at 6.0.

## Concurrency

- **Actors and value types.** Mutable shared state goes in an actor
  (`CircuitBreaker`, `PolicyRegistry`). Stateless policies are `Sendable`
  structs; don't make them actors, because that serialises callers for nothing.
- **Sendable everywhere.** User-supplied closures are `@Sendable`, and
  `PolicyEvent`, `CircuitState` and the strategies are `Sendable`.
- **No escape hatches in `Sources/`:** no `@unchecked Sendable` and no
  `nonisolated(unsafe)`. The one test exception is `MockURLProtocol`: its
  superclass isn't `Sendable`, and its static handler is safe only because the
  suite is `.serialized`.
- **Swift Concurrency only.** No GCD, `OperationQueue` or locks in `Sources/`.
  Tests may use `OSAllocatedUnfairLock` for shared counters.
- **Cancellation:**
  - Every policy's `execute` starts with `try Task.checkCancellation()`.
  - Cancellation means `CancellationError` *or* `URLError(.cancelled)`; always
    classify with `isCancellation(_:)`.
  - Cancellation is never a failure: it is never retried, never counted by the
    breaker, never replaced by a fallback, and it emits no event.
- **`CircuitBreaker`:**
  - The actor is released during `await operation()`, so every write after
    that `await` must first check that `generation` is unchanged.
  - State changes go only through `transition(to:)`, the single place that
    resets counters and advances `generation`.
- **Callbacks.** `onEvent` and `isFailure` run synchronously, on the breaker's
  executor for the breaker, so they must never block.
- **`NonisolatedNonsendingByDefault` is not enabled.** Under it, a plain
  `@Sendable () async throws -> T` operation would run on the *caller's* actor,
  serialising every breaker call. Adopting the feature means marking operation
  parameters `@concurrent`, which requires a Swift 6.2 minimum.

## Code style

- **File header:** `// FileName.swift` then
  `// SafeRetry — A composable resilience library for Swift.`, followed by
  `// MARK: -` sections, the type name first.
- **DocC:** every public symbol gets a `///` comment with `- Parameters:`,
  `- Returns:` and `- Throws:` where they apply.
- **Errors:** untyped `throws` (`any Error`). See issue #2 before introducing
  typed throws.
- **Time-dependent types** have a public init plus an internal one taking an
  injectable clock or sleep: `CircuitBreaker`'s `now:` and `RetryPolicy`'s
  `sleep:`. `TimeoutPolicy` does not have one yet (issue #3); give any new
  time-dependent type one from the start.

## Tests

- **Framework.** Swift Testing only (`@Suite`, `@Test`), no XCTest.
- **No real waiting** beyond a few tens of milliseconds — inject `now:` /
  `sleep:`. The known exceptions are the `TimeoutPolicy` tests (#3) and the
  preset tests (#4).
- **Ordering between tasks.** Never rely on `Task.yield()` for it; it gives no
  head start on a multi-threaded executor. Park work on a continuation gate
  instead (see `Gate` / `UncancellableGate` in the tests).
- **What to cover:**
  - cancellation, both mid-flight and on entry;
  - concurrent callers on the actors;
  - every breaker transition, including concurrent half-open probes.
- **Event order.** `RetryPolicyEventTests` asserts exact event sequences;
  extend it whenever events change.
- **Regression tests.** A bug fix ships with a test that fails without the fix
  — run it against the old code to confirm.
- **Label `onEvent:` explicitly** in tests and examples. Under `@testable`, the
  internal initialisers' `now:` / `sleep:` parameters come last, so a trailing
  closure binds to those instead.

## Documentation

- **Public API changes** update the README, the DocC articles,
  `DocumentedUsageTests` and `CHANGELOG.md` (`## [Unreleased]`, Keep a
  Changelog format) in the same change.
- **Wording:** say "attempts" — they include the first call — not "retries".
- **Breaker plus timeout:** in examples the timeout always sits *inside* the
  breaker, `.circuitBreaker(b).timeout(…)`. The reverse order hides hung calls
  from the breaker, so show it only as the anti-pattern.
- **Install snippets** in the README, GettingStarted and MigratingFromRxSwift
  must agree. They use `from:` with the latest minor release (`from: "1.0.0"`);
  the release commit of a new minor or major version bumps all three.
- **Unfixed review findings** go to GitHub Issues, not into files committed
  to the repository.
