import AVFoundation

/// Abstracts AVAssetWriterInput for pump scheduling and testing.
protocol WriterInputScheduling: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
    func markAsFinished()
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool
}

/// Abstracts AVAssetWriterInputPixelBufferAdaptor for testing.
protocol PixelBufferAppending: AnyObject {
    func append(_ pixelBuffer: CVPixelBuffer, withPresentationTime: CMTime) -> Bool
}

// AVFoundation conformances (all methods already exist)
extension AVAssetWriterInput: WriterInputScheduling {}
extension AVAssetWriterInputPixelBufferAdaptor: PixelBufferAppending {}
