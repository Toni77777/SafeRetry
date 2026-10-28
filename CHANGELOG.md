# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `CircuitBreaker(isFailure:)` — an optional predicate deciding whether a thrown
  error counts as evidence that the dependency is unhealthy. Without it the
  breaker treated *every* error as a dependency failure, so a validation
  rejection, a decoded `404`, or any business-rule error moved the circuit
  toward `.open`. Rejected errors still propagate to the caller; they just
  aren't recorded. Cancellation is exempt regardless of what the predicate
  returns.
- `CircuitBreakerError.retryAfter` — a uniform `Duration?` so callers can back
  off without switching on the case. `nil` for `.halfOpenRejected`, whose trial
  slot frees when the in-flight probe completes rather than at a deadline.
- `swift-docc-plugin`, appended to the package dependencies only when
  `SAFERETRY_BUILD_DOCS` is set. `swift package generate-documentation` — the
  command the README documented — previously failed with
  `error: Unknown subcommand or plugin name`, because the plugin was never
  declared. Gating it on the environment variable keeps the package
  dependency-free for consumers.
- GitHub Actions CI: debug and release test runs, a warnings-as-errors build, a
  thread-sanitizer run, iOS/tvOS/watchOS builds, and a DocC build that fails on
  any documentation warning.

- Public memberwise initialisers for `ServerError` and `TimeoutError`. Both
  types were `public` but their memberwise initialisers defaulted to
  `internal`, so package consumers could not construct them in their own
  `shouldRetry` predicates, request mocks, or tests.
- `PolicyChain.timeout(_:)` overloads that take a configured `TimeoutPolicy`
  (static and instance). The existing `timeout(_ duration:)` shorthand builds a
  policy with no `onEvent` callback, which left
  `PolicyEvent.timeoutExceeded(duration:)` unobservable from inside a chain.
- `LocalizedError` conformances for `ServerError`, `TimeoutError`,
  `CircuitBreakerError`, and `RegistryError`. Each type already rendered itself
  through `CustomStringConvertible`, but `error.localizedDescription` — the
  spelling that reaches log lines and analytics — fell back to Foundation's
  synthesised placeholder ("The operation couldn't be completed.
  (SafeRetry.ServerError error 1.)"), discarding the status code, timeout
  duration, and registry key. Both spellings now agree.
- `onEvent` parameters on `PolicyChain.fallback(_:onEvent:)` and
  `.fallback(onEvent:_:)`. Previously `FallbackChain` had no way to observe
  `PolicyEvent.fallbackUsed` at all — only the standalone `FallbackPolicy`
  emitted it, so a chain's fallback firing was invisible to any `onEvent`/
  `EventStream` consumer wired into the chain's other policies.

### Changed

- **`RetryPolicy` no longer retries `CircuitBreakerError` by default.** A
  retry wrapped around an open breaker used to make every one of its attempts —
  each rejected instantly, the operation never running — and wait out the whole
  backoff schedule between them: about 3 s for `PolicyChain.Preset.default`,
  about three minutes for `.aggressive`. Without a `shouldRetry`,
  `execute(_:)` — and so the presets, `PolicyChain.retry(…)` with no predicate,
  and `SafeRetry.retry` — now gives up at the first rejection, ending the
  sequence the way a veto does (no `retryExhausted`). A `shouldRetry` you pass
  replaces that default and is consulted for `CircuitBreakerError` too, so
  `shouldRetry: { _, _ in true }` restores the old behaviour.
  `URLSession.data(for:retrying:)` is unaffected: its transient-error allowlist
  never retried `CircuitBreakerError`.
- **Repository renamed to `SafeRetry`.** The package now lives at
  `https://github.com/Toni77777/SafeRetry.git`, so its SwiftPM identity
  matches the library: depend on it with
  `.product(name: "SafeRetry", package: "SafeRetry")`. The previous
  `RetrySwift` repository and its `package: "RetrySwift"` spelling (see the
  install-instructions fix under Documentation) no longer apply.
- `CircuitBreaker`, `TimeoutPolicy`, and `FallbackPolicy` now check for
  cancellation on entry, as `RetryPolicy` always has. A task that was already
  cancelled when it reached one of them — typically a dismissed screen's call
  queued behind an actor hop — used to run the operation anyway: the breaker
  sent the request to the dependency (and in half-open spent the only trial
  slot on it), the timeout spawned both children and then waited out an
  operation that ignored cancellation, and the fallback performed I/O only to
  discard it. All three now throw `CancellationError` without running the
  operation or emitting an event, and a `FallbackChain` inherits the behaviour
  from whichever policy it wraps.
- `EventStream` builds its stream with `AsyncStream.makeStream(of:bufferingPolicy:)`
  instead of capturing the continuation into an implicitly unwrapped optional.
- `URLSession+SafeRetry.swift` imports `FoundationNetworking` where it exists,
  matching `Cancellation.swift`; on Linux `URLSession` lives there, so the file
  could not have compiled without it.

- `EventStream` is now a `final class` whose `deinit` finishes the stream, so
  dropping the last reference terminates any consumer. As a `struct` it had no
  `deinit`, and a `for await` loop over a stream dropped without an explicit
  `finish()` stayed suspended for the lifetime of the process — a footgun the
  type's own documentation had to warn about at length. `finish()` is unchanged
  and still available for ending a stream while holding a reference.
- Removed `.enableUpcomingFeature("StrictConcurrency")` from both targets.
  `.swiftLanguageMode(.v6)` already implies complete strict-concurrency
  checking, so the flag was a no-op that read as uncertainty about which
  setting was doing the work.
- `URLSession.isRetryable(_:)` is `internal` rather than `private`, so the
  transient-error allowlist the documentation promises is asserted directly in
  tests.

### Removed

- `SafeRetry.version`. The constant was hardcoded to `"1.0.0"` with a
  `- Warning:` in its own documentation saying not to rely on it, since no tag
  backed it. A version constant that cannot be trusted is worse than none.

- **Repo layout.** `Package.swift`, `Sources/`, and `Tests/` moved from the
  `Retry/` subdirectory to the repository root, so Swift Package Manager now
  resolves the package directly from the repository URL. The duplicate
  `Retry/README.md`, `Retry/CHANGELOG.md`, and `Retry/LICENSE` were merged into
  their top-level counterparts.
- `PolicyChain.Preset.conservative` now applies its 5 s timeout to each retry
  attempt individually instead of to the whole retry sequence, so the second
  attempt is no longer starved of time by the first attempt and the delay
  between them.
- Broadened the set of `URLError` codes treated as transient by the
  `URLSession` resilience extensions to include `.notConnectedToInternet`,
  `.dnsLookupFailed`, and `.cannotFindHost`, in addition to the existing
  `.networkConnectionLost`, `.timedOut`, and `.cannotConnectToHost`.
  `.cannotFindHost` and `.dnsLookupFailed` are both DNS resolution failures,
  so retrying one but not the other was inconsistent.
- Constrained `PolicyRegistry.resolve<T>` to `T: Sendable`.
- `PolicyChain.fallback(_:handler:)`'s handler may now `throw` a different
  error instead of only returning a value, matching `FallbackPolicy`'s
  handler. A non-throwing closure literal still satisfies the new signature,
  so existing call sites are unaffected.
- `CircuitBreaker`'s four state-mutating paths (`executeClosed` opening the
  circuit, `execute` moving open→half-open, and `executeHalfOpen` closing or
  re-opening it) now go through a single private `transition(to:)` that
  resets the counters owned by the entered state and emits
  `circuitStateChanged` in one place, instead of each call site repeating its
  own `currentState = …; emitEvent(...)` and hand-picked counter resets.

### Fixed

- **`DelayStrategy` trapped on negative inputs that it documents as clamping
  to zero.** The overflow guards added for huge attempt counts only protected
  the `maxDelay` end. `.exponential` with a negative `base` (attempt 70 of
  `base: .seconds(-1)`) or a negative `multiplier` (`-1e308`, attempt 2) built a
  `Duration` from a `Double` far outside its range and crashed with
  *"Overflow in multiplication"* / *"Double value cannot be converted to
  _Int128"*; `.linear` with a negative `increment` could overflow the same way
  towards Duration's minimum. Non-positive results now short-circuit to
  `.zero` before conversion. A side effect: `.exponential(base: .zero, …)` with
  a power large enough to reach infinity computed `0 × ∞ = NaN`, which the cap
  read as "too large" and answered with the full `maxDelay`; it now yields
  `.zero`.
- The `TimeoutPolicy` test *"cancellation surfaces even when the timer loses its
  own race"* failed on every run under Xcode 27. It gave the timer child a
  single `Task.yield()` to finish before releasing the operation, which is no
  head start on a multi-threaded executor — the operation won the race and the
  policy correctly returned its value. The test now waits 50 ms; the timer
  wakes in well under one.
- Removed a needless `@unchecked Sendable` from a test-only gate whose stored
  properties are all `let` locks.

- **`CircuitBreaker` mis-attributed counters across state generations.** The
  breaker releases its actor for the duration of `await operation()`, then
  re-checked `currentState` on the way out. That cannot distinguish "nothing
  changed" from "changed and cycled back", and every transition wipes the
  counters — so a call from a dead generation corrupted the live one. Three
  defects followed, all now covered by `CircuitBreakerGenerationTests`:
  - A stale trial call released a half-open slot owned by a later generation,
    admitting more concurrent probes than `halfOpenMaxCalls` permits (observed:
    three concurrent probes with the limit set to two).
  - A stale trial call's success counted toward a later generation's
    `successThreshold`, closing the circuit after fewer genuine probes than
    configured (observed: closed after one probe with `successThreshold: 2`).
  - A failure from a call that started before a recovery counted against the
    recovered circuit, so a single fresh failure re-opened a healthy breaker
    (observed: re-opened on one failure with `failureThreshold: 2`).

  Fixed with a monotonic generation counter advanced by the single
  `transition(to:)` entry point; a call compares generations rather than states.
- **`URLError(.cancelled)` was treated as a genuine failure.** `URLSession`
  reports a cancelled task that way rather than as `CancellationError`, so
  cancelling in-flight requests fed failures into circuit breakers, burned
  retry attempts, and silently produced fallback values — contradicting the
  README's claim that cancellation is never counted. `RetryPolicy`,
  `CircuitBreaker`, `FallbackPolicy`, and `FallbackChain` now recognise both
  spellings via a shared internal `isCancellation(_:)`.
- **`CircuitBreaker.state` was stale after its open window elapsed.** The
  `open → halfOpen` transition is driven by `execute(_:)`, so a breaker whose
  deadline had long passed still reported `.open` until the next call arrived —
  meaning a status view polling `state` showed a recovered dependency as
  indefinitely rejecting. The getter now reports `.halfOpen` once the deadline
  has passed, without mutating or emitting an event.
- `transition(to:)` now clears all three counters for every target state
  instead of only those the entered state "owns". The narrower version was
  correct only because the paths into `.halfOpen` happened to come from
  `.open`, which had already cleared `failureTimestamps`; a future
  `closed → halfOpen` edge would have carried stale failures across.
- Eleven DocC warnings, invisible until the documentation could actually be
  built: two stale `PolicyChain/fallback(_:)` disambiguation hashes that no
  longer resolved, and nine `` ``Type`` `` symbol links to `AsyncStream`,
  `Sendable`, and `Duration` — types outside this module, so DocC could not
  resolve them. The DocC build now fails on any warning in CI.

- Fixed a crash (`Fatal error: Range requires lowerBound <= upperBound`) in
  `JitterStrategy.apply(to:)` when the incoming delay was negative. `.full` and
  `.equal` built a reversed `Double` range and trapped, taking down the whole
  retry loop on the first failure. A negative delay could arrive from a
  `DelayStrategy.custom` closure, a negative `.fixed` interval, or `.linear`
  with a negative `increment`. Negative delays now clamp to `.zero`.
- `DelayStrategy.linear` no longer round-trips through `Double` seconds —
  it's now computed with exact `Duration` arithmetic, so sub-second
  `initial`/`increment` values (e.g. `.milliseconds(30)`) no longer drift by
  a negligible but observable amount under exact `Duration` equality.
  `.exponential` still converts through `Double` (required by `pow`), but its
  `maxDelay` cap is now compared as a `Duration` instead of also round-tripping.
- Fixed a crash (`Fatal error: Overflow in multiplication`) in both
  `DelayStrategy.linear` and `.exponential` when a pathologically large
  attempt count would produce a computed delay too large to represent as a
  `Duration`, even though it would immediately be clamped to `maxDelay`. Both
  cases now detect that condition and return `maxDelay` before ever
  constructing the oversized `Duration`.
- `CircuitBreaker` no longer counts a failure that arrives after the circuit
  has already tripped. The actor is released for the duration of the operation,
  so a call that entered while closed could fail into an already-open circuit;
  the closed-state path then recorded that failure against a fresh (cleared)
  window and re-opened the breaker, pushing its deadline out by another full
  `timeout`. Under sustained concurrent failure the circuit could stay open far
  longer than configured, and each re-open emitted a
  `PolicyEvent.circuitStateChanged(from: .open, to: .open)` that reported a
  transition which never happened. The closed-state path now re-checks the
  state after the operation returns, matching what the half-open path already
  did.
- `DelayStrategy.delay(forAttempt:)` now clamps its result to `.zero` itself.
  Previously the only clamp lived in `JitterStrategy.apply(to:)`, which
  `RetryPolicy`'s default `jitter: .none` bypasses entirely — a `.linear`
  strategy with a negative `increment` (or a misbehaving `.custom` closure)
  could emit a negative `nextDelay`/`delay` through `PolicyEvent` to every
  `onEvent`/`EventStream` observer, even though the actual sleep was quietly
  skipped by an unrelated `> .zero` guard. The invariant now holds at its
  source regardless of jitter.
- Folding a half-open probe's outcome into `.open` or `.closed` now always
  zeroes `halfOpenInFlight`/`halfOpenSuccesses` for the state being entered
  (via the `transition(to:)` helper above), instead of only doing so on the
  code paths that happened to reach an explicit reset. A concurrent half-open
  probe that failed after a sibling probe already moved the breaker away from
  `.halfOpen` could previously leave `halfOpenInFlight` incremented with no
  path back to zero until the next `.open → .halfOpen` transition reset it.

### Documentation

- The README's requirements now state Swift 6.4 (Xcode 27) as the minimum,
  the only toolchain the test suite and CI actually run on, instead of an
  unverified "Swift 6.0+". The manifest's `swift-tools-version` is still
  6.0, so older Swift 6 compilers can attempt the build; they are untested.
- `PolicyChain.Preset` was described in "retries" while its counts are
  attempts: `.default` is 3 attempts (at most 2 retries), `.aggressive` 10,
  `.conservative` 2. Corrected in DocC, the README, and `CLAUDE.md`.
- The RxSwift migration guide told readers to "map the operator order directly
  — SafeRetry uses the same outermost-first ordering". It does not: each Rx
  operator wraps the ones above it, so `.timeout(10).retry(3)` is a per-attempt
  timeout, while the guide's own translation `.timeout(…).retry(…)` gave all
  attempts a single shared 10 s budget. The guide now says to reverse the
  order, the example is corrected and pinned by `DocumentedUsageTests`, and the
  RxSwift snippets use APIs that exist (`catchAndReturn`, RxSwiftExt's
  `retry(.exponentialDelayed…)`) rather than a nonexistent
  `.delay(.exponentialDelayWithBase…)`.
- The `onEvent` guidance promised in-order delivery and, in the same breath,
  recommended spawning a task per event — which loses that order, since such
  tasks run concurrently. The README, the Observability article, and the
  `RetryPolicy`/`CircuitBreaker` initialisers now say so and point at a
  single-consumer `EventStream` for ordered processing; the article and README
  also agree on `Task { }` rather than one saying `Task.detached`.
- Documented that a policy whose `onEvent` emits into an `EventStream` keeps
  the stream alive, and that reaching the stream through `self` closes a
  reference cycle.
- Documented `CircuitBreaker`'s inclusive `rollingWindow` boundary, now pinned
  by tests on both sides of it.
- Documented `TimeoutPolicy`'s per-call cost (a task group with two children)
  and its cancellation requirement in the README.
- Documented that `PolicyRegistry` names share one namespace across policy
  kinds and that re-registering replaces the previous entry.
- `SafeRetry.retry` documents its `attempts ≥ 1` precondition and cancellation;
  `data(for:retrying:)` names `URLError(.cancelled)` among its cancellation
  errors; the README's component table no longer says `ServerError` is
  "auto-retried" by both `URLSession` entry points.

- Documented that a `TimeoutPolicy` has to sit *inside* a `CircuitBreaker` in a
  chain, and reordered every example that got it backwards. The timeout enforces
  its deadline by cancelling, and the breaker exempts cancellation from failure
  counting, so `.timeout(…).circuitBreaker(b)` hides every timed-out call from
  the breaker — a dependency that only ever hangs never trips it, which is one
  of the main things a breaker exists to catch. `DocumentedUsageTests` now pins
  both orderings.
- Documented that half-open has no deadline. Only `.open` is time-bounded; an
  unbounded probe holds the only trial slot indefinitely, so every later call is
  rejected with `.halfOpenRejected` (whose `retryAfter` is `nil`) until an
  explicit `reset()`.
- The README's "`circuitBreaker` outside `retry`" bullet was an ungrammatical
  fragment and has been rewritten.
- Fixed the README snippet labelled "Immediate retry" that in fact used
  `SafeRetry.retry`'s default `.exponential(base: .seconds(1))`, so a documented
  in-memory cache retry slept ~3 seconds. Both forms are now shown explicitly.
- Corrected the `EventStream` lifetime claim. "Dropping the last reference
  terminates it, so a consumer is never left suspended" does not hold for the
  consumer pattern the docs themselves recommend: `for await event in stream`
  captures the stream in the task's closure, so `deinit` cannot run while the
  loop is suspended. `finish()` is now documented as the thing that ends a
  consumer, with the `deinit` behaviour described as the narrower backstop it is.
- Fixed the Observability article still calling `EventStream` a `Sendable`
  struct; it became a `final class` in this release.
- Documented that cancellation emits no events: a cancelled attempt's
  `attemptStarted` has no matching terminal event, which matters to any observer
  pairing starts with completions.
- Documented that `CircuitBreaker`'s `isFailure` predicate runs synchronously on
  the breaker's actor executor and must not block, the same contract `onEvent`
  already carried.
- Clarified `successThreshold`: a probe ending in cancellation or an
  `isFailure`-rejected error frees its slot without clearing the tally, so the
  successes that close the circuit need not be strictly consecutive — the word
  the parameter doc previously used.
- Fixed the 30-second tour referring to an undeclared `breaker`.
- Corrected the README's cancellation claim. It stated that `CancellationError`
  "always propagates unchanged" and that the circuit breaker never counts
  cancellations — true for `CancellationError`, false for the
  `URLError(.cancelled)` that `URLSession` actually throws. Both spellings are
  now handled and documented.
- Rewrote the stale paragraph in the Observability article claiming that a
  chain's `.fallback` cannot emit `fallbackUsed` and that `FallbackChain` takes
  no callback. Both have been false since `fallback(_:onEvent:)` and
  `.fallback(onEvent:_:)` landed, and the README documented them correctly one
  file over. The article's event table also credited only `FallbackPolicy` as a
  source of `fallbackUsed`, disagreeing with `PolicyEvent`'s own table.
- Rewrote Getting Started's URLSession step. Its heading read "Step 6: SafeRetry
  URLSession" — a find-and-replace artifact — and its body described
  `data(for:resilience:)` as retrying only transient errors while demonstrating
  it with a preset that retries everything, including a `badURL` that can never
  succeed. The step now contrasts the two entry points explicitly and notes
  that 4xx responses, `429` included, are returned rather than retried.
- Fixed the migration guide's circuit-breaker example, whose `catch let error as
  CircuitBreakerError` was non-exhaustive and would not compile as shown. Its
  observability step also mapped an RxSwift *retry* logger onto a
  *circuit-breaker* callback; the equivalent hook is `RetryPolicy`'s
  `attemptFailed` event, with the breaker's own vocabulary shown separately.
- Examples now label `onEvent:` explicitly instead of relying on trailing-closure
  position. Under `@testable` the internal initialisers' `now:`/`sleep:`
  parameters come last, so a trailing closure binds to those instead — and any
  future parameter added after `onEvent` would silently change what the snippet
  means.
- Documented the two URLSession entry points' differing retry semantics, the
  `isFailure` predicate, `retryAfter`, `EventStream`'s new drop-terminates
  behaviour, and the `SAFERETRY_BUILD_DOCS` documentation build.
- Moved the AI-assistant spec from `Sources/Claude.md` to `CLAUDE.md` at the
  repository root, where the convention expects it and where it is no longer
  shipped inside the source tree, and brought its drifted sections back in step
  with the code.
- Untracked `.claude/settings.local.json` (machine-local tool permissions) and
  added it to `.gitignore`. Removed the leftover `Retry/` directory from the
  pre-move layout.

- Corrected the README's description of `PolicyChain.Preset.conservative`,
  which still described the pre-fix wrapping order (timeout around the whole
  retry sequence instead of around each attempt).
- Corrected the README's composition example, which labelled `.fallback`
  as the "innermost" policy. `.fallback` terminates the builder and wraps the
  whole chain; it is not a layer in the wrapping order.
- Fixed the `EventStream` example in the README, which called `finish()`
  immediately after starting the consumer task and so delivered no events.
- Replaced the SPM repo-layout caveat in the README, `GettingStarted`,
  `MigratingFromRxSwift`, and `Sources/CLAUDE.md` with working install
  instructions, now that `Package.swift` is at the repo root. Install docs pin
  `branch: "main"` because no version is tagged yet.
- Documented that the `PolicyChain` shorthand factories build policies without
  an `onEvent` callback. (`PolicyChain.fallback` later gained its own
  `onEvent` parameter — see Added, above — so this no longer applies to it.)
- Replaced `PolicyEvent`'s stale type-level doc comment, which claimed only
  `CircuitBreaker` emits events, with the full case-to-policy table.
- `CircuitState.halfOpen` no longer documents "a single trial request"; the
  limit is the breaker's configurable `halfOpenMaxCalls`.
- Corrected the install instructions in the README and `GettingStarted`. Both
  told readers to add a bare `"SafeRetry"` string to their target's
  dependencies, which does not resolve: since Swift 5.2 a bare string only
  matches targets within the same package, and the product lives in a package
  whose identity is `RetrySwift`. Both now use
  `.product(name: "SafeRetry", package: "RetrySwift")`, verified against a
  real consumer package.
- Corrected the `PolicyChain.timeout(_ policy:)` doc comments, which told
  readers to use `timeout(_ policy:)` instead of the duration shorthand — a
  self-reference pointing at the overload being read. They now name
  `timeout(_ duration:)`.
- Documented that `TimeoutPolicy` enforces its deadline by *cancelling* the
  operation, and that because the operation runs as a child task, `execute(_:)`
  cannot return until that child finishes. An operation that never checks for
  cancellation delays `TimeoutError` past the deadline.
- Documented that `EventStream` requires an explicit `finish()`: it is a struct
  wrapping an `AsyncStream.Continuation` with no `deinit`, so a `for await`
  loop over a stream that is simply dropped stays suspended forever.
- Documented that `ServerError` carries only the status code — the `URLSession`
  extensions discard the response body and headers, including `Retry-After`.
- Documented that `PolicyRegistry.registeredNames` is unordered.
- Documented that `SafeRetry.version` describes the release being prepared
  rather than a published one, since no git tag backs `1.0.0` yet.
- Added the missing DocC `///` comment on the public `description` property
  of `ServerError`, `RegistryError`, `CircuitBreakerError`, `TimeoutError`,
  and `CircuitState` — each conformed to `CustomStringConvertible` without
  documenting the property itself, inconsistent with the project's own
  "every public symbol gets DocC" convention.

### Initial implementation

#### Policies

- **RetryPolicy** — value-type retry runner with configurable `maxAttempts`,
  ``DelayStrategy``, and ``JitterStrategy``. Supports a `shouldRetry` predicate
  for filtering non-transient errors; cancellation stops retries at the next
  checkpoint and never triggers a backoff sleep.
- **CircuitBreaker** — actor implementing a three-state machine
  (closed / open / half-open) with a rolling failure window, configurable
  `failureThreshold`, `successThreshold`, `halfOpenMaxCalls`, `timeout`, and
  `rollingWindow`. Injectable clock for deterministic tests. `CancellationError`
  is propagated without counting as a dependency failure.
- **TimeoutPolicy** — struct using `withThrowingTaskGroup` to race an operation
  against a timer; the loser is cancelled via structured concurrency.
- **FallbackPolicy** — generic struct returning a constant value or handler
  result on failure. Propagates `CancellationError` unchanged.

#### Strategies

- **DelayStrategy** — `.immediate`, `.fixed`, `.linear`, `.exponential`,
  `.custom` backoff algorithms.
- **JitterStrategy** — `.none`, `.full`, `.equal` randomisation strategies.

#### Composition

- **PolicyChain** — fluent builder API composing retry, circuit breaker, and
  timeout policies in user-defined outermost-first wrapping order.
- **FallbackChain** — chain terminated with a fallback; `execute` returns the
  fallback on non-cancellation failures and throws only on `CancellationError`.
- **PolicyChain.Preset** — `.default`, `.aggressive`, `.conservative` ready-made
  chains.

#### Registry

- **PolicyRegistry** — actor-isolated named storage for ``PolicyChain``,
  ``CircuitBreaker``, and ``RetryPolicy`` instances, with typed lookups that
  throw ``RegistryError`` on miss or type mismatch. A process-wide `shared`
  instance is exposed via ``SafeRetry/registry``.

#### Observability

- **PolicyEvent** — nine-case enum covering retry, circuit breaker, timeout, and
  fallback lifecycle events.
- **CircuitState** — enum representing `.closed`, `.open(until:)`, and
  `.halfOpen` with a stable `CustomStringConvertible` description.
- **EventStream** — single-consumer `AsyncSequence` wrapper around `AsyncStream`
  for thread-safe event delivery. Synchronous `emit`/`finish` so producers inside
  actors can publish without suspension. Default buffering policy is
  `.bufferingNewest(1024)`; customisable via `init(bufferingPolicy:)`.

#### Error types

- **CircuitBreakerError** — `.open(retryAfter:)` and `.halfOpenRejected`.
- **TimeoutError** — carries the exceeded `Duration`.
- **ServerError** — carries the HTTP 5xx `statusCode`.
- **RegistryError** — `.notFound(name:)` and
  `.typeMismatch(name:expected:found:)`.

#### Extensions

- **URLSession+SafeRetry** — `data(for:retrying:)` and `data(for:resilience:)`
  methods that map HTTP 5xx responses to ``ServerError`` and pass 4xx through
  untouched.

#### Namespace

- **SafeRetry** — top-level enum with `retry(attempts:delay:_:)` and
  `withCircuitBreaker(_:_:)` convenience methods, plus a `registry` accessor.

#### Documentation

- DocC catalogue with a top-level article, Getting Started guide, Observability
  guide, and RxSwift migration guide.
- README with installation, quick start, policy-by-policy guides, real-world
  recipes, and contributing guidelines.
- Full Swift 6 strict concurrency compliance; zero external dependencies.

[Unreleased]: https://github.com/Toni77777/SafeRetry/commits/main
