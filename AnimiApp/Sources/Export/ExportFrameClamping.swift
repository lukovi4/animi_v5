import TVECore

enum ExportFrameClamping {
    static func sceneFrame(_ frame: Int, nativeDurationFrames: Int) -> Int {
        let maxFrame = max(0, nativeDurationFrames - 1)
        return min(max(frame, 0), maxFrame)
    }
}
