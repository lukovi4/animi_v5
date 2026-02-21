import UIKit

// MARK: - Time Ruler View (PR2)

/// Displays time markers (seconds) synchronized with timeline scroll/zoom.
/// Draws programmatically based on contentOffset from TimelineView.
/// Does NOT use UIScrollView - renders based on external offset.
final class TimeRulerView: UIView {

    // MARK: - Configuration

    private var durationFrames: Int = 0
    private var fps: Int = 30
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var contentOffsetX: CGFloat = 0

    // MARK: - Appearance

    private let tickColor: UIColor = .secondaryLabel
    private let labelColor: UIColor = .label
    private let labelFont: UIFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemBackground
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    /// Configures ruler with duration and FPS.
    func configure(durationFrames: Int, fps: Int) {
        self.durationFrames = durationFrames
        self.fps = fps > 0 ? fps : 30
        setNeedsDisplay()
    }

    /// Updates content offset (called when timeline scrolls).
    func setContentOffset(_ offset: CGPoint) {
        contentOffsetX = offset.x
        setNeedsDisplay()
    }

    /// Updates pixels per second (called when timeline zooms).
    func setPxPerSecond(_ pxPerSec: CGFloat) {
        pxPerSecond = pxPerSec
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard durationFrames > 0, fps > 0 else { return }

        let durationSeconds = CGFloat(durationFrames) / CGFloat(fps)

        // Playhead model: playhead is fixed at center of view.
        // Timeline uses contentInset where padding = bounds.width/2.
        // contentOffsetX = -padding when frame 0 is under playhead.
        //
        // Position of time T in ruler coordinates:
        // x = T * pxPerSecond - contentOffsetX
        //
        // When contentOffsetX = -padding = -centerX:
        //   x(T=0) = 0 - (-centerX) = centerX ✓ (time 0 at playhead)
        let startX = -contentOffsetX // position of time 0 in ruler

        // Determine tick interval based on zoom level
        let tickInterval = calculateTickInterval()
        let majorTickInterval = tickInterval * 5

        // Draw ticks
        context.setStrokeColor(tickColor.cgColor)
        context.setLineWidth(1)

        var time: CGFloat = 0
        while time <= durationSeconds {
            let x = startX + time * pxPerSecond

            // Only draw if visible
            if x >= -20 && x <= bounds.width + 20 {
                let isMajor = time.truncatingRemainder(dividingBy: majorTickInterval) < 0.001
                let tickHeight: CGFloat = isMajor ? 12 : 6

                context.move(to: CGPoint(x: x, y: bounds.height))
                context.addLine(to: CGPoint(x: x, y: bounds.height - tickHeight))
                context.strokePath()

                // Draw label for major ticks
                if isMajor {
                    drawTimeLabel(at: x, time: time, context: context)
                }
            }

            time += tickInterval
        }
    }

    private func calculateTickInterval() -> CGFloat {
        // Adjust tick interval based on zoom level
        // More zoom = more detail (smaller intervals)
        let baseInterval: CGFloat = 1.0 // 1 second base

        if pxPerSecond >= 60 {
            return 0.25 // quarter seconds
        } else if pxPerSecond >= 30 {
            return 0.5 // half seconds
        } else {
            return baseInterval
        }
    }

    private func drawTimeLabel(at x: CGFloat, time: CGFloat, context: CGContext) {
        let timeInt = Int(time)
        let minutes = timeInt / 60
        let seconds = timeInt % 60
        let text = String(format: "%d:%02d", minutes, seconds)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor
        ]

        let size = text.size(withAttributes: attributes)
        let labelX = x - size.width / 2
        let labelY: CGFloat = 4

        text.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)
    }
}
