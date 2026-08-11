# Changelog

## [Unreleased]

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
