import Foundation

// MARK: - Timeline Time Model (Time Refactor PR)

/// Microseconds as the canonical time unit for timeline.
/// 1 second = 1_000_000 microseconds.
public typealias TimeUs = Int64

/// Microseconds per second constant.
public let US_PER_SEC: Double = 1_000_000.0

// MARK: - Conversion Utilities

/// Converts microseconds to seconds.
/// - Parameter us: Time in microseconds
/// - Returns: Time in seconds
public func usToSeconds(_ us: TimeUs) -> Double {
    Double(us) / US_PER_SEC
}

/// Converts seconds to microseconds.
/// P1-2: Uses rounding to avoid systematic truncation errors.
/// - Parameter seconds: Time in seconds
/// - Returns: Time in microseconds
public func secondsToUs(_ seconds: Double) -> TimeUs {
    TimeUs((seconds * US_PER_SEC).rounded())
}

/// Converts frame index to microseconds.
/// - Parameters:
///   - frame: Frame index (0-based)
///   - fps: Frames per second
/// - Returns: Time in microseconds
public func frameToUs(_ frame: Int, fps: Int) -> TimeUs {
    guard fps > 0 else { return 0 }
    return TimeUs(frame) * 1_000_000 / TimeUs(fps)
}

/// Converts frames count to duration in microseconds.
/// - Parameters:
///   - totalFrames: Total number of frames
///   - fps: Frames per second
/// - Returns: Duration in microseconds
public func framesToDurationUs(_ totalFrames: Int, fps: Int) -> TimeUs {
    guard fps > 0 else { return 0 }
    return TimeUs(totalFrames) * 1_000_000 / TimeUs(fps)
}

// MARK: - Quantize Mode

/// Determines how time is quantized to frame index.
/// - `dragging`: Use floor for stable feedback during drag (no jitter)
/// - `ended`: Use round for snap-to-nearest on gesture end
/// - `playback`: Use floor (frame comes from playback engine)
public enum QuantizeMode: Equatable, Sendable {
    case dragging
    case ended
    case playback
}

// MARK: - Quantize Function

/// Quantizes time to frame index based on mode.
/// - Parameters:
///   - timeUs: Time in microseconds
///   - fps: Frames per second
///   - mode: Quantize mode determining rounding behavior
/// - Returns: Frame index (0-based)
public func quantizeFrame(timeUs: TimeUs, fps: Int, mode: QuantizeMode) -> Int {
    guard fps > 0 else { return 0 }

    let timeSeconds = usToSeconds(timeUs)
    let exactFrame = timeSeconds * Double(fps)

    switch mode {
    case .dragging, .playback:
        // floor for stable feedback during drag and playback
        return max(0, Int(floor(exactFrame)))
    case .ended:
        // round for snap-to-nearest on gesture end
        return max(0, Int(round(exactFrame)))
    }
}

/// Clamps time to valid range [0, maxUs].
/// - Parameters:
///   - timeUs: Time in microseconds
///   - maxUs: Maximum allowed time in microseconds
/// - Returns: Clamped time
public func clampTimeUs(_ timeUs: TimeUs, maxUs: TimeUs) -> TimeUs {
    max(0, min(timeUs, maxUs))
}

/// Clamps frame to valid range [0, maxFrame].
/// - Parameters:
///   - frame: Frame index
///   - totalFrames: Total number of frames (maxFrame = totalFrames - 1)
/// - Returns: Clamped frame index
public func clampFrame(_ frame: Int, totalFrames: Int) -> Int {
    max(0, min(frame, max(0, totalFrames - 1)))
}
