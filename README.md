# Animi

Video template engine for iOS.

## Project Structure

- `TVECore/` — Core library (Swift Package)
- `AnimiApp/` — iOS application

## Local checks before push

Run from repository root:

```bash
make ci
```

This runs:

1. `make lint` — SwiftLint
2. `make test` — TVECore unit tests
3. `make build` — AnimiApp build

Or run individually:

```bash
make lint   # SwiftLint
make test   # swift test
make build  # xcodebuild
```

**Expected:**

* `make lint` → 0 violations
* `make test` → all tests passed
* `make build` → BUILD SUCCEEDED
