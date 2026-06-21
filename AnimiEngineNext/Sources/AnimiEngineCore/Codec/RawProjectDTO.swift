/// Strict decoder from canonical JSON into validated domain types (Task-002 plan, §11.2).
///
/// Every nested object is read through ``StrictObjectReader`` so unknown fields are rejected at
/// every depth. Values are converted through the domain factories (which throw
/// ``ProjectValidationError`` for semantic problems); the decoder surfaces structural problems as
/// ``ProjectDecodingError`` and lets validation problems propagate to the caller, which classifies
/// them.
enum RawProjectDecoder {
    static func decodeDocument(_ root: StrictJSONValue) throws -> CanonicalProjectDocument {
        var reader = try StrictObjectReader(root, path: "")
        let manifestReader = try reader.object("manifest")
        let manifest = try decodeManifest(manifestReader)
        let scenePayloads = try reader.array("scenePayloads").enumerated().map { index, value in
            try decodeScenePayload(value, path: "scenePayloads[\(index)]")
        }
        let overlayPayloads = try reader.array("overlayPayloads").enumerated().map { index, value in
            try decodeOverlayPayload(value, path: "overlayPayloads[\(index)]")
        }
        try reader.finish()
        return CanonicalProjectDocument(
            manifest: manifest,
            scenePayloads: scenePayloads,
            overlayPayloads: overlayPayloads
        )
    }

    // MARK: - Manifest

    private static func decodeManifest(_ readerIn: StrictObjectReader) throws -> CanonicalProjectManifest {
        var reader = readerIn
        let schemaVersion = try reader.intValue("schemaVersion")
        let output = try decodeOutput(try reader.object("output"))
        let scenes = try reader.array("scenes").enumerated().map { index, value in
            try decodeSceneEntry(value, path: "manifest.scenes[\(index)]", schemaVersion: schemaVersion)
        }
        let transitions = try reader.array("boundaryTransitions").enumerated().map { index, value in
            try decodeTransition(value, path: "manifest.boundaryTransitions[\(index)]")
        }
        let overlays = try reader.array("overlays").enumerated().map { index, value in
            try decodeOverlayEntry(value, path: "manifest.overlays[\(index)]")
        }
        try reader.finish()
        // CP7.5: uplift on decode. A v1 document is read with `timelineSpan = nominalDuration` (above)
        // and its in-memory manifest is normalized to the current schema version, so re-encoding it
        // writes a consistent v2 document (with the `timelineSpan` key). The on-disk `schemaVersion`
        // only drives the dual-path scene-entry read.
        let normalizedVersion = max(schemaVersion, CanonicalProjectManifest.supportedSchemaVersion)
        return CanonicalProjectManifest(
            schemaVersion: normalizedVersion,
            output: output,
            scenes: scenes,
            boundaryTransitions: transitions,
            overlays: overlays
        )
    }

    private static func decodeOutput(_ readerIn: StrictObjectReader) throws -> OutputContext {
        var reader = readerIn
        var canvasReader = try reader.object("canvas")
        let width = try canvasReader.int("width")
        let height = try canvasReader.int("height")
        try canvasReader.finish()
        var rateReader = try reader.object("frameRate")
        let numerator = try rateReader.int("numerator")
        let denominator = try rateReader.int("denominator")
        try rateReader.finish()
        try reader.finish()
        let canvas = try CanvasSize(width: width, height: height)
        let rate = try FrameRate(numerator: numerator, denominator: denominator)
        return OutputContext(canvas: canvas, frameRate: rate)
    }

    private static func decodeSceneEntry(
        _ value: StrictJSONValue, path: String, schemaVersion: Int
    ) throws -> SceneManifestEntry {
        var reader = try StrictObjectReader(value, path: path)
        let id = try SceneInstanceID(try reader.string("id"))
        let payloadID = try ScenePayloadID(try reader.string("payloadID"))
        let nominal = try TickDuration(ticks: try reader.int("nominalDuration"))
        let postRoll = try TickDuration(ticks: try reader.int("postRollCapability"))
        // CP7.5 dual-path: v2 carries an explicit `timelineSpan`; v1 has no such key and uplifts to
        // `timelineSpan = nominalDuration`. `finish()` rejects unknown keys, so a v1 doc must NOT have
        // `timelineSpan` and a v2 doc MUST have it (read it to mark consumed).
        let timelineSpan: TickDuration
        if schemaVersion >= 2 {
            timelineSpan = try TickDuration(ticks: try reader.int("timelineSpan"))
        } else {
            timelineSpan = nominal
        }
        try reader.finish()
        return SceneManifestEntry(
            id: id, payloadID: payloadID, nominalDuration: nominal,
            postRollCapability: postRoll, timelineSpan: timelineSpan
        )
    }

    private static func decodeOverlayEntry(_ value: StrictJSONValue, path: String) throws -> OverlayManifestEntry {
        var reader = try StrictObjectReader(value, path: path)
        let id = try OverlayID(try reader.string("id"))
        let payloadID = try OverlayPayloadID(try reader.string("payloadID"))
        let range = try decodeProjectTimeRange(try reader.object("timeRange"))
        let zIndex = try reader.intValue("zIndex")
        let stableOrdinal = try reader.intValue("stableOrdinal")
        try reader.finish()
        return OverlayManifestEntry(
            id: id, payloadID: payloadID, timeRange: range, zIndex: zIndex, stableOrdinal: stableOrdinal
        )
    }

    private static func decodeProjectTimeRange(_ readerIn: StrictObjectReader) throws -> ProjectTimeRange {
        var reader = readerIn
        let start = try ProjectTime(ticks: try reader.int("start"))
        let end = try ProjectTime(ticks: try reader.int("end"))
        try reader.finish()
        return try ProjectTimeRange(start: start, end: end)
    }

    // MARK: - Transitions

    private static func decodeTransition(_ value: StrictJSONValue, path: String) throws -> SceneTransition {
        var reader = try StrictObjectReader(value, path: path)
        let kindTag = try reader.string("kind")
        let duration = try TickDuration(ticks: try reader.int("duration"))
        let easing = try EasingReference(try reader.string("easing"))
        let kind: TransitionKind
        switch kindTag {
        case "cut":
            kind = .cut
        case "animated":
            var effectReader = try reader.object("effect")
            let effectID = try TransitionEffectID(try effectReader.string("effectID"))
            let params = try effectReader.array("parameters").enumerated().map { index, paramValue in
                try decodeTransitionParameter(paramValue, path: "\(path).effect.parameters[\(index)]")
            }
            try effectReader.finish()
            let set = try TransitionParameterSet(params)
            kind = .animated(TransitionEffect(effectID: effectID, parameters: set))
        default:
            throw ProjectDecodingError.unknownEnumTag(path: "\(path).kind", tag: kindTag)
        }
        try reader.finish()
        return SceneTransition(kind: kind, duration: duration, easing: easing)
    }

    private static func decodeTransitionParameter(_ value: StrictJSONValue, path: String) throws -> TransitionParameter {
        var reader = try StrictObjectReader(value, path: path)
        let key = try reader.string("key")
        let typeTag = try reader.string("type")
        let parameterValue: TransitionParameterValue
        switch typeTag {
        case "integer":
            parameterValue = .integer(try reader.int("value"))
        case "fixed":
            parameterValue = .fixed(ScaleScalar(rawValue: try reader.int("value")))
        case "identifier":
            parameterValue = .identifier(try reader.string("value"))
        case "boolean":
            parameterValue = .boolean(try reader.bool("value"))
        default:
            throw ProjectDecodingError.unknownEnumTag(path: "\(path).type", tag: typeTag)
        }
        try reader.finish()
        return TransitionParameter(key: key, value: parameterValue)
    }

    // MARK: - Scene payloads

    private static func decodeScenePayload(_ value: StrictJSONValue, path: String) throws -> ResolvedScenePayload {
        var reader = try StrictObjectReader(value, path: path)
        let payloadID = try ScenePayloadID(try reader.string("payloadID"))
        let sceneID = try SceneInstanceID(try reader.string("sceneID"))
        var templateReader = try reader.object("templateRef")
        let templateRef = try TemplateReference(
            catalogID: try templateReader.string("catalogID"),
            sceneID: try templateReader.string("sceneID")
        )
        try templateReader.finish()
        let layers = try reader.array("layers").enumerated().map { index, layerValue in
            try decodeSceneLayer(layerValue, path: "\(path).layers[\(index)]")
        }
        try reader.finish()
        return ResolvedScenePayload(
            payloadID: payloadID, sceneID: sceneID, templateRef: templateRef, layers: layers
        )
    }

    private static func decodeSceneLayer(_ value: StrictJSONValue, path: String) throws -> SceneLayer {
        var reader = try StrictObjectReader(value, path: path)
        let id = try LayerID(try reader.string("id"))
        let zIndex = try reader.intValue("zIndex")
        let stableOrdinal = try reader.intValue("stableOrdinal")
        let activeRange = try decodeScenePlaybackRange(try reader.object("activeRange"))
        let placement = try decodePlacement(try reader.object("placement"))
        let mediaPlacement = try decodeMediaPlacement(try reader.object("mediaPlacement"), path: "\(path).mediaPlacement")
        let content = try decodeSceneLayerContent(try reader.object("content"), path: "\(path).content")
        let animation = try decodeOptionalAnimation(try reader.optionalObject("animation"))
        try reader.finish()
        return SceneLayer(
            id: id, zIndex: zIndex, stableOrdinal: stableOrdinal, activeRange: activeRange,
            placement: placement, mediaPlacement: mediaPlacement, content: content, animation: animation
        )
    }

    /// Strictly decodes the authored ``MediaPlacement`` (step-8 corrective, issue #1). The fit mode is
    /// a required enum string (`cover`/`contain`/`fill`); an unknown value is a typed failure with no
    /// default. The user offset/scale/rotation are required fixed-point integers.
    private static func decodeMediaPlacement(_ readerIn: StrictObjectReader, path: String) throws -> MediaPlacement {
        var reader = readerIn
        let fitRaw = try reader.string("fitMode")
        guard let fitMode = MediaFitMode(rawValue: fitRaw) else {
            throw ProjectDecodingError.unknownEnumTag(path: "\(path).fitMode", tag: fitRaw)
        }
        let offsetX = CanvasScalar(rawValue: try reader.int("userOffsetX"))
        let offsetY = CanvasScalar(rawValue: try reader.int("userOffsetY"))
        let scale = ScaleScalar(rawValue: try reader.int("userScale"))
        let rotation = RotationScalar(rawValue: try reader.int("userRotation"))
        try reader.finish()
        return try MediaPlacement(
            fitMode: fitMode, userOffsetX: offsetX, userOffsetY: offsetY,
            userScale: scale, userRotation: rotation)
    }

    private static func decodeScenePlaybackRange(_ readerIn: StrictObjectReader) throws -> ScenePlaybackRange {
        var reader = readerIn
        let start = try ScenePlaybackTime(ticks: try reader.int("start"))
        let end = try ScenePlaybackTime(ticks: try reader.int("end"))
        try reader.finish()
        return try ScenePlaybackRange(start: start, end: end)
    }

    private static func decodePlacement(_ readerIn: StrictObjectReader) throws -> Placement {
        var reader = readerIn
        var frameReader = try reader.object("frame")
        let x = CanvasScalar(rawValue: try frameReader.int("x"))
        let y = CanvasScalar(rawValue: try frameReader.int("y"))
        let width = CanvasScalar(rawValue: try frameReader.int("width"))
        let height = CanvasScalar(rawValue: try frameReader.int("height"))
        try frameReader.finish()
        let frame = try FixedRect(x: x, y: y, width: width, height: height)
        let scale = ScaleScalar(rawValue: try reader.int("scale"))
        let rotation = RotationScalar(rawValue: try reader.int("rotation"))
        try reader.finish()
        return try Placement(frame: frame, scale: scale, rotation: rotation)
    }

    private static func decodeSceneLayerContent(_ readerIn: StrictObjectReader, path: String) throws -> SceneLayerContent {
        var reader = readerIn
        let typeTag = try reader.string("type")
        switch typeTag {
        case "video":
            let binding = try decodeVideoBinding(try reader.object("video"))
            try reader.finish()
            return .video(binding)
        case "image":
            let image = try ImageReference(try reader.string("image"))
            try reader.finish()
            return .image(image)
        default:
            throw ProjectDecodingError.unknownEnumTag(path: "\(path).type", tag: typeTag)
        }
    }

    private static func decodeVideoBinding(_ readerIn: StrictObjectReader) throws -> VideoBinding {
        var reader = readerIn
        let media = try MediaReference(try reader.string("media"))
        let mapping = try decodeSourceMapping(try reader.object("sourceMapping"))
        try reader.finish()
        return VideoBinding(media: media, sourceMapping: mapping)
    }

    private static func decodeSourceMapping(_ readerIn: StrictObjectReader) throws -> SourceTimeMapping {
        var reader = readerIn
        var trimReader = try reader.object("trimRange")
        let start = try decodeRationalSourceTime(try trimReader.object("start"))
        let end = try decodeRationalSourceTime(try trimReader.object("end"))
        try trimReader.finish()
        let trim = try RationalSourceRange(start: start, end: end)
        let timescale = try SourceTimescale(unitsPerSecond: try reader.int("nativeTimescale"))
        var rateReader = try reader.object("rate")
        let rate = try PlaybackRate(
            numerator: try rateReader.int("numerator"),
            denominator: try rateReader.int("denominator")
        )
        try rateReader.finish()
        try reader.finish()
        return SourceTimeMapping(trimRange: trim, nativeTimescale: timescale, rate: rate)
    }

    private static func decodeRationalSourceTime(_ readerIn: StrictObjectReader) throws -> RationalSourceTime {
        var reader = readerIn
        let numerator = try reader.int("numerator")
        let denominator = try reader.int("denominator")
        try reader.finish()
        return try RationalSourceTime(numerator: numerator, denominator: denominator)
    }

    // MARK: - Animation

    private static func decodeOptionalAnimation(_ readerIn: StrictObjectReader?) throws -> AnimationReference? {
        guard var reader = readerIn else { return nil }
        let variantID = try reader.string("variantID")
        let animationRef = try reader.string("animationRef")
        let authored = try TickDuration(ticks: try reader.int("authoredDuration"))
        let ifShorter = try decodeShorterPolicy(try reader.string("ifShorter"), path: reader.path)
        let ifLonger = try decodeLongerPolicy(try reader.string("ifLonger"), path: reader.path)
        try reader.finish()
        return try AnimationReference(
            variantID: variantID, animationRef: animationRef, authoredDuration: authored,
            ifShorter: ifShorter, ifLonger: ifLonger
        )
    }

    private static func decodeShorterPolicy(_ tag: String, path: String) throws -> AnimationShorterPolicy {
        switch tag {
        case "holdLast": return .holdLast
        case "loop": return .loop
        case "becomeInactive": return .becomeInactive
        default: throw ProjectDecodingError.unknownEnumTag(path: "\(path).ifShorter", tag: tag)
        }
    }

    private static func decodeLongerPolicy(_ tag: String, path: String) throws -> AnimationLongerPolicy {
        switch tag {
        case "cutAtEvaluationEnd": return .cutAtEvaluationEnd
        default: throw ProjectDecodingError.unknownEnumTag(path: "\(path).ifLonger", tag: tag)
        }
    }

    // MARK: - Overlay payloads

    private static func decodeOverlayPayload(_ value: StrictJSONValue, path: String) throws -> ResolvedOverlayPayload {
        var reader = try StrictObjectReader(value, path: path)
        let payloadID = try OverlayPayloadID(try reader.string("payloadID"))
        let overlayID = try OverlayID(try reader.string("overlayID"))
        let content = try decodeOverlayContent(try reader.object("content"), path: "\(path).content")
        let placement = try decodePlacement(try reader.object("placement"))
        let animation = try decodeOptionalAnimation(try reader.optionalObject("animation"))
        try reader.finish()
        return ResolvedOverlayPayload(
            payloadID: payloadID, overlayID: overlayID, content: content,
            placement: placement, animation: animation
        )
    }

    private static func decodeOverlayContent(_ readerIn: StrictObjectReader, path: String) throws -> OverlayContent {
        var reader = readerIn
        let typeTag = try reader.string("type")
        switch typeTag {
        case "text":
            let text = try TextContentReference(try reader.string("text"))
            try reader.finish()
            return .text(text)
        case "sticker":
            let image = try ImageReference(try reader.string("image"))
            try reader.finish()
            return .sticker(image)
        case "graphic":
            let image = try ImageReference(try reader.string("image"))
            try reader.finish()
            return .graphic(image)
        default:
            throw ProjectDecodingError.unknownEnumTag(path: "\(path).type", tag: typeTag)
        }
    }
}
