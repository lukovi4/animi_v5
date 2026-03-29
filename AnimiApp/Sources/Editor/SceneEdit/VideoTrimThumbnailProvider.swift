import UIKit
import AVFoundation

// MARK: - Video Trim Thumbnail Provider

/// Generates filmstrip thumbnails from a video URL using AVAssetImageGenerator.
/// Used by VideoTrimFilmstripView to populate the thumbnail strip.
@MainActor
final class VideoTrimThumbnailProvider {

    // MARK: - Configuration

    /// Thumbnail size in points (height matches filmstrip row height).
    static let thumbnailHeight: CGFloat = 56

    // MARK: - Properties

    private let asset: AVAsset
    private let duration: Double
    private var generator: AVAssetImageGenerator?
    private var generationTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a thumbnail provider for the given video URL.
    /// - Parameters:
    ///   - url: Video file URL
    ///   - duration: Actual video duration in seconds
    init(url: URL, duration: Double) {
        self.asset = AVAsset(url: url)
        self.duration = duration
    }

    // MARK: - Public API

    /// Generates evenly-spaced thumbnails across the full video duration.
    /// - Parameters:
    ///   - count: Number of thumbnails to generate
    ///   - size: Target thumbnail size in points
    ///   - completion: Called on main thread with array of (time, image) pairs
    func generateThumbnails(
        count: Int,
        size: CGSize,
        completion: @escaping ([(time: Double, image: UIImage)]) -> Void
    ) {
        cancel()

        guard count > 0, duration > 0 else {
            completion([])
            return
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size.width * UIScreen.main.scale,
                                 height: size.height * UIScreen.main.scale)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        self.generator = gen

        let interval = duration / Double(count)
        let times: [NSValue] = (0..<count).map { i in
            let t = interval * Double(i) + interval / 2.0
            return NSValue(time: CMTime(seconds: min(t, duration), preferredTimescale: 600))
        }

        generationTask = Task { [weak self] in
            var results: [(time: Double, image: UIImage)] = []

            await withCheckedContinuation { continuation in
                var completed = 0
                gen.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cgImage, _, _, _ in
                    let time = requestedTime.seconds
                    if let cgImage {
                        let image = UIImage(cgImage: cgImage)
                        results.append((time: time, image: image))
                    }
                    completed += 1
                    if completed >= count {
                        continuation.resume()
                    }
                }
            }

            guard !Task.isCancelled else { return }

            // Sort by time for consistent ordering
            results.sort { $0.time < $1.time }
            completion(results)
        }
    }

    /// Cancels any in-flight thumbnail generation.
    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        generator?.cancelAllCGImageGeneration()
        generator = nil
    }

    deinit {
        generator?.cancelAllCGImageGeneration()
    }
}
