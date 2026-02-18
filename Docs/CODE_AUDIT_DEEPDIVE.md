# CODE AUDIT DEEP DIVE — Section-by-section (evidence-based)

Snapshot date: **2026-02-11**
**Last updated:** 2026-02-17 (added S11 Export Pipeline)

## 1. Scope & method

Deep dive performed by subsystems (S1..S10). Evidence sources:
- Source code in snapshot (code anchors).
- Canonical issue register: `Docs/CODE_AUDIT_ISSUES.md`.
- Coverage proofs: `Docs/REVIEW_PROOFS_INDEX.md`, `Docs/SNAPSHOT_FILE_INVENTORY.txt`.
- Scan artifact (keyword scans): `Docs/AUDIT_SCAN_REPORT.md` (used for S7/S8 presence/absence).

## S1) App entry & dependency wiring

### Overview (PROVEN)
- UIKit app: root is `UINavigationController` with `TemplatesHomeViewController` as root VC (Release) or `PlayerViewController` directly (Debug dev mode).

### Proven reachable call graph (Release — Templates Home)

**Code anchor**
- `AnimiApp/Sources/App/SceneDelegate.swift`
- `scene(_:willConnectTo:)` — UINavigationController with TemplatesHomeViewController
```swift
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)

        // Release: Templates Home as root
        let homeVC = TemplatesHomeViewController()
        let navController = UINavigationController(rootViewController: homeVC)
        navController.isNavigationBarHidden = true  // Home has custom header
        window.rootViewController = navController
        window.makeKeyAndVisible()

        self.window = window
    }
```

→ `TemplatesHomeViewController.viewDidLoad()` → (user flow) → `TemplateDetailsViewController` → `PlayerViewController(.editor)`

### Navigation Flow (Release)
1. **Home** (`TemplatesHomeViewController`): Category sliders, "See all" links
2. **See All** (`TemplatesSeeAllViewController`): Grid view of category templates
3. **Details** (`TemplateDetailsViewController`): Full-screen preview, "Use template" CTA
4. **Editor** (`PlayerViewController(.editor)`): Template editing with system Back button

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `viewDidLoad()`
```swift
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupRenderer()
        wireEditorController()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")

        // PR4: Auto-load default template on startup
        // In Release builds, load pre-compiled template automatically
        // In Debug builds, user can select and load via Load Scene button
        #if !DEBUG
        loadCompiledTemplateFromBundle(templateName: "example_4blocks")
        #endif
    }
```


### Ownership & lifecycle map (PROVEN)
- `SceneDelegate` owns `UIWindow`; `UIWindow.rootViewController` is `PlayerViewController`.
- `PlayerViewController` initializes `MetalRenderer` in `setupRenderer()`.

### Findings
- P3-001 (was P1-002) — Earcut force-unwrap after `eliminateHoles` — unreachable in current codebase (no callers pass `holeIndices`).

## S2) Scene/Template loading & compilation pipeline

### Overview (PROVEN)
- Debug: “Load Scene” action loads a JSON scene package from bundle (`TestAssets/ScenePackages/...`).
- Release: app auto-loads a compiled template folder (`Templates/<name>`) using `.tve` file.

### Proven reachable call graph (DEBUG load path)

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `loadTestPackageTapped()`
```swift
        } catch { log("ERROR: MetalRenderer failed: \(error)") }
    }

    // MARK: - Actions

    #if DEBUG
    @objc private func loadTestPackageTapped() {
        stopPlayback()
        renderErrorLogged = false
        log("---\nLoading scene package...")
        let sceneNames = ["example_4blocks", "alpha_matte_test", "variant_switch_demo", "polaroid_shared_demo"]
        let idx = sceneSelector.selectedSegmentIndex
        let sceneName = idx < sceneNames.count ? sceneNames[idx] : sceneNames[0]
        let subdir = "TestAssets/ScenePackages/\(sceneName)"
        guard let url = Bundle.main.url(forResource: "scene", withExtension: "json", subdirectory: subdir) else {
            log("ERROR: Test package '\(sceneName)' not found"); return
        }
        do {
            try loadAndValidatePackage(from: url.deletingLastPathComponent())
        } catch {
            log("ERROR: \(error)")
            isSceneValid = false
            isAnimValid = false
        }
    }
    #endif
```


**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `loadAndValidatePackage(from:)`
```swift

        view.layoutIfNeeded()
    }

    // MARK: - Package Loading (DEBUG only)

    #if DEBUG
    private func loadAndValidatePackage(from rootURL: URL) throws {
        let package = try loader.load(from: rootURL)
        currentPackage = package
        logPackageInfo(package)

        // PR-28: Create resolver early — needed for both validation and texture loading.
        let localIndex = try LocalAssetsIndex(imagesRootURL: package.imagesRootURL)
        let sharedIndex = try SharedAssetsIndex(bundle: Bundle.main, rootFolderName: "SharedAssets")
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)
        currentResolver = resolver

        let sceneReport = sceneValidator.validate(scene: package.scene)
        logValidationReport(sceneReport, title: "SceneValidation")
        isSceneValid = !sceneReport.hasErrors
        guard isSceneValid else { log("Scene invalid"); metalView.setNeedsDisplay(); return }
        try loadAndValidateAnimations(for: package, resolver: resolver)
        try compileScene(for: package)
        metalView.setNeedsDisplay()
    }
```


**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `compileScene(for:)`
```swift
    private func compileScene(for package: ScenePackage) throws {
        guard isAnimValid,
              let loaded = loadedAnimations,
              let device = metalView.device else { return }

        log("---\nCompiling scene...")

        // PR3: Use SceneCompiler from TVECompilerCore (compile logic moved out of ScenePlayer)
        let sceneCompiler = SceneCompiler()
        let compiled = try sceneCompiler.compile(package: package, loadedAnimations: loaded)
        compiledScene = compiled

        // Create ScenePlayer and load the compiled scene
        let player = ScenePlayer()
        player.loadCompiledScene(compiled)

        // PR-19: Store player as property and wire to editor controller
        scenePlayer = player
        editorController.setPlayer(player)
```


### Proven reachable call graph (Release compiled template load path)

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `viewDidLoad() — Release autoload`
```swift
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupRenderer()
        wireEditorController()
        let deviceName = metalView.device?.name ?? "N/A"
        log("AnimiApp initialized, TVECore: \(TVECore.version), Metal: \(deviceName)")

        // PR4: Auto-load default template on startup
        // In Release builds, load pre-compiled template automatically
        // In Debug builds, user can select and load via Load Scene button
        #if !DEBUG
        loadCompiledTemplateFromBundle(templateName: "example_4blocks")
        #endif
    }
```


**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `loadCompiledTemplateFromBundle(templateName:)`
```swift
    private func loadCompiledTemplateFromBundle(templateName: String) {
        stopPlayback()
        renderErrorLogged = false
        log("---\nLoading compiled template '\(templateName)'...")

        guard let device = metalView.device else {
            log("ERROR: No Metal device")
            loadingState = .failed(message: "No Metal device")
            updateLoadingStateUI()
            return
        }

        // Find template folder in bundle
        guard let templateURL = Bundle.main.url(forResource: templateName, withExtension: nil, subdirectory: "Templates") else {
            log("ERROR: Template '\(templateName)' not found in bundle")
            loadingState = .failed(message: "Template not found")
            updateLoadingStateUI()
            return
        }

        // PR-D: Cancel previous loading task if any
        preparingTask?.cancel()

        // PR-D: Generate new request ID for cancellation check
        let requestId = UUID()
        currentRequestId = requestId
        loadingState = .preparing(requestId: requestId)
        updateLoadingStateUI()

        // PR-D: Async loading pipeline
        preparingTask = Task { [weak self] in
            guard let self = self else { return }

            // === PHASE 1: Background ===
            // File IO + JSON decode + asset index creation
            // PR-D.1: Use child Task (not detached) so cancellation propagates
            do {
                let result: BackgroundLoadResult = try await Task(priority: .userInitiated) {
                    // Check cancellation before starting
                    try Task.checkCancellation()

                    // Load .tve file (IO)
```


**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `background phase — CompiledScenePackageLoader.load(from:)`
```swift
                    try Task.checkCancellation()

                    // Load .tve file (IO)
                    let compiledLoader = CompiledScenePackageLoader(engineVersion: TVECore.version)
                    let compiledPackage = try compiledLoader.load(from: templateURL)

                    // Check cancellation after file load
                    try Task.checkCancellation()

                    // Create asset indices (may scan directories)
                    let localIndex = try LocalAssetsIndex(imagesRootURL: templateURL.appendingPathComponent("images"))
                    let sharedIndex = try SharedAssetsIndex(bundle: Bundle.main, rootFolderName: "SharedAssets")
                    let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

                    return BackgroundLoadResult(
                        compiledPackage: compiledPackage,
                        resolver: resolver
                    )
                }.value
```


**Code anchor**
- `TVECore/Sources/TVECore/ScenePackage/CompiledScenePackageLoader.swift`
- `load(from:) — Data(contentsOf:)`
```swift
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CompiledPackageError.fileNotFound(fileURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CompiledPackageError.ioReadFailed(fileURL)
        }

        // Header minimal validation
        guard data.count >= Int(CompiledPackageConstants.headerSizeV1) else {
            throw CompiledPackageError.payloadLengthMismatch
        }
```


### Ownership & lifecycle map (PROVEN)
- `PlayerViewController` owns `ScenePackage`/`CompiledScenePackage` state (`compiledScene`, `scenePlayer`, `textureProvider`).
- `SceneCompiler` is created locally in `compileScene(for:)` and not stored.

### Findings
- P2-001 (was P1-001) — Synchronous texture preload on UI action path (DEBUG-only; Release path uses background Task with draw gate).
- P2-001 — Compiled template loader reads entire `.tve` into memory.

## S3) Rendering pipeline (Metal) + command building

### Overview (PROVEN)
- `PlayerViewController` creates `MetalRenderer` and drives `MTKViewDelegate.draw(in:)`.

### Proven reachable call graph

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `setupRenderer()`
```swift

    private func setupRenderer() {
        guard let device = metalView.device else { log("ERROR: No Metal device"); return }
        do {
            let clearCol = ClearColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1.0)
            renderer = try MetalRenderer(
                device: device,
                colorPixelFormat: metalView.colorPixelFormat,
                options: MetalRendererOptions(
                    clearColor: clearCol,
                    enableDiagnostics: true,
                    maxFramesInFlight: Self.maxFramesInFlight  // Must match inFlightSemaphore
                )
            )
            log("MetalRenderer initialized (maxFramesInFlight=\(Self.maxFramesInFlight))")
        } catch { log("ERROR: MetalRenderer failed: \(error)") }
    }
```


**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `draw(in:) — main-thread + loading gate`
```swift
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        // Model A contract: draw must execute on main thread
        dispatchPrecondition(condition: .onQueue(.main))

        // PR-D.1: No draw while template is loading (prevents race with background preload)
        guard loadingState == .ready else { return }

        // PR1.5: Split timing - start
        #if DEBUG
        let tSemStart = CACurrentMediaTime()
        #endif
```


### Ownership & lifecycle map (PROVEN)
- `MetalRenderer` owns GPU-side caches/pools (`TexturePool`, caches).

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer.swift`
- `MetalRenderer properties — texturePool`
```swift
public final class MetalRenderer {
    // MARK: - Properties

    let device: MTLDevice
    let resources: MetalRendererResources
    let options: MetalRendererOptions
    let texturePool: TexturePool
    let maskCache: MaskCache
    let shapeCache: ShapeCache
    private let logger: TVELogger?

    // PR-C3: GPU buffer caching for mask rendering
    let vertexUploadPool: VertexUploadPool
    let pathIndexBufferCache: PathIndexBufferCache
```


### Findings
- P2-003 — TexturePool has no bounds/eviction for unique size keys.

## S4) Media / Video pipeline (AVFoundation, frame providers)

### Overview (PROVEN)
- `UserMediaService` is `@MainActor` and manages per-block `VideoFrameProvider` instances + temp URLs.

### Proven reachable call graph

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `compileScene(for:) — UserMediaService init`
```swift
        }

        // PR-32: Create UserMediaService for photo/video injection
        if let tp = textureProvider {
            userMediaService = UserMediaService(
                device: device,
                scenePlayer: player,
                textureProvider: tp
            )
            userMediaService?.setSceneFPS(Double(compiled.runtime.fps))
            // PR1.1: Wire callback for async updates (poster ready, clear)
            userMediaService?.onNeedsDisplay = { [weak self] in
                self?.metalView.setNeedsDisplay()
            }
            log("UserMediaService initialized")
```


**Code anchor**
- `AnimiApp/Sources/UserMedia/UserMediaService.swift`
- `cleanupVideoResources(for:)`
```swift
        // PR-async-race: Invalidate pending async operations for this blockId
        videoSetupGenerationByBlock[blockId, default: 0] += 1
        videoSetupTasksByBlock[blockId]?.cancel()
        videoSetupTasksByBlock.removeValue(forKey: blockId)

        // Release video provider
        if let provider = videoProviders.removeValue(forKey: blockId) {
            provider.release()
        }

        // Delete temp file
        if let tempURL = tempVideoURLByBlockId.removeValue(forKey: blockId) {
            do {
                try FileManager.default.removeItem(at: tempURL)
                #if DEBUG
                print("[UserMediaService] Deleted temp file: \(tempURL.lastPathComponent)")
                #endif
```


**Code anchor**
- `AnimiApp/Sources/UserMedia/VideoFrameProvider.swift`
- `release() + deinit`
```swift
    public func release() {
        // PR-async-race: Invalidate all pending async operations
        generation += 1
        durationTask?.cancel()
        durationTask = nil

        stopPlayback()
        playerItem.remove(videoOutput)
        player.replaceCurrentItem(with: nil)
        lastTexture = nil
        textureFactory.flushCache()
        state = .idle
    }

    deinit {
        release()
    }
}
```


### Ownership & lifecycle map (PROVEN)
- `PlayerViewController` holds `userMediaService` property.
- `UserMediaService` holds `videoProviders[blockId]` and `tempVideoURLByBlockId[blockId]` and cleans them in `cleanupVideoResources(for:)` and `deinit`.

### Findings
- P2-002 — VideoFrameProvider cleanup is non-idempotent (release called explicitly and in deinit).
- P2-004 — Temp file cleanup in UserMediaService.deinit swallows errors (try?).

## S5) Resource lifecycle & caches (textures/pools/file cache)

### Overview (PROVEN)
- GPU texture reuse is implemented via `TexturePool` stored in `MetalRenderer`.
- Template textures are loaded into `ScenePackageTextureProvider` cache via `preloadAll()`.

### Proven reachable call graph

**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/ScenePackageTextureProvider.swift`
- `preloadAll()`
```swift
    /// Binding assets (identified by `bindingAssetIds`) are expected to have no file on disk
    /// and are skipped with a debug log. All other non-resolvable assets are logged as errors
    /// and added to `missingAssets` — this indicates a corrupted template.
    ///
    /// Statistics are stored in `lastPreloadStats` after completion.
    public func preloadAll() {
        let startTime = CFAbsoluteTimeGetCurrent()
        var loadedCount = 0
        var skippedBindingCount = 0

        for (assetId, basename) in assetIndex.basenameById {
            // Skip already cached (including injected textures)
            if cache[assetId] != nil {
                loadedCount += 1 // Count as loaded (was pre-injected)
                continue
            }

            guard let textureURL = try? resolver.resolveURL(forKey: basename) else {
                if bindingAssetIds.contains(assetId) {
                    // Expected: binding asset has no file (user media injected at runtime)
                    logger?("[TextureProvider] Preload skipped binding asset '\(assetId)'")
                    skippedBindingCount += 1
                } else {
                    // Unexpected: non-binding asset missing — template corrupted
                    logger?("[TextureProvider] ERROR: Asset '\(assetId)' (basename='\(basename)') not resolvable — template may be corrupted")
                    missingAssets.insert(assetId)
                }
                continue
            }

            if let texture = loadTexture(from: textureURL, assetId: assetId) {
                cache[assetId] = texture
                loadedCount += 1
            }
            // Note: loadTexture already adds to missingAssets on failure
        }
```


**Code anchor**
- `TVECore/Sources/TVECore/MetalRenderer/TexturePool.swift`
- `TexturePool storage`
```swift
/// Manages reusable Metal textures to avoid per-frame allocations.
/// Textures are pooled by (width, height, pixelFormat) key.
final class TexturePool {
    private let device: MTLDevice
    private var available: [TexturePoolKey: [MTLTexture]] = [:]
    private var inUse: Set<ObjectIdentifier> = []

    init(device: MTLDevice) {
        self.device = device
    }

    /// Acquires a color texture (BGRA8Unorm) for offscreen rendering.
    /// - Parameter size: Texture dimensions in pixels
```


### Findings
- P2-003 — TexturePool no eviction/bounds.

## S6) Concurrency model & thread-safety contracts

### Overview (PROVEN)
- Rendering draw path asserts main queue (`dispatchPrecondition`).
- Some background work is performed via `Task { ... }` in compiled template load pipeline.

### Proven reachable call graph

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `loadCompiledTemplateFromBundle(templateName:) — Task background phase`
```swift
    private func loadCompiledTemplateFromBundle(templateName: String) {
        stopPlayback()
        renderErrorLogged = false
        log("---\nLoading compiled template '\(templateName)'...")

        guard let device = metalView.device else {
            log("ERROR: No Metal device")
            loadingState = .failed(message: "No Metal device")
            updateLoadingStateUI()
            return
        }

        // Find template folder in bundle
        guard let templateURL = Bundle.main.url(forResource: templateName, withExtension: nil, subdirectory: "Templates") else {
            log("ERROR: Template '\(templateName)' not found in bundle")
            loadingState = .failed(message: "Template not found")
            updateLoadingStateUI()
            return
        }

        // PR-D: Cancel previous loading task if any
        preparingTask?.cancel()

        // PR-D: Generate new request ID for cancellation check
        let requestId = UUID()
        currentRequestId = requestId
        loadingState = .preparing(requestId: requestId)
        updateLoadingStateUI()

        // PR-D: Async loading pipeline
        preparingTask = Task { [weak self] in
            guard let self = self else { return }

            // === PHASE 1: Background ===
            // File IO + JSON decode + asset index creation
            // PR-D.1: Use child Task (not detached) so cancellation propagates
            do {
                let result: BackgroundLoadResult = try await Task(priority: .userInitiated) {
                    // Check cancellation before starting
                    try Task.checkCancellation()

                    // Load .tve file (IO)
```


### Findings
- No additional concurrency issues raised to P1/P2 beyond those already captured (see issues).

## S7) Persistence / storage

### Overview
- **NOT PRESENT IN SNAPSHOT (as a distinct subsystem)** — no DB schema / CoreData model / persistence module discovered by recorded scan artifact.


**Code anchor**
- `Docs/AUDIT_SCAN_REPORT.md`
- `Keyword scan excerpt (persistence/storage)`
```
## Keyword scans (presence/absence evidence)

### Persistence / storage — code scope (AnimiApp/Sources, TVECore/Sources, TVECore/Tests, Scripts)
Keywords: CoreData, NSPersistentContainer, NSManagedObject, SQLite, FMDB, Realm, GRDB, UserDefaults, Keychain, SecItem, SecureEnclave, NSUbiquitousKeyValueStore, .xcdatamodeld
Matches:
- Total matches: 0
- Matched files: (none)
```


### Findings
- No persistence-specific issues recorded.

## S8) Networking / analytics / remote config

### Overview
- **NOT PRESENT IN SNAPSHOT (as a distinct subsystem)** — absence claim is based on recorded scan artifact (no grep-only claims).


**Code anchor**
- `Docs/AUDIT_SCAN_REPORT.md`
- `Keyword scan excerpt (networking/analytics)`
```
### Networking / analytics / remote config — code scope (AnimiApp/Sources, TVECore/Sources, TVECore/Tests, Scripts)
Keywords: URLSession, NSURLSession, Alamofire, Moya, GraphQL, Apollo, FirebaseRemoteConfig, RemoteConfig, FirebaseAnalytics, Crashlytics, Sentry, Mixpanel, Amplitude, AppsFlyer, Analytics.logEvent, Appsflyer, AFSDK, FirebaseApp, FIRApp
Matches:
- Total matches: 0
- Matched files: (none)
```


### Findings
- No networking/analytics issues recorded.

## S9) Tooling & release safety (scripts, build integration)

### Overview (PROVEN)
- Snapshot contains build/release scripts under `Scripts/` and `.swiftlint.yml` at repo root.

### Evidence

**Code anchor**
- `.swiftlint.yml`
- `Root lint config`
```
# SwiftLint Configuration for Animi Project

# Paths to include
included:
  - AnimiApp/Sources
  - TVECore/Sources

# Paths to exclude
excluded:
  - .build
  - "**/.build"
  - "**/DerivedData"
```


**Code anchor**
- `Scripts/verify_release_bundle.sh`
- `Script header`
```
#!/bin/bash
# verify_release_bundle.sh — Verifies Release bundle has no anim-*.json and has compiled.tve
#
# Usage:
#   ./Scripts/verify_release_bundle.sh <app_bundle_path>
#   ./Scripts/verify_release_bundle.sh /path/to/AnimiApp.app
#
# Exit codes:
#   0 - Bundle is valid (no anim-*.json, has compiled.tve for all templates)
#   1 - Bundle validation failed

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
```


### Findings
- No script integration issues are asserted as PROVEN beyond what is already in baseline (build phase wiring is outside snapshot evidence unless in `project.pbxproj`).

## S10) Tests

### Overview (PROVEN)
- Snapshot includes `TVECoreTests` and test assets.

### Evidence

**Code anchor**
- `TVECore/Tests/TVECoreTests/CompiledTemplateTests.swift`
- `Imports`
```swift
import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// PR4 Smoke Tests: Verifies compiled template (.tve) loading and playback
final class CompiledTemplateTests: XCTestCase {

    // MARK: - Test Resources

    private var compiledTemplateURL: URL? {
        // Look for compiled.tve in test resources
        Bundle.module.url(
            forResource: "compiled",
            withExtension: "tve",
            subdirectory: "Resources/example_4blocks"
```


### Findings
- No new test gaps are asserted as PROVEN beyond presence/structure (coverage metrics are NOT PROVEN from snapshot).

## 2. Cross-cutting risks (PROVEN)

- **Main-thread heavy work:** synchronous preload path (P2 — Debug-only, Release uses background Task).
- **Resource/caching growth:** TexturePool growth risk (P2-003), temp file deletion error swallowing (P2-004).

## 3. Final verdict (based on issue register)

- Verdict: **YES — NO P1 RISKS REMAINING**
- P0 blockers (HIGH confidence): **0**
- P1 must-fix: **0** (all former P1 issues resolved or downgraded)
- P2 downgraded: **P1-001 → P2** (Debug-only; Release path fixed via PR-D async pipeline)
- P3 downgraded: **P1-002 → P3** (unreachable crash path — `holeIndices` never passed)
- P2 nice-to-fix: **P2-001..P2-005**

---

## S11) Export Pipeline (added 2026-02-17)

### Overview (PROVEN)
- GPU-only video export implemented via `VideoExporter` + AVAssetWriter.
- Uses CVPixelBufferPool → CVMetalTextureCache → MTLTexture for zero-copy GPU rendering.
- In-flight pipelining with `maxFramesInFlight` semaphore control.
- Audio export via `AudioCompositionBuilder` + `AudioWriterPump`.
- Release Export UI via `ExportProgressViewController` modal.

### Proven reachable call graph (Release Export)

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `exportTapped() — starts Release Export`
```swift
    @objc private func exportTapped() {
        guard !isExporting else { return }
        startExport()
    }
```

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `startExport() — creates ExportProgressViewController + VideoExporter`
```swift
    private func startExport() {
        // ... setup ExportProgressViewController ...
        let exporter = VideoExporter()
        self.videoExporter = exporter

        // Create export texture provider (thread-safe)
        let exportProvider = ExportTextureProvider(
            device: device,
            assetIndex: compiled.mergedAssetIndex,
            resolver: currentResolver!,
            bindingAssetIds: compiled.bindingAssetIds
        )

        // Preload + inject user media textures
        ExportTextureProvider.preloadAll(...)
        exportProvider.injectTextures(from: currentMutableTextureProvider, ...)

        // Start export
        exporter.exportVideo(
            compiledScene: compiled,
            scenePlayer: scenePlayer!,
            renderer: renderer!,
            textureProvider: exportProvider,
            ...
        )
    }
```

**Code anchor**
- `AnimiApp/Sources/Export/VideoExporter.swift`
- `exportVideo() — MainActor entry point + background dispatch`
```swift
    @MainActor
    public func exportVideo(
        compiledScene: CompiledScene,
        scenePlayer: ScenePlayer,
        renderer: MetalRenderer,
        textureProvider: MutableTextureProvider,
        ...
    ) {
        // Capture state snapshot on MainActor (deep copy)
        let snapshot = scenePlayer.exportStateSnapshot()
        let videoSelections = userMediaService?.exportVideoSelectionsSnapshot() ?? [:]

        // Run export on background queue
        exportQueue.async { [weak self] in
            self.runExportLoop(...)
        }
    }
```

**Code anchor**
- `AnimiApp/Sources/Export/VideoExporter.swift`
- `runExportLoop() — main export loop with in-flight pipelining`
```swift
    private func runExportLoop(...) {
        // 1. Create AVAssetWriter
        // 2. Configure video input + pixel buffer adaptor
        // 3. PR-E4: Build audio pipeline (if configured)
        // 4. Start writing
        // 5. Create CVMetalTextureCache
        // 6. PR-E3: Setup video slots coordinator
        // 7. Video export loop with semaphore
        for frameIndex in 0..<totalFrames {
            semaphore.wait()
            videoGroup.enter()

            // Get pixel buffer from pool → create Metal texture → render → append
            commandBuffer.addCompletedHandler { [weak self] _ in
                self.writerQueue.async {
                    adaptor.append(inFlightFrame.pixelBuffer, ...)
                    videoGroup.leave()
                    semaphore.signal()
                }
            }
            commandBuffer.commit()
        }

        // Wait for all frames + finalize
        videoGroup.wait()
        audioGroup.wait()
        writer.finishWriting { ... }
    }
```

### Key Components

#### VideoQualityPreset (B2)
```swift
public enum VideoQualityPreset: Sendable {
    case low      // ~4 Mbps for 1080p
    case medium   // ~10 Mbps for 1080p
    case high     // ~15 Mbps for 1080p
    case max      // ~25 Mbps for 1080p
    case custom(bitrate: Int)

    public func bitrate(for canvasSize: (width: Int, height: Int)) -> Int {
        // Scales by pixel count relative to 1080p
    }
}
```

#### ExportVideoSlotsCoordinator (B1: Visibility Gating)
```swift
/// B1: Prefetch margin in seconds for visibility gating.
private let visibilityPrefetchMarginSeconds: Double = 1.0

public func updateTextures(forSceneFrameIndex sceneFrameIndex: Int) {
    let prefetchFrames = Int(visibilityPrefetchMarginSeconds * sceneFPS)

    for (_, slot) in slots {
        // B1: Visibility gating — skip slots that are not visible
        let visibilityStart = max(0, slot.startFrame - prefetchFrames)
        guard sceneFrameIndex >= visibilityStart && sceneFrameIndex < slot.endFrame else {
            continue
        }
        // ... decode and inject texture
    }
}
```

#### ExportProgressViewController (Release Export UI)
```swift
enum ExportProgressState {
    case preparing
    case rendering(progress: Double)
    case finishing
    case completed(URL)
    case failed(Error)
    case cancelled
}

final class ExportProgressViewController: UIViewController {
    var onCancel: (() -> Void)?
    var onCompleted: ((URL) -> Void)?
    var onFailed: ((Error) -> Void)?

    func updateState(_ state: ExportProgressState) { ... }
}
```

#### Cancel Flow (P0 Fix)
```swift
// In PlayerViewController.startExport():
var wasCancelled = false

progressVC.onCancel = { [weak self, weak exporter] in
    wasCancelled = true
    exporter?.cancel()
    self?.isExporting = false
    self?.exportButton.isEnabled = true  // Fix 1: restore button
    self?.videoExporter = nil
    self?.dismiss(animated: true)
}

// In completion handler:
guard !wasCancelled else {
    self.log("[Export] Completion ignored (was cancelled)")
    return
}
```

### Ownership & Lifecycle Map (PROVEN)
- `PlayerViewController` owns `videoExporter: VideoExporter?` and `exportProgressVC: ExportProgressViewController?`
- `VideoExporter` owns background queues (`exportQueue`, `writerQueue`) and AVAssetWriter lifecycle
- `ExportVideoSlotsCoordinator` owns per-block `ExportVideoFrameProvider` instances
- `AudioWriterPump` runs independently with `audioGroup` synchronization

### Findings
- P0 cancel-flow issue RESOLVED (button state + wasCancelled flag)
- Thread-safe texture provider (`ExportTextureProvider`) with NSLock
- Visibility gating with 1.0s prefetch margin for video slots
- In-flight pipelining matches `maxFramesInFlight` semaphore

---

## S12) Templates (added 2026-02-17)

### Overview (PROVEN)
- Templates are folder references in Xcode project
- Available templates registered in `PlayerViewController.availableTemplates`

### Current Templates

| Template Name | Display Name | Status |
|---------------|--------------|--------|
| `example_4blocks` | 4 Blocks | ✅ Active |
| `polaroid_shared_demo` | Polaroid | ✅ Active |
| `polaroid_2` | Polaroid 2 | ✅ Active (added 2026-02-17) |

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `availableTemplates array`
```swift
    private let availableTemplates: [(name: String, displayName: String)] = [
        ("example_4blocks", "4 Blocks"),
        ("polaroid_shared_demo", "Polaroid"),
        ("polaroid_2", "Polaroid 2")
    ]
```

### Findings
- `polaroid_2` was added to `availableTemplates` (was missing despite folder existing)

---

## S13) Templates Catalog (added 2026-02-18)

### Overview (PROVEN)
- Templates Catalog provides discovery UI for browsing and selecting templates.
- Catalog loads from `manifest.json` via `Task.detached` (background IO, no UI freeze).
- Navigation: Home → See All → Details → Editor (PlayerViewController in `.editor` mode).
- Video previews use `AVPlayer` with background/foreground lifecycle handling.

### Architecture

```
TemplateCatalog (singleton)
    └── BundleTemplateCatalogLoader
            └── manifest.json → TemplateCatalogSnapshot
                    ├── categories: [CategoryDescriptor]
                    └── templates: [TemplateDescriptor]

TemplatesHomeViewController
    ├── templatesByCategory: [CategoryID: [TemplateDescriptor]] (cached)
    ├── UICollectionView (horizontal sliders per category)
    └── TemplatePreviewCell → PreviewVideoView (AVPlayer)

TemplatesSeeAllViewController
    └── UICollectionView (grid layout)

TemplateDetailsViewController
    ├── Full-screen PreviewVideoView
    ├── Close → popToRootViewController
    └── Use template → PlayerViewController(.editor)

PlayerViewController
    ├── presentationMode: .dev | .editor
    ├── .editor: nav bar visible (system Back), template selector hidden
    └── viewWillAppear: setNavigationBarHidden(false) for .editor
```

### Proven reachable call graph

**Code anchor**
- `AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift`
- `load() — Task.detached for background IO`
```swift
    func load() async -> Result<TemplateCatalogSnapshot, Error> {
        if let snapshot = snapshot { return .success(snapshot) }
        if let existingTask = loadTask { return await existingTask.value }

        let loader = self.loader
        loadTask = Task<Result<TemplateCatalogSnapshot, Error>, Never> {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try loader.loadManifest()
                }.value
                return .success(loaded)
            } catch {
                return .failure(error)
            }
        }

        let result = await loadTask!.value
        if case .success(let loaded) = result { snapshot = loaded }
        loadTask = nil
        return result
    }
```

**Code anchor**
- `AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift`
- `resolveURL(for:) — NSString path parsing + folder URL for compiled.tve`
```swift
    private func resolveURL(for relativePath: String) -> URL? {
        let nsPath = relativePath as NSString
        let directory = nsPath.deletingLastPathComponent
        let filenameWithExt = nsPath.lastPathComponent as NSString
        let filename = filenameWithExt.deletingPathExtension
        let ext = nsPath.pathExtension

        // For compiled.tve, return template folder URL (PlayerViewController expects folder, not file)
        if filename == "compiled" && ext == "tve" {
            let templateFolder = (directory as NSString).lastPathComponent
            if let folderURL = bundle.url(forResource: templateFolder, withExtension: nil, subdirectory: "Templates") {
                return folderURL
            }
            return nil
        }

        // Direct file lookup for other files (preview.mp4, etc.)
        if let directURL = bundle.url(forResource: filename, withExtension: ext.isEmpty ? nil : ext, subdirectory: directory) {
            return directURL
        }
        return nil
    }
```

**Code anchor**
- `AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift`
- `loadCatalog() — caches templatesByCategory`
```swift
    private func loadCatalog() {
        Task {
            let result = await TemplateCatalog.shared.load()
            switch result {
            case .success(let snapshot):
                categories = snapshot.categories
                // Cache templates by category (avoids filter/sort on every cellForItemAt)
                templatesByCategory = Dictionary(grouping: snapshot.templates, by: \.categoryId)
                    .mapValues { $0.sorted { $0.order < $1.order } }
                collectionView.reloadData()
            case .failure(let error):
                print("[Home] Catalog load failed: \(error)")
            }
        }
    }
```

**Code anchor**
- `AnimiApp/Sources/TemplatesUI/PreviewVideoView.swift`
- `Background/foreground notification handling`
```swift
    private func setupObservers() {
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.player?.pause()
        }

        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isVisible else { return }
            self.player?.play()
        }
    }
```

**Code anchor**
- `AnimiApp/Sources/Player/PlayerViewController.swift`
- `viewWillAppear — nav bar for editor mode`
```swift
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Show navigation bar in editor mode (system Back button)
        if case .editor = presentationMode {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| `Task.detached` for catalog load | Prevents MainActor blocking; no `loadTask` polling |
| NSString path parsing | Avoids leading "/" issue from `URL(fileURLWithPath:)` |
| `compiled.tve` → folder URL | PlayerViewController expects template folder, not `.tve` file |
| `templatesByCategory` cache | Avoids filter/sort on every `cellForItemAt` |
| Background/foreground observers | Pause video when app goes to background, resume if visible |
| `viewWillAppear` nav bar restore | Details hides nav bar; Editor must restore it for Back button |
| Constraint switching for `.editor` | `isHidden=true` doesn't collapse layout; explicit constraint activation |

### Ownership & Lifecycle Map (PROVEN)
- `TemplateCatalog.shared` — singleton, owns `snapshot` and `loadTask`
- `TemplatesHomeViewController` owns `templatesByCategory` cache
- `PreviewVideoView` owns `AVPlayer`, observers cleaned in `deinit`
- `PlayerViewController` owns presentation mode constraints

### Findings
- P0 nav bar issue RESOLVED (viewWillAppear restores bar in editor mode)
- P1 sync IO on MainActor RESOLVED (Task.detached for catalog load)
- P1 busy-wait polling RESOLVED (single loadTask pattern)
- P1 filter/sort every cellForItemAt RESOLVED (templatesByCategory cache)
- P2 background handling RESOLVED (notification observers in PreviewVideoView)
- P2 AutoLayout warning in editor mode — minor, logTextView constraint deactivation may log ambiguous height (non-blocking)