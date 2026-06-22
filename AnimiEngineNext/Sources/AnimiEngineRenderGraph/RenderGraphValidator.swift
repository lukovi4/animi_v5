import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §7.4 — the independent RenderGraph validator (§17 step 9 corrective #10).
///
/// Re-checks a compiled graph against every §7.4 condition independently of the compiler, strengthened
/// per corrective #10:
///   * the full `graph.configuration` must equal the supplied configuration;
///   * resources are declared before use, with the exact kind for each reference;
///   * every render target is **written before it is read** (no implicit current surface);
///   * `beginScene`/`endScene` match on scene id + role; commands are legal inside/outside scene and
///     mask/clip scopes;
///   * the final source/destination chain is exact (`linearCanvas` → sRGB → output);
///   * pixel/offscreen descriptor invariants hold (positive dims; pixel resources carry bytes).
public enum RenderGraphValidator {

    public static func validate(_ graph: RenderGraph, configuration: RenderConfiguration) throws {
        try validateConfiguration(graph, configuration: configuration)
        try validateOrderAndFinalChain(graph)
        try validateSequential(graph, configuration: configuration)
    }

    // MARK: - Configuration

    private static func validateConfiguration(_ graph: RenderGraph, configuration: RenderConfiguration) throws {
        // Full configuration equality (corrective #10), not only the colour contract.
        guard graph.configuration == configuration else {
            throw RenderGraphError.validatorColorProfileMismatch(detail: "graph.configuration != supplied configuration")
        }
        guard graph.configuration.colorContract == .task003 else {
            throw RenderGraphError.validatorColorProfileMismatch(detail: "non-Task-003 colour contract")
        }
    }

    // MARK: - Command order + final source/destination chain

    private static func validateOrderAndFinalChain(_ graph: RenderGraph) throws {
        let cmds = graph.commands
        // Resource/surface declarations come first; the first non-declaration command must clear the
        // linear canvas (corrective #5: declare-before-use + clear-first).
        let firstBody = cmds.first { $0.category != .declareResource && $0.category != .offscreenSurface }
        guard let first = firstBody, case let .clearBackground(_, firstTarget) = first.payload,
              firstTarget == RenderSurface.linearCanvas else {
            throw RenderGraphError.validatorInvalidCommandOrder(detail: "first non-declaration command must clear the linear canvas")
        }
        // The linear canvas is cleared exactly once; any later clearBackground may only target a
        // matte/scene/transition surface (initialisation), never the linear canvas again.
        var seenLinearClear = false
        for c in cmds {
            if case let .clearBackground(_, target) = c.payload, target == RenderSurface.linearCanvas {
                if seenLinearClear { throw RenderGraphError.validatorInvalidCommandOrder(detail: "linear canvas cleared more than once") }
                seenLinearClear = true
            }
        }
        // Exactly one finalLinearToSRGB then one finalOutput, last.
        let outputs = cmds.filter { $0.category == .finalOutput }
        let srgbs = cmds.filter { $0.category == .finalLinearToSRGB }
        guard outputs.count == 1, srgbs.count == 1 else {
            throw RenderGraphError.validatorIncompleteFinalOutput(detail: "exactly one sRGB + one output required")
        }
        guard let last = cmds.last, last.category == .finalOutput,
              cmds.count >= 2, cmds[cmds.count - 2].category == .finalLinearToSRGB else {
            throw RenderGraphError.validatorIncompleteFinalOutput(detail: "graph must end with finalLinearToSRGB then finalOutput")
        }
        // Exact final chain: sRGB reads linearCanvas → sRGB surface; output reads sRGB surface.
        guard case let .finalLinearToSRGB(srgbSource, srgbTarget) = cmds[cmds.count - 2].payload,
              srgbSource == RenderSurface.linearCanvas, srgbTarget == RenderSurface.sRGBSurface else {
            throw RenderGraphError.validatorIncompleteFinalOutput(detail: "finalLinearToSRGB must read linearCanvas, write sRGB")
        }
        guard case let .finalOutput(outSource) = last.payload, outSource == RenderSurface.sRGBSurface else {
            throw RenderGraphError.validatorIncompleteFinalOutput(detail: "finalOutput must read sRGB surface")
        }
    }

    // MARK: - Resource declarations + descriptor invariants

    // MARK: - Single sequential pass: declaration-before-use, write-before-read, scopes (corrective #5/#6/#10)

    private static func validateSequential(_ graph: RenderGraph, configuration: RenderConfiguration) throws {
        var declared: [String: RenderResourceDescriptor] = [:]
        var written = Set<String>()
        // Surfaces that received an actual draw command (not merely a clear). A matteLink requires its
        // source surface to have been drawn into — a clear alone does not satisfy it (final corrective #4).
        var drawnInto = Set<String>()
        // Matte surfaces cleared (initialised) inside the current scene scope; a draw into one of them is
        // a legitimate matte-source render pass (corrective #3/#6).
        var matteTargetsInScene = Set<String>()
        enum Scope: Equatable { case scene(String, ResolvedSceneRole, String); case clip; case mask(content: String, target: String) }
        var stack: [Scope] = []

        func openSceneTarget() -> String? {
            for s in stack.reversed() { if case let .scene(_, _, t) = s { return t } }
            return nil
        }
        func insideScene() -> Bool { openSceneTarget() != nil }

        func requireDeclared(_ id: String) throws -> RenderResourceDescriptor {
            guard let d = declared[id] else { throw RenderGraphError.validatorMissingResource(resourceID: id) }
            return d
        }
        func requirePixel(_ id: String) throws {
            let d = try requireDeclared(id)
            // CP7.8: a draw may reference EITHER a bytes pixel input OR a dynamic texture-backed input.
            guard d.kind == .pixelInput || d.kind == .dynamicTexturePixelInput else {
                throw RenderGraphError.validatorUnsupportedMode(field: "reference.kind", value: "\(id) is not a pixel/dynamic-texture input")
            }
        }
        func requireSurface(_ id: String) throws -> RenderResourceDescriptor {
            let d = try requireDeclared(id)
            guard d.kind == .offscreen else {
                throw RenderGraphError.validatorInvalidSurfaceDependency(detail: "\(id) is not an offscreen surface")
            }
            return d
        }
        func requireWritten(_ id: String) throws {
            _ = try requireSurface(id)
            guard written.contains(id) else {
                throw RenderGraphError.validatorInvalidSurfaceDependency(detail: "surface \(id) read before written")
            }
        }
        // Profile/role/storage compatibility (corrective #5/#6): the sRGB output surface is finalSRGB;
        // every other surface is intermediate with the configuration's profile; and the declared
        // physical storage must EXACTLY match the storage the profile implies (no rgba16FloatLinear
        // surface mislabelled as BGRA8).
        func requireProfile(_ d: RenderResourceDescriptor) throws {
            let expectedProfile: RenderSurfaceProfile = d.resourceID == RenderSurface.sRGBSurface
                ? .finalSRGB : .intermediate(configuration.intermediateProfile)
            guard let profile = d.surfaceProfile, profile == expectedProfile else {
                throw RenderGraphError.validatorColorProfileMismatch(detail: "surface \(d.resourceID) profile \(String(describing: d.surfaceProfile)) != expected \(expectedProfile)")
            }
            guard let storage = d.surfaceStorage, storage == profile.storageFormat else {
                throw RenderGraphError.validatorColorProfileMismatch(detail: "surface \(d.resourceID) storage \(String(describing: d.surfaceStorage)) != profile storage \(profile.storageFormat)")
            }
        }
        // The innermost open mask content surface, if any (Rev-4 §2.8): inner content writes there.
        func openMaskContent() -> String? {
            for s in stack.reversed() { if case let .mask(content, _) = s { return content } }
            return nil
        }
        // A draw's target must equal the innermost open mask content surface (when inside a mask group),
        // OR the open scene target, OR an isolation surface initialised in this scene scope (a matte
        // source / matte consumer / mask content render pass, Rev-4 §2.8/§2.9/§5).
        func requireDrawTargetMatchesScene(_ target: String) throws {
            guard let open = openSceneTarget() else {
                throw RenderGraphError.validatorInvalidCommandOrder(detail: "draw outside any scene scope")
            }
            if let maskContent = openMaskContent() {
                guard maskContent == target || matteTargetsInScene.contains(target) else {
                    throw RenderGraphError.validatorInvalidCommandOrder(detail: "draw target \(target) inside mask group must be the content surface \(maskContent) or a nested isolation surface")
                }
                return
            }
            guard open == target || matteTargetsInScene.contains(target) else {
                throw RenderGraphError.validatorInvalidCommandOrder(detail: "draw target \(target) != open scene target \(open) and is not an isolation surface")
            }
        }
        // Two declared offscreen surfaces must agree on width/height/profile/storage (Rev-4 §6.1/§6.2).
        func requireDescriptorsMatch(_ a: String, _ b: String) throws {
            let da = try requireSurface(a), db = try requireSurface(b)
            guard da.width == db.width, da.height == db.height,
                  da.surfaceProfile == db.surfaceProfile, da.surfaceStorage == db.surfaceStorage else {
                throw RenderGraphError.validatorSurfaceDescriptorMismatch(resourceID: a, targetSurfaceID: b)
            }
        }

        for command in graph.commands {
            switch command.payload {
            case .declareResource(let d):
                // CP7.8: a declared resource is EITHER a bytes pixel input OR a dynamic texture input.
                guard d.kind == .pixelInput || d.kind == .dynamicTexturePixelInput else {
                    throw RenderGraphError.validatorUnsupportedMode(field: "declareResource.kind", value: d.kind.rawValue)
                }
                if d.kind == .pixelInput {
                    guard let pixels = d.pixels, pixels.bytes.count == pixels.dimensions.requiredByteCount else {
                        throw RenderGraphError.validatorInvalidDimensions(field: "pixel[\(d.resourceID)].bytes", width: d.width, height: d.height)
                    }
                } else {
                    // Dynamic texture input: NO owned bytes; MUST carry a source id + quarter-turn metadata.
                    guard d.pixels == nil else { throw RenderGraphError.validatorUnsupportedMode(field: "dynamic[\(d.resourceID)].pixels", value: "present") }
                    guard d.dynamicTextureSourceID == d.resourceID else { throw RenderGraphError.validatorUnsupportedMode(field: "dynamic[\(d.resourceID)].sourceID", value: d.dynamicTextureSourceID ?? "nil") }
                    guard let q = d.dynamicOrientationQuarterTurns, (0...3).contains(q) else { throw RenderGraphError.validatorUnsupportedMode(field: "dynamic[\(d.resourceID)].quarterTurns", value: "\(d.dynamicOrientationQuarterTurns ?? -1)") }
                }
                // Both kinds carry an input byte format; surface profile/storage MUST be absent.
                guard d.pixelFormat != nil else { throw RenderGraphError.validatorUnsupportedMode(field: "pixel[\(d.resourceID)].pixelFormat", value: "nil") }
                guard d.surfaceProfile == nil, d.surfaceStorage == nil else { throw RenderGraphError.validatorUnsupportedMode(field: "pixel[\(d.resourceID)].surfaceProfile", value: "present") }
                guard declared[d.resourceID] == nil else { throw RenderGraphError.validatorDuplicateResource(resourceID: d.resourceID) }
                guard d.width > 0, d.height > 0 else { throw RenderGraphError.validatorInvalidDimensions(field: "resource[\(d.resourceID)]", width: d.width, height: d.height) }
                declared[d.resourceID] = d

            case .offscreenSurface(let d):
                guard d.kind == .offscreen, d.pixels == nil else { throw RenderGraphError.validatorUnsupportedMode(field: "offscreenSurface.kind", value: d.kind.rawValue) }
                // An offscreen surface MUST NOT carry a pixel byte format — it is described by
                // profile + storage alone, never mislabelled BGRA8 (final micro-correction #1).
                guard d.pixelFormat == nil else { throw RenderGraphError.validatorUnsupportedMode(field: "surface[\(d.resourceID)].pixelFormat", value: d.pixelFormat?.rawValue ?? "n/a") }
                guard declared[d.resourceID] == nil else { throw RenderGraphError.validatorDuplicateResource(resourceID: d.resourceID) }
                guard d.width > 0, d.height > 0 else { throw RenderGraphError.validatorInvalidDimensions(field: "surface[\(d.resourceID)]", width: d.width, height: d.height) }
                try requireProfile(d)
                declared[d.resourceID] = d

            case let .clearBackground(_, target):
                let d = try requireSurface(target)
                if target == RenderSurface.linearCanvas {
                    guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "linear-canvas clear inside an open scope") }
                } else if insideScene(), target != openSceneTarget() {
                    // A non-scene-target clear inside a scene initialises a matte surface (corrective #3).
                    matteTargetsInScene.insert(target)
                }
                _ = d
                written.insert(target)

            case let .beginScene(id, role, target):
                _ = try requireSurface(target)
                // beginScene/endScene do NOT mark a surface written (corrective #5) — only draws do.
                stack.append(.scene(id, role, target))

            case let .endScene(id, role, target):
                guard case let .scene(bid, brole, btarget)? = stack.last, bid == id, brole == role, btarget == target else {
                    throw RenderGraphError.validatorUnbalancedScope(detail: "endScene mismatch for \(id)/\(role)")
                }
                stack.removeLast()
                if !insideScene() { matteTargetsInScene.removeAll() }

            case let .drawImage(resourceID, _, _, target), let .drawVideoFrame(resourceID, _, _, target):
                try requirePixel(resourceID)
                try requireDrawTargetMatchesScene(target)
                written.insert(target); drawnInto.insert(target)

            case let .drawShape(_, _, _, target):
                try requireDrawTargetMatchesScene(target)
                written.insert(target); drawnInto.insert(target)

            case .beginClip:
                stack.append(.clip)
            case .endClip:
                guard stack.last == .clip else { throw RenderGraphError.validatorUnbalancedScope(detail: "endClip without beginClip") }
                stack.removeLast()
            case let .beginMask(operations, contentSurfaceID, targetSurfaceID):
                // §6.1 — nonempty operations; distinct content/target; both declared; matching descriptors.
                guard insideScene() else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "beginMask outside any scene scope") }
                guard !operations.isEmpty else { throw RenderGraphError.validatorUnsupportedMode(field: "beginMask.operations", value: "empty") }
                guard contentSurfaceID != targetSurfaceID else { throw RenderGraphError.validatorSurfaceAlias(resourceID: contentSurfaceID) }
                let contentDesc = try requireSurface(contentSurfaceID)
                _ = try requireSurface(targetSurfaceID)
                try requireDescriptorsMatch(contentSurfaceID, targetSurfaceID)
                // Each operation mesh must be closed and valid (the value type validated indices already).
                for (i, op) in operations.enumerated() {
                    guard op.mesh.closed else { throw RenderGraphError.validatorUnsupportedMode(field: "beginMask.operations[\(i)].mesh", value: "open mesh") }
                }
                // The content surface must have been cleared (initialised) before inner writes.
                guard written.contains(contentSurfaceID) else {
                    throw RenderGraphError.validatorInvalidSurfaceDependency(detail: "mask content surface \(contentSurfaceID) not cleared before beginMask")
                }
                _ = contentDesc
                stack.append(.mask(content: contentSurfaceID, target: targetSurfaceID))

            case let .endMask(contentSurfaceID, targetSurfaceID):
                guard case let .mask(openContent, openTarget)? = stack.last,
                      openContent == contentSurfaceID, openTarget == targetSurfaceID else {
                    throw RenderGraphError.validatorUnbalancedScope(detail: "endMask mismatch for \(contentSurfaceID)→\(targetSurfaceID)")
                }
                // §6.1 — the content surface must have been drawn into before endMask reads it.
                guard drawnInto.contains(contentSurfaceID) else {
                    throw RenderGraphError.validatorInvalidSurfaceDependency(detail: "mask content surface \(contentSurfaceID) cleared but never drawn into")
                }
                stack.removeLast()
                // endMask composites the masked content into the target — that target is now written/drawn.
                written.insert(targetSurfaceID); drawnInto.insert(targetSurfaceID)

            case let .matteLink(_, _, _, sourceSurfaceID, consumerSurfaceID, targetSurfaceID):
                // §6.2 — three distinct declared surfaces; source+consumer written & drawn into; target
                // declared; matching descriptors; no aliasing.
                guard insideScene() else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "matteLink outside any scene scope") }
                guard sourceSurfaceID != consumerSurfaceID, sourceSurfaceID != targetSurfaceID, consumerSurfaceID != targetSurfaceID else {
                    throw RenderGraphError.validatorSurfaceAlias(resourceID: sourceSurfaceID)
                }
                try requireWritten(sourceSurfaceID)
                try requireWritten(consumerSurfaceID)
                _ = try requireSurface(targetSurfaceID)
                // CP7.5: a matte source surface that was CLEARED in this scene (a declared matte
                // isolation surface) but never drawn into is an EMPTY (non-drawing) matte source — e.g.
                // a source whose content is fully clipped/zero-coverage at this frame. It is allowed
                // (the matteLink composites an empty source). NOTE: a timing-inactive or hidden matte
                // source is NOT this case — the compiler renders such a source HELD (oracle parity), so
                // it IS drawn into. A source surface never even cleared as a matte target is still
                // rejected (a genuine dependency bug).
                guard drawnInto.contains(sourceSurfaceID) || matteTargetsInScene.contains(sourceSurfaceID) else {
                    throw RenderGraphError.validatorInvalidSurfaceDependency(detail: "matte source surface \(sourceSurfaceID) is neither drawn into nor a cleared matte isolation surface")
                }
                // The consumer must always carry real content (it is the matted layer itself).
                guard drawnInto.contains(consumerSurfaceID) else {
                    throw RenderGraphError.validatorInvalidSurfaceDependency(detail: "matte consumer surface \(consumerSurfaceID) cleared but never drawn into")
                }
                try requireDescriptorsMatch(sourceSurfaceID, targetSurfaceID)
                try requireDescriptorsMatch(consumerSurfaceID, targetSurfaceID)
                // The link composites the matted consumer into the target.
                written.insert(targetSurfaceID); drawnInto.insert(targetSurfaceID)

            case let .overlay(resourceID, _, _, _, target):
                guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "overlay inside an open scope") }
                try requirePixel(resourceID); try requireWritten(target); written.insert(target)

            case let .fadeTransition(_, outgoing, incoming, target):
                guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "fade inside an open scope") }
                try requireWritten(outgoing); try requireWritten(incoming); _ = try requireSurface(target); written.insert(target)

            case let .slideTransition(_, _, _, _, outgoing, incoming, target):
                guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "slide inside an open scope") }
                try requireWritten(outgoing); try requireWritten(incoming); _ = try requireSurface(target); written.insert(target)

            case let .pushTransition(_, _, _, _, _, _, outgoing, incoming, target):
                guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "push inside an open scope") }
                try requireWritten(outgoing); try requireWritten(incoming); _ = try requireSurface(target); written.insert(target)

            case let .dipTransition(_, _, outgoing, incoming, target):
                guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "dip inside an open scope") }
                try requireWritten(outgoing); try requireWritten(incoming); _ = try requireSurface(target); written.insert(target)

            case let .finalLinearToSRGB(source, target):
                guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "finalLinearToSRGB inside an open scope") }
                try requireWritten(source); _ = try requireSurface(target); written.insert(target)

            case let .finalOutput(source):
                guard stack.isEmpty else { throw RenderGraphError.validatorInvalidCommandOrder(detail: "finalOutput inside an open scope") }
                try requireWritten(source)
            }
        }
        guard stack.isEmpty else { throw RenderGraphError.validatorUnbalancedScope(detail: "unclosed scope(s)") }
    }
}
