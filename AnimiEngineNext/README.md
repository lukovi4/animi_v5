# AnimiEngineNext

An **isolated**, next-generation video-engine package built *beside* the current Animi product
(decisions D-101/D-102). Task 001 lays only the foundation: a versioned typed configuration with a
stable SHA-256 hash, a transactional (write-once, no-overwrite, sealed) benchmark-run evidence writer,
and a real-template fixture index
that **hashes but never loads or renders** templates.

This package has **zero product dependencies** — it does not depend on `TVECore` and must not import
`AnimiApp`. No decoder, renderer, proxy, cache, audio, export, or UI code is in scope for Task 001.

## Targets

| Target | Product? | Purpose |
| --- | --- | --- |
| `AnimiEngineNext` | `.library` | Versioned typed configuration: decode (strict), canonical encoding, SHA-256 hash. |
| `AnimiEngineDiagnostics` | `.library` | Transactionally-published, write-once benchmark-run manifests + structured NDJSON events; injected clocks/ID. |
| `AnimiEngineTestSupport` | dev/test-only target (**not** a product) | Real-template fixture index, repository-root abstraction, copied-fixture helper, deterministic clock/ID fakes. |

## Requirements

- Swift tools 5.9
- Platforms: iOS 18, macOS 15 (host-side `swift test`)

## Running the tests

```sh
cd AnimiEngineNext
swift build      # builds the package independently
swift test       # runs the Level-1 unit tests
```

The fixture-index tests locate the five real templates under the repository's `SceneSources/` via an
injected `TemplateRepositoryRoot` (tests resolve the repo root from their own file location).

## Documentation

- `Docs/ADR-001-package-and-dependency-boundaries.md` — package isolation & dependency boundaries.
- `Docs/ADR-014-diagnostics-evidence-and-comparison.md` — versioned config hash + transactional,
  write-once evidence (and the explicit limits of that guarantee).
