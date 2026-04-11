import Foundation
import os.log
import TVECore

private let placementDiagnosticsLogger = Logger(
    subsystem: "com.animi.app",
    category: "PlacementDiagnostics"
)

// MARK: - ScenePlayerApplying Protocol

/// Protocol for ScenePlayer methods used by the applier.
/// Production: ScenePlayer. Tests: spy via @testable import.
@MainActor
protocol ScenePlayerApplying: AnyObject {
    func mediaInputConfig(blockId: String) -> MediaInput?
    func bindingBaseline(blockId: String) -> BindingBaselineRuntime?
    func mediaInputGeometry(blockId: String) -> MediaInputGeometryRuntime?
    func applyVariantSelection(_ mapping: [String: String])
    func setUserTransform(blockId: String, transform: Matrix2D)
    func setUserMediaPresent(blockId: String, present: Bool)
    func setLayerToggle(blockId: String, toggleId: String, enabled: Bool)
}

extension ScenePlayer: ScenePlayerApplying {}

// MARK: - MediaInputProvider

/// Provides default fit mode for a block. Used for placement resolution.
public protocol MediaInputProvider {
    /// Returns the `defaultFit` for the given block, or `nil` if unknown.
    func defaultFit(forBlockId blockId: String) -> FitMode?
}

// MARK: - MediaInputProvider Adapters

/// Adapts `ScenePlayer` to `MediaInputProvider` for placement resolution.
@MainActor
public struct ScenePlayerMediaInputProvider: MediaInputProvider {
    private let scenePlayer: ScenePlayer

    public init(scenePlayer: ScenePlayer) {
        self.scenePlayer = scenePlayer
    }

    public func defaultFit(forBlockId blockId: String) -> FitMode? {
        scenePlayer.mediaInputConfig(blockId: blockId)?.defaultFit
    }
}


/// Stateless helper that applies `SceneState` to runtime components.
///
/// Used by both `PlayerViewController` (scene-edit path) and `SceneInstanceRuntime` (timeline path)
/// to eliminate duplicated apply logic.
///
/// ## Apply Order (canonical)
/// 1. Media restore (visibility atomic via `presentOnReady`)
/// 2. Variants
/// 3. Placement / transforms
/// 4. Layer toggles
///
/// ## Resolver Integration
/// For media blocks with `placement != nil`, `MediaPlacementResolver` generates the `Matrix2D`.
public enum SceneRuntimeStateApplier {
#if DEBUG
    @MainActor
    private static var lastPlacementDiagnosticsByKey: [String: (payload: String, timestamp: TimeInterval)] = [:]
    private static let placementDiagnosticsDedupWindow: TimeInterval = 0.5
#endif

    private struct ResolvedPlacement {
        let matrix: Matrix2D
        let diagnostics: PlacementDiagnostics?
    }

    private struct PlacementDiagnostics {
        let sceneId: String?
        let blockId: String
        let activeVariantId: String?
        let editVariantId: String?
        let defaultFit: FitMode?
        let placement: MediaPlacementState
        let baselineRectLocal: RectD
        let apertureRectLocal: RectD?
        let mediaSize: SizeD
        let mediaSizeSource: String
        let baseFitTransform: Matrix2D
        let resolvedTransform: Matrix2D
        let expectedFrameLocal: RectD
        let actualQuadLocal: [Vec2D]
        let actualQuadAABBLocal: RectD
        let blockRectCanvas: RectD?
        let bindingToCanvasMatrix: Matrix2D?
        let finalToCanvasMatrix: Matrix2D?
        let expectedQuadCanvas: [Vec2D]?
        let expectedQuadAABBCanvas: RectD?
        let apertureAABBCanvas: RectD?
        let actualQuadCanvas: [Vec2D]?
        let actualQuadAABBCanvas: RectD?
    }

    /// Dependencies for URL-free fast-path operations (placement / visibility /
    /// video selection / media-ready). These paths do not touch the file system
    /// and therefore do not need a `ProjectMediaLocator`.
    public struct FastPathDependencies: Sendable {
        public let scenePlayer: ScenePlayer
        public let userMediaService: UserMediaService

        public init(scenePlayer: ScenePlayer, userMediaService: UserMediaService) {
            self.scenePlayer = scenePlayer
            self.userMediaService = userMediaService
        }
    }

    /// Dependencies for full-apply / slot-change paths that need to restore
    /// media from disk. The URLs must be pre-resolved into a `ResolvedMediaMap`
    /// on an async path before entering the synchronous apply.
    public struct RestoreDependencies: Sendable {
        public let scenePlayer: ScenePlayer
        public let userMediaService: UserMediaService
        public let resolvedMedia: ResolvedMediaMap

        public init(
            scenePlayer: ScenePlayer,
            userMediaService: UserMediaService,
            resolvedMedia: ResolvedMediaMap
        ) {
            self.scenePlayer = scenePlayer
            self.userMediaService = userMediaService
            self.resolvedMedia = resolvedMedia
        }
    }

    // MARK: - Full Apply

    /// Applies full `SceneState` to runtime in canonical order.
    ///
    /// - Parameters:
    ///   - state: The scene state to apply.
    ///   - deps: Restore dependencies (includes pre-resolved media URLs).
    /// - Returns: Count of restored media items.
    @MainActor
    @discardableResult
    public static func apply(
        _ state: SceneState,
        deps: RestoreDependencies
    ) -> Int {
        apply(
            state,
            player: deps.scenePlayer,
            userMediaService: deps.userMediaService,
            restore: { slots, svc in
                guard let svc else { return 0 }
                return MediaRestoreCoordinator.restore(slots: slots, to: svc, resolved: deps.resolvedMedia)
            }
        )
    }

    /// Testing overload: accepts protocol-typed player and injectable restore.
    @MainActor
    @discardableResult
    static func apply(
        _ state: SceneState,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService?,
        restore: (_ slots: [String: SceneMediaSlot]?, _ service: UserMediaService?) -> Int = { _, _ in 0 }
    ) -> Int {
        // 1. Media restore (visibility gated via presentOnReady)
        let restoredCount = restore(state.mediaSlotsByBlockId, userMediaService)

        // 2. Variants
        player.applyVariantSelection(state.variantOverrides)

        // 3. Placement / transforms
        applyTransforms(state: state, player: player, userMediaService: userMediaService)

        // 4. Layer toggles
        for (blockId, toggles) in state.layerToggles {
            for (toggleId, enabled) in toggles {
                player.setLayerToggle(blockId: blockId, toggleId: toggleId, enabled: enabled)
            }
        }

        return restoredCount
    }

    // MARK: - Fast-Path: Placement Only

    /// Applies a single placement change without full reload.
    /// Resolves placement → Matrix2D via `MediaPlacementResolver` and sets on player.
    @MainActor
    public static func applyPlacementChange(
        blockId: String,
        placement: MediaPlacementState,
        deps: FastPathDependencies
    ) {
        applyPlacementChange(
            blockId: blockId,
            placement: placement,
            player: deps.scenePlayer,
            userMediaService: deps.userMediaService
        )
    }

    /// Testing overload for placement fast-path.
    @MainActor
    static func applyPlacementChange(
        blockId: String,
        placement: MediaPlacementState,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService? = nil
    ) {
        let resolved = resolvePlacement(
            blockId: blockId,
            placement: placement,
            player: player,
            userMediaService: userMediaService
        )
        player.setUserTransform(blockId: blockId, transform: resolved.matrix)
        logPlacementDiagnostics(
            stage: "fast-path",
            resolved: resolved
        )
    }

    // MARK: - Fast-Path: Visibility Only

    /// Applies a visibility change without full reload.
    @MainActor
    public static func applyVisibilityChange(
        blockId: String,
        visible: Bool,
        player: ScenePlayer
    ) {
        applyVisibilityChange(blockId: blockId, visible: visible, playerApplying: player)
    }

    /// Testing overload for visibility fast-path.
    @MainActor
    static func applyVisibilityChange(
        blockId: String,
        visible: Bool,
        playerApplying player: any ScenePlayerApplying
    ) {
        player.setUserMediaPresent(blockId: blockId, present: visible)
    }

    // MARK: - Fast-Path: Video Selection

    /// Applies a video selection change via UserMediaService.
    /// Throws if UMS validation fails.
    @MainActor
    public static func applyVideoSelectionChange(
        blockId: String,
        selection: PersistedVideoSelection,
        service: UserMediaService
    ) throws {
        try service.applyPersistedVideoSelection(blockId: blockId, selection)
    }

    // MARK: - Fast-Path: Slot Change

    /// Applies a single slot change (insert/replace/remove).
    /// Restores media, applies visibility and placement.
    @MainActor
    @discardableResult
    public static func applySlotChange(
        blockId: String,
        slot: SceneMediaSlot?,
        deps: RestoreDependencies
    ) -> Int {
        applySlotChange(
            blockId: blockId,
            slot: slot,
            player: deps.scenePlayer,
            userMediaService: deps.userMediaService,
            restore: { slots, svc in
                guard let svc else { return 0 }
                return MediaRestoreCoordinator.restore(slots: slots, to: svc, resolved: deps.resolvedMedia)
            }
        )
    }

    /// Testing overload for slot change fast-path.
    @MainActor
    @discardableResult
    static func applySlotChange(
        blockId: String,
        slot: SceneMediaSlot?,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService? = nil,
        restore: (_ slots: [String: SceneMediaSlot]?, _ service: UserMediaService?) -> Int = { _, _ in 0 }
    ) -> Int {
        if let slot {
            // Restore single slot
            let singleSlot: [String: SceneMediaSlot]? = [blockId: slot]
            let count = restore(singleSlot, userMediaService)

            // Apply placement
            applyPlacementChange(
                blockId: blockId,
                placement: slot.asset.placement,
                player: player,
                userMediaService: userMediaService
            )

            return count
        } else {
            // Remove: hide media for this block (full cleanup on next reload)
            player.setUserMediaPresent(blockId: blockId, present: false)
            return 0
        }
    }

    // MARK: - Internal

    /// Applies transforms for all blocks, using resolver for media blocks with placement.
    @MainActor
    private static func applyTransforms(state: SceneState, player: any ScenePlayerApplying, userMediaService: UserMediaService?) {
        // Track which blocks got placement-based transforms
        var placementApplied: Set<String> = []

        // Media blocks: resolve placement via MediaPlacementResolver
        if let slots = state.mediaSlotsByBlockId {
            for (blockId, slot) in slots {
                let resolved = resolvePlacement(
                    blockId: blockId,
                    placement: slot.asset.placement,
                    player: player,
                    userMediaService: userMediaService
                )
                player.setUserTransform(blockId: blockId, transform: resolved.matrix)
                logPlacementDiagnostics(
                    stage: "full-apply",
                    resolved: resolved
                )
                placementApplied.insert(blockId)
            }
        }

    }

    /// Resolves a placement to Matrix2D using MediaPlacementResolver.
    /// Uses binding baseline rect (not aperture AABB) as the target for fitting.
    /// Uses actual loaded media size when available, falls back to baseline rect.
    @MainActor
    private static func resolveTransform(
        blockId: String,
        placement: MediaPlacementState,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService? = nil
    ) -> Matrix2D {
        resolvePlacement(
            blockId: blockId,
            placement: placement,
            player: player,
            userMediaService: userMediaService
        ).matrix
    }

    @MainActor
    private static func resolvePlacement(
        blockId: String,
        placement: MediaPlacementState,
        player: any ScenePlayerApplying,
        userMediaService: UserMediaService? = nil
    ) -> ResolvedPlacement {
        guard let baseline = player.bindingBaseline(blockId: blockId) else {
            return ResolvedPlacement(matrix: .identity, diagnostics: nil)
        }

        let baselineRect = baseline.contentRectLocal

        // Use actual presentation-correct media size if available (loaded texture/video),
        // otherwise fall back to baseline rect dimensions (will be corrected on next apply after load).
        let mediaW: Double
        let mediaH: Double
        let mediaSizeSource: String
        if let size = userMediaService?.mediaPresentationSize(blockId: blockId) {
            mediaW = size.width
            mediaH = size.height
            mediaSizeSource = "presentation"
        } else {
            mediaW = baselineRect.width
            mediaH = baselineRect.height
            mediaSizeSource = "baseline-fallback"
        }

        let geometry = MediaPlacementResolver.SlotGeometry(
            baselineRectLocal: baselineRect,
            mediaWidth: mediaW,
            mediaHeight: mediaH
        )

        let baseFit = MediaPlacementResolver.baseFitTransform(
            fitMode: placement.fitMode,
            geometry: geometry
        )
        let resolved = MediaPlacementResolver.resolve(placement: placement, geometry: geometry)
        let actualQuadLocal = transformQuad(width: mediaW, height: mediaH, matrix: resolved)
        let actualQuadAABBLocal = boundingRect(points: actualQuadLocal)

        let scenePlayer = player as? ScenePlayer
        let compiled = scenePlayer?.compiledScene
        let runtimeBlock = compiled?.runtime.blocks.first(where: { $0.blockId == blockId })
        let activeVariantId = scenePlayer?.selectedVariantId(blockId: blockId)
        let editVariantId = runtimeBlock?.editVariantId
        let blockRectCanvas = runtimeBlock?.rectCanvas
        let bindingToCanvasMatrix = scenePlayer?.editBindingToCanvasMatrix(blockId: blockId)
        let expectedQuadCanvas = bindingToCanvasMatrix.map { transformRectAsQuad(rect: baselineRect, matrix: $0) }
        let expectedQuadAABBCanvas = expectedQuadCanvas.map(boundingRect(points:))
        let finalToCanvasMatrix = bindingToCanvasMatrix.map { $0.concatenating(resolved) }
        let actualQuadCanvas = finalToCanvasMatrix.map { transformQuad(width: mediaW, height: mediaH, matrix: $0) }
        let actualQuadAABBCanvas = actualQuadCanvas.map(boundingRect(points:))
        let apertureAABBCanvas = scenePlayer?.mediaInputHitPath(
            blockId: blockId,
            frame: ScenePlayer.editFrameIndex,
            mode: .edit
        ).map { boundingRect(points: $0.vertices) }

        let diagnostics = PlacementDiagnostics(
            sceneId: compiled?.runtime.scene.sceneId,
            blockId: blockId,
            activeVariantId: activeVariantId,
            editVariantId: editVariantId,
            defaultFit: player.mediaInputConfig(blockId: blockId)?.defaultFit,
            placement: placement,
            baselineRectLocal: baselineRect,
            apertureRectLocal: player.mediaInputGeometry(blockId: blockId)?.placementRectLocal,
            mediaSize: SizeD(width: mediaW, height: mediaH),
            mediaSizeSource: mediaSizeSource,
            baseFitTransform: baseFit,
            resolvedTransform: resolved,
            expectedFrameLocal: baselineRect,
            actualQuadLocal: actualQuadLocal,
            actualQuadAABBLocal: actualQuadAABBLocal,
            blockRectCanvas: blockRectCanvas,
            bindingToCanvasMatrix: bindingToCanvasMatrix,
            finalToCanvasMatrix: finalToCanvasMatrix,
            expectedQuadCanvas: expectedQuadCanvas,
            expectedQuadAABBCanvas: expectedQuadAABBCanvas,
            apertureAABBCanvas: apertureAABBCanvas,
            actualQuadCanvas: actualQuadCanvas,
            actualQuadAABBCanvas: actualQuadAABBCanvas
        )

        return ResolvedPlacement(matrix: resolved, diagnostics: diagnostics)
    }

    private static func transformRectAsQuad(rect: RectD, matrix: Matrix2D) -> [Vec2D] {
        let quad = [
            Vec2D(x: rect.x, y: rect.y),
            Vec2D(x: rect.x + rect.width, y: rect.y),
            Vec2D(x: rect.x + rect.width, y: rect.y + rect.height),
            Vec2D(x: rect.x, y: rect.y + rect.height)
        ]
        return quad.map { matrix.apply(to: $0) }
    }

    private static func transformQuad(width: Double, height: Double, matrix: Matrix2D) -> [Vec2D] {
        let quad = [
            Vec2D(x: 0, y: 0),
            Vec2D(x: width, y: 0),
            Vec2D(x: width, y: height),
            Vec2D(x: 0, y: height)
        ]
        return quad.map { matrix.apply(to: $0) }
    }

    private static func boundingRect(points: [Vec2D]) -> RectD {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        return RectD(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func format(rect: RectD) -> String {
        "x=\(fmt(rect.x)) y=\(fmt(rect.y)) w=\(fmt(rect.width)) h=\(fmt(rect.height))"
    }

    private static func format(size: SizeD) -> String {
        "w=\(fmt(size.width)) h=\(fmt(size.height))"
    }

    private static func format(point: Vec2D) -> String {
        "(\(fmt(point.x)), \(fmt(point.y)))"
    }

    private static func format(points: [Vec2D]) -> String {
        points.map(format(point:)).joined(separator: ", ")
    }

    private static func format(optionalRect: RectD?) -> String {
        guard let rect = optionalRect else { return "nil" }
        return format(rect: rect)
    }

    private static func format(optionalMatrix: Matrix2D?) -> String {
        guard let matrix = optionalMatrix else { return "nil" }
        return format(matrix: matrix)
    }

    private static func format(optionalPoints: [Vec2D]?) -> String {
        guard let points = optionalPoints else { return "nil" }
        return "[\(format(points: points))]"
    }

    private static func format(matrix: Matrix2D) -> String {
        "a=\(fmt(matrix.a)) b=\(fmt(matrix.b)) c=\(fmt(matrix.c)) d=\(fmt(matrix.d)) tx=\(fmt(matrix.tx)) ty=\(fmt(matrix.ty))"
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    @MainActor
    private static func logPlacementDiagnostics(stage: String, resolved: ResolvedPlacement) {
#if DEBUG
        guard let diagnostics = resolved.diagnostics else { return }

        let payload = """
scene=\(diagnostics.sceneId ?? "nil") block=\(diagnostics.blockId) variants={active=\(diagnostics.activeVariantId ?? "nil") edit=\(diagnostics.editVariantId ?? "nil")} defaultFit=\(String(describing: diagnostics.defaultFit)) placement={fit=\(String(describing: diagnostics.placement.fitMode)) offset=(\(fmt(diagnostics.placement.offsetX)), \(fmt(diagnostics.placement.offsetY))) scale=\(fmt(diagnostics.placement.userScale)) rotation=\(fmt(diagnostics.placement.rotationDegrees))}
template.expected bindingBaseline(binding-local)=\(format(rect: diagnostics.baselineRectLocal)) apertureAABB(block-local)=\(format(optionalRect: diagnostics.apertureRectLocal))
template.expected blockRect(canvas)=\(format(optionalRect: diagnostics.blockRectCanvas)) bindingToCanvas(edit)=\(format(optionalMatrix: diagnostics.bindingToCanvasMatrix))
template.expected frame(canvas-edit)=\(format(optionalPoints: diagnostics.expectedQuadCanvas)) aabb=\(format(optionalRect: diagnostics.expectedQuadAABBCanvas)) apertureAABB(canvas-edit)=\(format(optionalRect: diagnostics.apertureAABBCanvas))
runtime.actual mediaSize[\(diagnostics.mediaSizeSource)]=\(format(size: diagnostics.mediaSize)) expectedFrame(binding-local)=\(format(rect: diagnostics.expectedFrameLocal))
runtime.actual baseFit=\(format(matrix: diagnostics.baseFitTransform)) resolved=\(format(matrix: diagnostics.resolvedTransform)) finalToCanvas(edit)=\(format(optionalMatrix: diagnostics.finalToCanvasMatrix))
runtime.actual quad(binding-local)=[\(format(points: diagnostics.actualQuadLocal))] aabb=\(format(rect: diagnostics.actualQuadAABBLocal))
runtime.actual quad(canvas-edit)=\(format(optionalPoints: diagnostics.actualQuadCanvas)) aabb=\(format(optionalRect: diagnostics.actualQuadAABBCanvas))
"""

        let key = "\(diagnostics.sceneId ?? "nil")|\(diagnostics.blockId)"
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastPlacementDiagnosticsByKey[key],
           last.payload == payload,
           now - last.timestamp < placementDiagnosticsDedupWindow {
            return
        }
        lastPlacementDiagnosticsByKey[key] = (payload: payload, timestamp: now)

        placementDiagnosticsLogger.debug("[PlacementDiag][\(stage, privacy: .public)]\n\(payload, privacy: .public)")
#endif
    }
}
