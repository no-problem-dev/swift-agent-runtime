# Changelog

## [Unreleased]

## [0.20.1] - 2026-08-11

### Changed

- Builds and tests on Linux, verified against `swift:6.2` in Docker. No source change was needed:
  nothing here is Apple-only, and the manifest's existing version ranges already resolve to
  swift-structured-data 3.0.1, which carries that package's Linux fix. A working copy still holding
  a `Package.resolved` from before that release fails on `CFGetTypeID` until it resolves again —
  the file is not tracked here, so a fresh checkout never sees it.

### Fixed

- The two cancellation tests read their worker's flag on a timer rather than on the event. One
  waited a fixed 100 ms for the worker to reach its hang point; both then checked "cancellation
  reached the worker" the instant the host's run threw, though the worker runs on its own task and
  marks the flag slightly later. Both now poll for the state they are waiting on. They failed only
  under load — the first on Linux, the second on macOS — which is the shape of a flake, not of a
  platform difference.

## [0.20.0] - 2026-08-11

### Changed

- Raised the swift-llm-client pin to 5.0.0. 0.19.0 shipped with it still at 4.x, which made this
  package unresolvable alongside anything on llm-client 5 — swift-research-agent hit it first.


## [0.19.0] - 2026-08-11

### Fixed

- **Overlapping `run` calls made the first uncancellable**, so `cancel()` silently cancelled
  nothing. An overlapping run is refused now, and ending a turn only clears the turn it owns, so a
  stale `defer` cannot orphan a live one.
- **A network failure reading a task was indistinguishable from a task not yet persisted** — the
  caller got stale data presented as current. Reads now carry their freshness, and `check_task`
  surfaces staleness to the model instead of answering "still submitted, check again later".
- **Failed conversation writes were invisible**, so `session/load` silently started fresh and the
  user's history appeared to vanish. Loading also tells "no file yet" from "exists but
  undecodable".
- Tool calls were spawned one task each with no concurrency cap. `delegatedTasks` and
  `HostAgentExecutor.hosts` were never pruned — the first also leaked its monitor tasks, and the
  second held prompt caches for hosts nobody was using.


## [0.18.1] - 2026-08-11

### Fixed

- The test suite compiles again. 0.18.0 was tagged with test mocks still declaring
  swift-llm-client's pre-4.0.0 `generateWithUsage` signature; the library targets had been
  migrated and the mocks had not, so `swift build --build-tests` failed with 47 errors on a fresh
  clone. It was not caught because a stale `.build` directory predating the pin bump made
  `swift test` report a pass.


## [0.18.0] - 2026-08-11

### Changed

- Raised the swift-llm-client pin to 4.0.0 and the swift-structured-data pin to 3.0.0. Neither
  changes this package's own API: llm-client 4.0.0 alters protocol *requirement* signatures, which
  affects types that conform to them, not code that calls them.


## [0.17.0] - 2026-08-06

See [GitHub Releases](../../releases) for changes up to and including this version.
