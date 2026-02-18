# Audit scan report (regex-based)

This file is generated during audit from the snapshot to provide evidence for regex-based inventories (counts and per-file hit lists).

**Last updated:** 2026-02-17

---

## New Files Since Last Audit (2026-02-11)

### Export Pipeline (PR-E1..E4, Release Export)

| File | Description |
|------|-------------|
| `AnimiApp/Sources/Export/VideoExporter.swift` | GPU-only video exporter with AVAssetWriter |
| `AnimiApp/Sources/Export/ExportProgressViewController.swift` | Modal progress UI for export |
| `AnimiApp/Sources/Export/ExportTextureProvider.swift` | Thread-safe texture provider for export |
| `AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift` | Video slot coordination with visibility gating |
| `AnimiApp/Sources/Export/ExportVideoFrameProvider.swift` | Video frame extraction for export |
| `AnimiApp/Sources/Export/AudioCompositionBuilder.swift` | Audio timeline composition builder |
| `AnimiApp/Sources/Export/AudioWriterPump.swift` | AVAssetWriter audio input pump |

### Templates

| File | Description |
|------|-------------|
| `AnimiApp/Resources/Templates/polaroid_2/` | New polaroid_2 template (folder reference) |

### Templates Catalog (PR-Templates, 2026-02-18)

| File | Description |
|------|-------------|
| `AnimiApp/Sources/TemplatesCatalog/TemplateCatalog.swift` | Singleton catalog with async load + caching |
| `AnimiApp/Sources/TemplatesCatalog/BundleTemplateCatalogLoader.swift` | Bundle manifest loader + URL resolution |
| `AnimiApp/Sources/TemplatesCatalog/TemplateDescriptor.swift` | Template model (id, title, category, paths) |
| `AnimiApp/Sources/TemplatesCatalog/CatalogManifest.swift` | JSON manifest model (categories + templates) |
| `AnimiApp/Sources/TemplatesUI/TemplatesHomeViewController.swift` | Home screen with category sliders |
| `AnimiApp/Sources/TemplatesUI/TemplatesSeeAllViewController.swift` | Grid view for category templates |
| `AnimiApp/Sources/TemplatesUI/TemplateDetailsViewController.swift` | Full-screen preview + Use template |
| `AnimiApp/Sources/TemplatesUI/TemplatePreviewCell.swift` | Collection view cell with video preview |
| `AnimiApp/Sources/TemplatesUI/PreviewVideoView.swift` | AVPlayer wrapper with background handling |

---

## Pattern inventories

### force_unwrap
- Regex: `![\s\)\],;:]`
- Total matches (regex count): 250

- F-0231 `TVECore/Tests/TVECoreTests/ShapePathExtractorTests.swift` — 78
- F-0230 `TVECore/Tests/TVECoreTests/ShapeItemDecodeTests.swift` — 28
- F-0091 `TVECore/Sources/TVECore/MetalRenderer/Earcut.swift` — 12
- F-0153 `TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift` — 10
- F-0147 `TVECore/Tests/TVECoreTests/LayerToggleTests.swift` — 9
- F-0150 `TVECore/Tests/TVECoreTests/MediaInputTests.swift` — 9
- F-0138 `TVECore/Tests/TVECoreTests/AnimLoaderTests.swift` — 8
- F-0033 `AnimiApp/Sources/Player/PlayerViewController.swift` — 7
- F-0060 `TVECore/Sources/TVECompilerCore/Bridges/LottieToAnimIRPath.swift` — 6
- F-0149 `TVECore/Tests/TVECoreTests/MaskModeCommandTests.swift` — 6
- F-0233 `TVECore/Tests/TVECoreTests/SharedMatteTests.swift` — 6
- F-0139 `TVECore/Tests/TVECoreTests/AnimValidatorTests.swift` — 5
- F-0145 `TVECore/Tests/TVECoreTests/ImplicitMatteSourceTests.swift` — 5
- F-0237 `TVECore/Tests/TVECoreTests/UserTransformPipelineTests.swift` — 5
- F-0140 `TVECore/Tests/TVECoreTests/AnimatedPathSamplingTests.swift` — 4
- F-0135 `TVECore/Tests/TVECoreTests/AlphaMatteTests.swift` — 3
- F-0136 `TVECore/Tests/TVECoreTests/AnimIRCompilerTests.swift` — 3
- F-0144 `TVECore/Tests/TVECoreTests/HitTestOverlayTests.swift` — 3
- F-0151 `TVECore/Tests/TVECoreTests/MetalRendererAnimatedMatteMorphTests.swift` — 3
- F-0154 `TVECore/Tests/TVECoreTests/MetalRendererMatteTests.swift` — 3
- F-0155 `TVECore/Tests/TVECoreTests/NestedPrecompPropagationTests.swift` — 3
- F-0160 `TVECore/Tests/TVECoreTests/RenderCommandValidatorTests.swift` — 3
- F-0238 `TVECore/Tests/TVECoreTests/VariantSwitchTests.swift` — 3
- F-0137 `TVECore/Tests/TVECoreTests/AnimIRTransformTests.swift` — 2
- F-0152 `TVECore/Tests/TVECoreTests/MetalRendererBaselineTests.swift` — 2
- F-0156 `TVECore/Tests/TVECoreTests/NoPlaceholderBindingTests.swift` — 2
- F-0161 `TVECore/Tests/TVECoreTests/RenderGraphContractTests.swift` — 2
- F-0224 `TVECore/Tests/TVECoreTests/ScenePackageLoaderTests.swift` — 2
- F-0226 `TVECore/Tests/TVECoreTests/ScenePlayerRenderIntegrationTests.swift` — 2
- F-0235 `TVECore/Tests/TVECoreTests/TemplateModeTests.swift` — 2
- F-0035 `AnimiApp/Sources/UserMedia/PerfLogger.swift` — 1
- F-0087 `TVECore/Sources/TVECore/Assets/LocalAssetsIndex.swift` — 1
- F-0088 `TVECore/Sources/TVECore/Assets/SharedAssetsIndex.swift` — 1
- F-0097 `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+Execute.swift` — 1
- F-0098 `TVECore/Sources/TVECore/MetalRenderer/MetalRenderer+MaskHelpers.swift` — 1
- F-0101 `TVECore/Sources/TVECore/MetalRenderer/MetalRendererResources.swift` — 1
- F-0110 `TVECore/Sources/TVECore/MetalRenderer/VertexUploadPool.swift` — 1
- F-0146 `TVECore/Tests/TVECoreTests/InputClipGroupTransformTests.swift` — 1
- F-0148 `TVECore/Tests/TVECoreTests/MaskExtractionTests.swift` — 1
- F-0225 `TVECore/Tests/TVECoreTests/ScenePlayerDiagnosticTests.swift` — 1
- F-0228 `TVECore/Tests/TVECoreTests/SceneValidatorTests.swift` — 1
- F-0232 `TVECore/Tests/TVECoreTests/SharedAssetsResolverTests.swift` — 1
- F-0236 `TVECore/Tests/TVECoreTests/TestProfileTransformsTests.swift` — 1
- F-0239 `TVECore/Tests/TVECoreTests/VertexUploadPoolTests.swift` — 1

### fatalError
- Regex: `\bfatalError\s*\(`
- Total matches (regex count): 2

- F-0031 `AnimiApp/Sources/Editor/EditorOverlayView.swift` — 1
- F-0034 `AnimiApp/Sources/Player/PreparingOverlayView.swift` — 1

### unwrap_optional_chain
- Regex: `!\.`
- Total matches (regex count): 47

- F-0091 `TVECore/Sources/TVECore/MetalRenderer/Earcut.swift` — 13
- F-0158 `TVECore/Tests/TVECoreTests/PerfMetricsTests.swift` — 8
- F-0238 `TVECore/Tests/TVECoreTests/VariantSwitchTests.swift` — 6
- F-0140 `TVECore/Tests/TVECoreTests/AnimatedPathSamplingTests.swift` — 3
- F-0150 `TVECore/Tests/TVECoreTests/MediaInputTests.swift` — 3
- F-0153 `TVECore/Tests/TVECoreTests/MetalRendererMaskTests.swift` — 3
- F-0232 `TVECore/Tests/TVECoreTests/SharedAssetsResolverTests.swift` — 3
- F-0231 `TVECore/Tests/TVECoreTests/ShapePathExtractorTests.swift` — 2
- F-0233 `TVECore/Tests/TVECoreTests/SharedMatteTests.swift` — 2
- F-0225 `TVECore/Tests/TVECoreTests/ScenePlayerDiagnosticTests.swift` — 1
- F-0226 `TVECore/Tests/TVECoreTests/ScenePlayerRenderIntegrationTests.swift` — 1
- F-0227 `TVECore/Tests/TVECoreTests/ScenePlayerTests.swift` — 1
- F-0235 `TVECore/Tests/TVECoreTests/TemplateModeTests.swift` — 1

## Keyword scans (presence/absence evidence)

These scans are used ONLY for subsystem presence/absence claims. They are recorded here to avoid “grep-only” assertions.

### Persistence / storage — code scope (AnimiApp/Sources, TVECore/Sources, TVECore/Tests, Scripts)
Keywords: CoreData, NSPersistentContainer, NSManagedObject, SQLite, FMDB, Realm, GRDB, UserDefaults, Keychain, SecItem, SecureEnclave, NSUbiquitousKeyValueStore, .xcdatamodeld
Matches:
- Total matches: 0
- Matched files: (none)

### Networking / analytics / remote config — code scope (AnimiApp/Sources, TVECore/Sources, TVECore/Tests, Scripts)
Keywords: URLSession, NSURLSession, Alamofire, Moya, GraphQL, Apollo, FirebaseRemoteConfig, RemoteConfig, FirebaseAnalytics, Crashlytics, Sentry, Mixpanel, Amplitude, AppsFlyer, Analytics.logEvent, Appsflyer, AFSDK, FirebaseApp, FIRApp
Matches:
- Total matches: 0
- Matched files: (none)

### Notes (full snapshot matches, including Docs/)
- Persistence/storage keywords — full snapshot: total matches 1
- Matched files:
  - F-0042 `Docs/FULL_PROJECT_AUDIT_2026-02-10.md` — 1

- Networking/analytics/remote config keywords — full snapshot: total matches 0
- Matched files:
  - (none)

---

## Export Pipeline Files (added 2026-02-17)

### Export Source Files
| File ID | Path | Lines |
|---------|------|-------|
| F-EXP-001 | `AnimiApp/Sources/Export/VideoExporter.swift` | ~919 |
| F-EXP-002 | `AnimiApp/Sources/Export/ExportProgressViewController.swift` | ~214 |
| F-EXP-003 | `AnimiApp/Sources/Export/ExportTextureProvider.swift` | ~202 |
| F-EXP-004 | `AnimiApp/Sources/Export/ExportVideoSlotsCoordinator.swift` | ~244 |
| F-EXP-005 | `AnimiApp/Sources/Export/ExportVideoFrameProvider.swift` | ~250 (est) |
| F-EXP-006 | `AnimiApp/Sources/Export/AudioCompositionBuilder.swift` | ~278 |
| F-EXP-007 | `AnimiApp/Sources/Export/AudioWriterPump.swift` | ~150 (est) |

### Key Types Introduced
- `VideoExporter` — GPU-only video export orchestrator
- `VideoExportSettings` — Export configuration (H.264, bitrate, fps)
- `VideoExportError` — Comprehensive error enum for export failures
- `VideoQualityPreset` — Quality levels (low/medium/high/max/custom)
- `AudioExportConfig` — Audio export configuration
- `AudioTrackConfig` — Single audio track config (music/voiceover)
- `BuiltAudioPipeline` — Result of audio composition building
- `ExportProgressViewController` — Modal progress UI
- `ExportProgressState` — UI state enum (preparing/rendering/finishing/completed/failed/cancelled)
- `ExportTextureProvider` — Thread-safe MutableTextureProvider
- `ExportVideoSlotsCoordinator` — Video slot coordination with visibility gating
- `ExportVideoFrameProvider` — Video frame extraction with block timing
- `AudioCompositionBuilder` — AVMutableComposition builder
- `AudioWriterPump` — Async audio writing pump
