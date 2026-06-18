/// The sample-selection policy for a source request (Task-002 plan, §4.2).
///
/// v1 always selects the presentation interval that contains the exact target. Actual sample-table
/// lookup is deferred to a later media-boundary layer; Task 002 only emits the request.
public enum SampleSelectionPolicy: Equatable, Sendable {
    case presentationIntervalContainsTarget
}

/// An exact, render-ready request for a single source sample (Task-002 plan, §4.2).
///
/// The target is an exact normalized ``RationalSourceTime``; it is never rounded onto the native
/// timescale and never clamped to the trim range.
public struct SourceRequest: Equatable, Sendable {
    public let media: MediaReference
    public let target: RationalSourceTime
    public let selection: SampleSelectionPolicy

    public init(media: MediaReference, target: RationalSourceTime, selection: SampleSelectionPolicy) {
        self.media = media
        self.target = target
        self.selection = selection
    }
}
