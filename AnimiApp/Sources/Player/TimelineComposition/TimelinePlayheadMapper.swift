import Foundation
import UIKit

// MARK: - Timeline Playhead Mapper

/// Bidirectional mapping between nominal frames and compressed frames.
/// Built as a wrapper over TimelineTransitionMath using zone-table model.
///
/// Zone model:
/// - Each scene has up to 3 zones: incoming, body, outgoing
/// - Transition zones (incoming/outgoing) use 1:1 mapping
/// - Body zones absorb compression from incoming transition
///
/// Key invariant: boundary nominal = boundary compressed (visual boundary preserved)
public struct TimelinePlayheadMapper: Sendable {

    // MARK: - Types

    /// Zone kind determines mapping behavior.
    private enum ZoneKind: Equatable {
        case identity   // 1:1 mapping (transition zones)
        case scaled     // compressed mapping (body zones)
    }

    /// A mapping zone within the timeline.
    private struct MappingZone: Equatable {
        let nominalStartFrame: Int
        let nominalLength: Int
        let compressedStartFrame: Int
        let compressedLength: Int
        let kind: ZoneKind
        let sceneIndex: Int

        var nominalEndFrame: Int { nominalStartFrame + nominalLength }
        var compressedEndFrame: Int { compressedStartFrame + compressedLength }

        /// Maps nominal frame to compressed frame within this zone.
        /// - Parameters:
        ///   - offset: Offset within the zone (0-based)
        ///   - quantize: Quantize mode for scaled zones (floor for .dragging/.playback, round for .ended)
        func compressedFrame(forNominalOffset offset: Int, quantize: QuantizeMode) -> Int {
            switch kind {
            case .identity:
                return compressedStartFrame + offset
            case .scaled:
                // Scale: compressed = offset * (compressedLength / nominalLength)
                guard nominalLength > 0 else { return compressedStartFrame }
                let ratio = Double(compressedLength) / Double(nominalLength)
                let rawValue = Double(offset) * ratio
                // Apply quantize mode: floor for .dragging/.playback, round for .ended
                switch quantize {
                case .dragging, .playback:
                    return compressedStartFrame + Int(rawValue)
                case .ended:
                    return compressedStartFrame + Int(rawValue.rounded())
                }
            }
        }

        /// Maps compressed frame to nominal frame within this zone.
        func nominalFrame(forCompressedOffset offset: Int) -> Int {
            switch kind {
            case .identity:
                return nominalStartFrame + offset
            case .scaled:
                // Inverse scale: nominal = offset * (nominalLength / compressedLength)
                guard compressedLength > 0 else { return nominalStartFrame }
                let ratio = Double(nominalLength) / Double(compressedLength)
                return nominalStartFrame + Int((Double(offset) * ratio).rounded())
            }
        }
    }

    // MARK: - Properties

    private let math: TimelineTransitionMath
    private let zones: [MappingZone]
    private let _nominalDurationFrames: Int
    private let _compressedDurationFrames: Int

    // MARK: - Initialization

    public init(math: TimelineTransitionMath) {
        self.math = math
        self.zones = Self.buildZones(from: math)
        self._nominalDurationFrames = math.sceneItems.reduce(0) { $0 + math.durationFrames(for: $1) }
        self._compressedDurationFrames = math.compressedDurationFrames
    }

    /// Empty mapper for fallback (returns 0 for all mappings).
    public static var empty: TimelinePlayheadMapper {
        TimelinePlayheadMapper(math: TimelineTransitionMath(sceneItems: [], boundaryTransitions: [:], fps: 30))
    }

    // MARK: - Public Properties

    /// Total duration in compressed frames.
    public var compressedDurationFrames: Int { _compressedDurationFrames }

    /// Total duration in nominal frames.
    public var nominalDurationFrames: Int { _nominalDurationFrames }

    // MARK: - Frame Mapping

    /// Maps nominal frame to compressed frame with quantize mode applied.
    /// - Parameters:
    ///   - nominal: Nominal frame index
    ///   - quantize: Quantize mode (determines rounding behavior)
    /// - Returns: Compressed frame index
    public func compressedFrame(forNominalFrame nominal: Int, quantize: QuantizeMode) -> Int {
        // Clamp to valid range
        let clampedNominal = max(0, min(nominal, _nominalDurationFrames - 1))

        // Find zone containing this nominal frame
        guard let zone = zones.first(where: {
            clampedNominal >= $0.nominalStartFrame && clampedNominal < $0.nominalEndFrame
        }) else {
            // Fallback: last frame
            return max(0, _compressedDurationFrames - 1)
        }

        let offset = clampedNominal - zone.nominalStartFrame
        let compressed = zone.compressedFrame(forNominalOffset: offset, quantize: quantize)

        return clampFrame(compressed, totalFrames: _compressedDurationFrames)
    }

    /// Maps compressed frame to nominal frame.
    /// Uses rounding for inverse mapping in scaled zones.
    /// - Parameter compressed: Compressed frame index
    /// - Returns: Nominal frame index
    public func nominalFrame(forCompressedFrame compressed: Int) -> Int {
        // Clamp to valid range
        let clampedCompressed = max(0, min(compressed, _compressedDurationFrames - 1))

        // Find zone containing this compressed frame
        guard let zone = zones.first(where: {
            clampedCompressed >= $0.compressedStartFrame && clampedCompressed < $0.compressedEndFrame
        }) else {
            // Fallback: last frame
            return max(0, _nominalDurationFrames - 1)
        }

        let offset = clampedCompressed - zone.compressedStartFrame
        let nominal = zone.nominalFrame(forCompressedOffset: offset)

        return clampFrame(nominal, totalFrames: _nominalDurationFrames)
    }

    // MARK: - TimeUs Mapping

    /// Maps time in microseconds to compressed frame with quantize mode.
    /// - Parameters:
    ///   - timeUs: Time in microseconds
    ///   - quantize: Quantize mode (floor for dragging, round for ended)
    /// - Returns: Compressed frame index
    public func compressedFrame(forTimeUs timeUs: TimeUs, quantize: QuantizeMode) -> Int {
        // Convert timeUs to nominal frame using quantize
        let nominalFrame = quantizeFrame(timeUs: timeUs, fps: math.fps, mode: quantize)
        // Then map to compressed
        return compressedFrame(forNominalFrame: nominalFrame, quantize: quantize)
    }

    /// Maps compressed frame to nominal time in microseconds.
    /// - Parameter compressed: Compressed frame index
    /// - Returns: Time in microseconds (nominal timeline)
    public func nominalTimeUs(forCompressedFrame compressed: Int) -> TimeUs {
        let nominal = nominalFrame(forCompressedFrame: compressed)
        return frameToUs(nominal, fps: math.fps)
    }

    // MARK: - UI Offset Mapping

    /// Maps UI scroll offset to compressed frame.
    /// offsetX = scrollView.contentOffset.x (time under playhead in pixels)
    /// - Parameters:
    ///   - offsetX: Scroll offset in pixels
    ///   - pxPerSecond: Pixels per second (zoom level)
    ///   - quantize: Quantize mode
    /// - Returns: Compressed frame index
    public func compressedFrame(
        forOffsetX offsetX: CGFloat,
        pxPerSecond: CGFloat,
        quantize: QuantizeMode
    ) -> Int {
        guard pxPerSecond > 0 else { return 0 }

        // Convert offsetX to nominal time
        let timeSeconds = Double(offsetX) / Double(pxPerSecond)
        let timeUs = secondsToUs(timeSeconds)

        return compressedFrame(forTimeUs: timeUs, quantize: quantize)
    }

    /// Maps compressed frame to UI scroll offset.
    /// Uses continuous inverse for smooth positioning.
    /// - Parameters:
    ///   - frame: Compressed frame index
    ///   - pxPerSecond: Pixels per second (zoom level)
    /// - Returns: Scroll offset in pixels
    public func offsetX(forCompressedFrame frame: Int, pxPerSecond: CGFloat) -> CGFloat {
        // Get nominal time for this compressed frame
        let nominalTimeUs = nominalTimeUs(forCompressedFrame: frame)
        let timeSeconds = usToSeconds(nominalTimeUs)

        return CGFloat(timeSeconds) * pxPerSecond
    }

    // MARK: - Scene Boundary

    /// Returns boundary-preserving compressed frame for scene start.
    /// This is the `compressedStartFrame` of the first zone belonging to the scene.
    /// Use this for scene edit entry instead of raw TTM.compressedStartFrame.
    /// - Parameter sceneIndex: Index of the scene (0-based)
    /// - Returns: Compressed frame at scene boundary
    public func sceneBoundaryCompressedFrame(forSceneAt sceneIndex: Int) -> Int {
        // Find first zone belonging to this scene
        guard let firstZone = zones.first(where: { $0.sceneIndex == sceneIndex }) else {
            // Fallback: if no zone found, return 0 (shouldn't happen with valid timeline)
            return 0
        }
        return firstZone.compressedStartFrame
    }

    // MARK: - Zone Building

    /// Builds zone table from TimelineTransitionMath.
    ///
    /// For each scene, creates up to 3 zones:
    /// 1. incoming zone (1:1) - transition half from previous scene
    /// 2. body zone (scaled) - non-transition body, compressed by incomingHalf
    /// 3. outgoing zone (1:1) - transition half to next scene
    ///
    /// Key invariant: boundary nominal = boundary compressed (visual boundary preserved)
    /// Compression is absorbed in body zone, not transition zones.
    private static func buildZones(from math: TimelineTransitionMath) -> [MappingZone] {
        guard !math.sceneItems.isEmpty else { return [] }

        var zones: [MappingZone] = []
        var nominalPosition = 0
        var compressedPosition = 0

        for sceneIndex in 0..<math.sceneItems.count {
            let sceneDuration = math.durationFrames(forSceneAt: sceneIndex)

            // Calculate incoming and outgoing transition halves
            let incomingHalf = incomingTransitionHalf(for: sceneIndex, math: math)
            let outgoingHalf = outgoingTransitionHalf(for: sceneIndex, math: math)

            // 1. Incoming zone (1:1 mapping)
            // This is the first half of transition FROM previous scene
            if incomingHalf > 0 {
                zones.append(MappingZone(
                    nominalStartFrame: nominalPosition,
                    nominalLength: incomingHalf,
                    compressedStartFrame: compressedPosition,
                    compressedLength: incomingHalf,
                    kind: .identity,
                    sceneIndex: sceneIndex
                ))
                compressedPosition += incomingHalf
            }

            // 2. Body zone (may be scaled if there's incoming transition)
            let bodyNominalLength = sceneDuration - incomingHalf - outgoingHalf
            if bodyNominalLength > 0 {
                // Compression absorbed in body = incomingHalf
                // This is where the timeline "catches up" from transition overlap
                let bodyCompressedLength = bodyNominalLength - incomingHalf

                if bodyCompressedLength > 0 {
                    zones.append(MappingZone(
                        nominalStartFrame: nominalPosition + incomingHalf,
                        nominalLength: bodyNominalLength,
                        compressedStartFrame: compressedPosition,
                        compressedLength: bodyCompressedLength,
                        kind: bodyCompressedLength == bodyNominalLength ? .identity : .scaled,
                        sceneIndex: sceneIndex
                    ))
                    compressedPosition += bodyCompressedLength
                }
            }

            // 3. Outgoing zone (1:1 mapping)
            // This is the first half of transition TO next scene
            if outgoingHalf > 0 {
                let outgoingNominalStart = nominalPosition + sceneDuration - outgoingHalf

                zones.append(MappingZone(
                    nominalStartFrame: outgoingNominalStart,
                    nominalLength: outgoingHalf,
                    compressedStartFrame: compressedPosition,
                    compressedLength: outgoingHalf,
                    kind: .identity,
                    sceneIndex: sceneIndex
                ))
                compressedPosition += outgoingHalf
            }

            // Move to next scene
            nominalPosition += sceneDuration
        }

        return zones
    }

    /// Returns incoming transition half-duration for scene at index.
    private static func incomingTransitionHalf(for sceneIndex: Int, math: TimelineTransitionMath) -> Int {
        guard sceneIndex > 0 else { return 0 } // First scene has no incoming

        let prevScene = math.sceneItems[sceneIndex - 1]
        let currentScene = math.sceneItems[sceneIndex]
        let key = SceneBoundaryKey(prevScene.id, currentScene.id)

        guard let transition = math.boundaryTransitions[key], transition.type != .none else {
            return 0
        }

        return transition.durationFrames / 2
    }

    /// Returns outgoing transition half-duration for scene at index.
    private static func outgoingTransitionHalf(for sceneIndex: Int, math: TimelineTransitionMath) -> Int {
        guard sceneIndex < math.sceneItems.count - 1 else { return 0 } // Last scene has no outgoing

        let currentScene = math.sceneItems[sceneIndex]
        let nextScene = math.sceneItems[sceneIndex + 1]
        let key = SceneBoundaryKey(currentScene.id, nextScene.id)

        guard let transition = math.boundaryTransitions[key], transition.type != .none else {
            return 0
        }

        return transition.durationFrames / 2
    }
}

// MARK: - Debug

#if DEBUG
extension TimelinePlayheadMapper {
    /// Debug description of zone table.
    public var debugZoneDescription: String {
        var lines: [String] = ["TimelinePlayheadMapper zones:"]
        for (i, zone) in zones.enumerated() {
            lines.append("  [\(i)] scene=\(zone.sceneIndex) \(zone.kind)")
            lines.append("       nominal: \(zone.nominalStartFrame)..<\(zone.nominalEndFrame) (len=\(zone.nominalLength))")
            lines.append("       compressed: \(zone.compressedStartFrame)..<\(zone.compressedEndFrame) (len=\(zone.compressedLength))")
        }
        lines.append("  Total: nominal=\(_nominalDurationFrames), compressed=\(_compressedDurationFrames)")
        return lines.joined(separator: "\n")
    }
}
#endif
