/// An ordering-agnostic canonical value tree: objects are key/value pairs sorted at emit time, so
/// construction order never affects the bytes (Task-002 plan, §11.3).
indirect enum CanonicalValue {
    case object([(String, CanonicalValue)])
    case array([CanonicalValue])
    case int(Int64)
    case string(String)
    case bool(Bool)
}

/// Writes a ``CanonicalValue`` deterministically: lexicographically sorted keys, fixed base-10
/// integers (no exponent, no trailing `.0`), and minimal escaping (Task-002 plan, §11.3).
enum CanonicalJSONWriter {
    static func write(_ value: CanonicalValue, into output: inout String) {
        switch value {
        case .object(let pairs):
            output.append("{")
            let sorted = pairs.sorted { $0.0 < $1.0 }
            for (index, pair) in sorted.enumerated() {
                if index > 0 { output.append(",") }
                writeString(pair.0, into: &output)
                output.append(":")
                write(pair.1, into: &output)
            }
            output.append("}")
        case .array(let elements):
            output.append("[")
            for (index, element) in elements.enumerated() {
                if index > 0 { output.append(",") }
                write(element, into: &output)
            }
            output.append("]")
        case .int(let number):
            output.append(String(number))
        case .string(let string):
            writeString(string, into: &output)
        case .bool(let flag):
            output.append(flag ? "true" : "false")
        }
    }

    private static func writeString(_ string: String, into output: inout String) {
        output.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\u{08}": output.append("\\b")
            case "\u{0C}": output.append("\\f")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    let padded = String(repeating: "0", count: 4 - hex.count) + hex
                    output.append("\\u" + padded)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output.append("\"")
    }
}

/// Builds the canonical value tree for a project document, mirroring the strict decode schema
/// (Task-002 plan, §11.3). Payload tables are emitted in deterministic id order.
enum CanonicalProjectValueBuilder {
    static func build(_ document: CanonicalProjectDocument) throws -> CanonicalValue {
        .object([
            ("manifest", manifest(document.manifest)),
            ("scenePayloads", .array(
                document.scenePayloads
                    .sorted { $0.payloadID.raw < $1.payloadID.raw }
                    .map(scenePayload)
            )),
            ("overlayPayloads", .array(
                document.overlayPayloads
                    .sorted { $0.payloadID.raw < $1.payloadID.raw }
                    .map(overlayPayload)
            ))
        ])
    }

    // MARK: - Manifest

    private static func manifest(_ manifest: CanonicalProjectManifest) -> CanonicalValue {
        // CP7.5 (D1): the canonical encoder always writes the CURRENT schema version (v2) and the
        // `timelineSpan` key (emitted in `sceneEntry`). The on-disk format that carries `timelineSpan`
        // IS v2, so a v1 in-memory manifest (e.g. a fixture, or a v1 doc decoded before uplift)
        // re-encodes as a consistent v2 document — never a v1 header with a v2 body.
        .object([
            ("schemaVersion", .int(Int64(CanonicalProjectManifest.supportedSchemaVersion))),
            ("output", output(manifest.output)),
            ("scenes", .array(manifest.scenes.map(sceneEntry))),
            ("boundaryTransitions", .array(manifest.boundaryTransitions.map(transition))),
            ("overlays", .array(manifest.overlays.map(overlayEntry))),
            ("audio", audio(manifest.audio))
        ])
    }

    /// Slice 001 (schema v3): the canonical encoder always writes an explicit `"audio"` object with
    /// the three required tables. **Stage C** emits the populated tables in deterministic order
    /// (input array order is non-semantic):
    /// - `sources` by `AudioSourceID`;
    /// - `tracks` by `AudioTrackID`;
    /// - `clips` by `(trackID, destination.start.ticks, AudioClipID)`.
    /// Object keys within each entry are sorted by the canonical writer.
    private static func audio(_ audio: AudioManifest) -> CanonicalValue {
        let sortedSources = audio.sources.sorted { $0.id < $1.id }
        let sortedTracks = audio.tracks.sorted { $0.id < $1.id }
        let sortedClips = audio.clips.sorted { lhs, rhs in
            if lhs.trackID != rhs.trackID { return lhs.trackID < rhs.trackID }
            if lhs.destination.start.ticks != rhs.destination.start.ticks {
                return lhs.destination.start.ticks < rhs.destination.start.ticks
            }
            return lhs.id < rhs.id
        }
        return .object([
            ("sources", .array(sortedSources.map(audioSource))),
            ("tracks", .array(sortedTracks.map(audioTrack))),
            ("clips", .array(sortedClips.map(audioClip)))
        ])
    }

    private static func audioSource(_ entry: AudioSourceEntry) -> CanonicalValue {
        .object([
            ("id", .string(entry.id.raw)),
            ("asset", audioAsset(entry.asset))
        ])
    }

    private static func audioAsset(_ asset: AudioAssetReference) -> CanonicalValue {
        switch asset {
        case .videoLayerMedia(let media):
            return .object([
                ("kind", .string("videoLayerMedia")),
                ("media", .string(media.raw))
            ])
        case .globalAudio(let assetID):
            return .object([
                ("kind", .string("globalAudio")),
                ("id", .string(assetID.raw))
            ])
        }
    }

    private static func audioTrack(_ entry: AudioTrackEntry) -> CanonicalValue {
        .object([
            ("id", .string(entry.id.raw)),
            ("role", .string(entry.role.rawValue))
        ])
    }

    private static func audioClip(_ entry: AudioClipEntry) -> CanonicalValue {
        var pairs: [(String, CanonicalValue)] = [
            ("id", .string(entry.id.raw)),
            ("trackID", .string(entry.trackID.raw)),
            ("sourceID", .string(entry.sourceID.raw)),
            ("destination", projectTimeRange(entry.destination)),
            ("sourceTrim", rationalSourceRange(entry.sourceTrim)),
            ("gain", .int(entry.gain.raw)),
            ("isMuted", .bool(entry.isMuted)),
            ("playbackPolicy", .string(entry.playbackPolicy.rawValue))
        ]
        // `videoLayer` is emitted ONLY when present; absence has exactly one canonical representation
        // (the key is simply omitted — never `"videoLayer":null`).
        if let videoLayer = entry.videoLayer {
            pairs.append(("videoLayer", sceneLayerReference(videoLayer)))
        }
        return .object(pairs)
    }

    private static func sceneLayerReference(_ ref: SceneLayerReference) -> CanonicalValue {
        .object([
            ("sceneID", .string(ref.sceneID.raw)),
            ("layerID", .string(ref.layerID.raw))
        ])
    }

    private static func rationalSourceRange(_ range: RationalSourceRange) -> CanonicalValue {
        .object([
            ("start", rationalSourceTime(range.start)),
            ("end", rationalSourceTime(range.end))
        ])
    }

    private static func output(_ output: OutputContext) -> CanonicalValue {
        .object([
            ("canvas", .object([
                ("width", .int(output.canvas.width)),
                ("height", .int(output.canvas.height))
            ])),
            ("frameRate", .object([
                ("numerator", .int(output.frameRate.numerator)),
                ("denominator", .int(output.frameRate.denominator))
            ]))
        ])
    }

    private static func sceneEntry(_ entry: SceneManifestEntry) -> CanonicalValue {
        // CP7.5 (schema v2): emit `timelineSpan`. Keys are sorted lexicographically by the canonical
        // writer, so the new key lands deterministically. This changes the project canonical hash
        // for v2 documents (owner-approved D4 — does NOT affect ReferenceData render pixels).
        .object([
            ("id", .string(entry.id.raw)),
            ("payloadID", .string(entry.payloadID.raw)),
            ("nominalDuration", .int(entry.nominalDuration.ticks)),
            ("postRollCapability", .int(entry.postRollCapability.ticks)),
            ("timelineSpan", .int(entry.timelineSpan.ticks))
        ])
    }

    private static func overlayEntry(_ entry: OverlayManifestEntry) -> CanonicalValue {
        .object([
            ("id", .string(entry.id.raw)),
            ("payloadID", .string(entry.payloadID.raw)),
            ("timeRange", projectTimeRange(entry.timeRange)),
            ("zIndex", .int(Int64(entry.zIndex))),
            ("stableOrdinal", .int(Int64(entry.stableOrdinal)))
        ])
    }

    private static func projectTimeRange(_ range: ProjectTimeRange) -> CanonicalValue {
        .object([
            ("start", .int(range.start.ticks)),
            ("end", .int(range.end.ticks))
        ])
    }

    // MARK: - Transitions

    private static func transition(_ transition: SceneTransition) -> CanonicalValue {
        var pairs: [(String, CanonicalValue)] = [
            ("duration", .int(transition.duration.ticks)),
            ("easing", .string(transition.easing.raw))
        ]
        switch transition.kind {
        case .cut:
            pairs.append(("kind", .string("cut")))
        case .animated(let effect):
            pairs.append(("kind", .string("animated")))
            pairs.append(("effect", .object([
                ("effectID", .string(effect.effectID.raw)),
                // Parameters are emitted in sorted key order.
                ("parameters", .array(effect.parameters.sortedUniqueParameters.map(transitionParameter)))
            ])))
        }
        return .object(pairs)
    }

    private static func transitionParameter(_ parameter: TransitionParameter) -> CanonicalValue {
        var pairs: [(String, CanonicalValue)] = [("key", .string(parameter.key))]
        switch parameter.value {
        case .integer(let v):
            pairs.append(("type", .string("integer")))
            pairs.append(("value", .int(v)))
        case .fixed(let v):
            pairs.append(("type", .string("fixed")))
            pairs.append(("value", .int(v.rawValue)))
        case .identifier(let v):
            pairs.append(("type", .string("identifier")))
            pairs.append(("value", .string(v)))
        case .boolean(let v):
            pairs.append(("type", .string("boolean")))
            pairs.append(("value", .bool(v)))
        }
        return .object(pairs)
    }

    // MARK: - Scene payloads

    private static func scenePayload(_ payload: ResolvedScenePayload) -> CanonicalValue {
        .object([
            ("payloadID", .string(payload.payloadID.raw)),
            ("sceneID", .string(payload.sceneID.raw)),
            ("templateRef", .object([
                ("catalogID", .string(payload.templateRef.catalogID)),
                ("sceneID", .string(payload.templateRef.sceneID))
            ])),
            ("layers", .array(payload.layers.map(sceneLayer)))
        ])
    }

    private static func sceneLayer(_ layer: SceneLayer) -> CanonicalValue {
        var pairs: [(String, CanonicalValue)] = [
            ("id", .string(layer.id.raw)),
            ("zIndex", .int(Int64(layer.zIndex))),
            ("stableOrdinal", .int(Int64(layer.stableOrdinal))),
            ("activeRange", scenePlaybackRange(layer.activeRange)),
            ("placement", placement(layer.placement)),
            ("mediaPlacement", mediaPlacement(layer.mediaPlacement)),
            ("content", sceneLayerContent(layer.content))
        ]
        if let animation = layer.animation {
            pairs.append(("animation", animationReference(animation)))
        }
        return .object(pairs)
    }

    private static func scenePlaybackRange(_ range: ScenePlaybackRange) -> CanonicalValue {
        .object([
            ("start", .int(range.start.ticks)),
            ("end", .int(range.end.ticks))
        ])
    }

    private static func placement(_ placement: Placement) -> CanonicalValue {
        .object([
            ("frame", .object([
                ("x", .int(placement.frame.x.rawValue)),
                ("y", .int(placement.frame.y.rawValue)),
                ("width", .int(placement.frame.width.rawValue)),
                ("height", .int(placement.frame.height.rawValue))
            ])),
            ("scale", .int(placement.scale.rawValue)),
            ("rotation", .int(placement.rotation.rawValue))
        ])
    }

    private static func mediaPlacement(_ media: MediaPlacement) -> CanonicalValue {
        .object([
            ("fitMode", .string(media.fitMode.rawValue)),
            ("userOffsetX", .int(media.userOffsetX.rawValue)),
            ("userOffsetY", .int(media.userOffsetY.rawValue)),
            ("userScale", .int(media.userScale.rawValue)),
            ("userRotation", .int(media.userRotation.rawValue))
        ])
    }

    private static func sceneLayerContent(_ content: SceneLayerContent) -> CanonicalValue {
        switch content {
        case .video(let binding):
            return .object([
                ("type", .string("video")),
                ("video", videoBinding(binding))
            ])
        case .image(let image):
            return .object([
                ("type", .string("image")),
                ("image", .string(image.raw))
            ])
        }
    }

    private static func videoBinding(_ binding: VideoBinding) -> CanonicalValue {
        .object([
            ("media", .string(binding.media.raw)),
            ("sourceMapping", sourceMapping(binding.sourceMapping))
        ])
    }

    private static func sourceMapping(_ mapping: SourceTimeMapping) -> CanonicalValue {
        .object([
            ("trimRange", .object([
                ("start", rationalSourceTime(mapping.trimRange.start)),
                ("end", rationalSourceTime(mapping.trimRange.end))
            ])),
            ("nativeTimescale", .int(mapping.nativeTimescale.unitsPerSecond)),
            ("rate", .object([
                ("numerator", .int(mapping.rate.numerator)),
                ("denominator", .int(mapping.rate.denominator))
            ]))
        ])
    }

    private static func rationalSourceTime(_ time: RationalSourceTime) -> CanonicalValue {
        .object([
            ("numerator", .int(time.numerator)),
            ("denominator", .int(time.denominator))
        ])
    }

    private static func animationReference(_ animation: AnimationReference) -> CanonicalValue {
        .object([
            ("variantID", .string(animation.variantID)),
            ("animationRef", .string(animation.animationRef)),
            ("authoredDuration", .int(animation.authoredDuration.ticks)),
            ("ifShorter", .string(shorterTag(animation.ifShorter))),
            ("ifLonger", .string(longerTag(animation.ifLonger)))
        ])
    }

    private static func shorterTag(_ policy: AnimationShorterPolicy) -> String {
        switch policy {
        case .holdLast: return "holdLast"
        case .loop: return "loop"
        case .becomeInactive: return "becomeInactive"
        }
    }

    private static func longerTag(_ policy: AnimationLongerPolicy) -> String {
        switch policy {
        case .cutAtEvaluationEnd: return "cutAtEvaluationEnd"
        }
    }

    // MARK: - Overlay payloads

    private static func overlayPayload(_ payload: ResolvedOverlayPayload) -> CanonicalValue {
        var pairs: [(String, CanonicalValue)] = [
            ("payloadID", .string(payload.payloadID.raw)),
            ("overlayID", .string(payload.overlayID.raw)),
            ("content", overlayContent(payload.content)),
            ("placement", placement(payload.placement))
        ]
        if let animation = payload.animation {
            pairs.append(("animation", animationReference(animation)))
        }
        return .object(pairs)
    }

    private static func overlayContent(_ content: OverlayContent) -> CanonicalValue {
        switch content {
        case .text(let text):
            return .object([("type", .string("text")), ("text", .string(text.raw))])
        case .sticker(let image):
            return .object([("type", .string("sticker")), ("image", .string(image.raw))])
        case .graphic(let image):
            return .object([("type", .string("graphic")), ("image", .string(image.raw))])
        }
    }
}
