# Changelog

## [Unreleased]

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
