import UIKit

// MARK: - Time Ruler View (PR2, PR3: Reorder toggle)

/// Displays time markers (seconds) synchronized with timeline scroll/zoom.
/// Draws programmatically based on contentOffset from TimelineView.
/// Does NOT use UIScrollView - renders based on external offset.
/// PR3: Includes reorder mode toggle button on the right side.
final class TimeRulerView: UIView {

    // MARK: - Callbacks (PR3)

    /// Called when reorder mode toggle is changed.
    var onReorderModeChanged: ((Bool) -> Void)?

    // MARK: - Configuration

    /// Duration in microseconds (source of truth).
    private var durationUs: TimeUs = 0

    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var contentOffsetX: CGFloat = 0

    // MARK: - Reorder Mode (PR3)

    private var isReorderMode: Bool = false

    private lazy var reorderToggle: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.filled()
        config.title = "Reorder"
        config.baseForegroundColor = .label
        config.baseBackgroundColor = .tertiarySystemFill
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 11, weight: .medium)
            return outgoing
        }
        button.configuration = config
        button.addTarget(self, action: #selector(reorderToggleTapped), for: .touchUpInside)
        return button
    }()

    // MARK: - Appearance

    private let tickColor: UIColor = .secondaryLabel
    private let labelColor: UIColor = .label
    private let labelFont: UIFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemBackground
        setupReorderToggle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupReorderToggle() {
        addSubview(reorderToggle)
        NSLayoutConstraint.activate([
            reorderToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            reorderToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func reorderToggleTapped() {
        isReorderMode.toggle()
        updateReorderToggleAppearance()
        onReorderModeChanged?(isReorderMode)
    }

    private func updateReorderToggleAppearance() {
        var config = reorderToggle.configuration ?? UIButton.Configuration.filled()
        if isReorderMode {
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .white
        } else {
            config.baseBackgroundColor = .tertiarySystemFill
            config.baseForegroundColor = .label
        }
        reorderToggle.configuration = config
    }

    // MARK: - Configuration

    /// Configures ruler with duration in microseconds.
    /// - Parameter durationUs: Duration in microseconds
    func configure(durationUs: TimeUs) {
        self.durationUs = durationUs
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

    // MARK: - Drawing (PR2.4 Optimized, Time Refactor)

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        guard durationUs > 0, pxPerSecond > 0 else { return }

        let durationSeconds = CGFloat(usToSeconds(durationUs))

        // Playhead model: playhead is fixed at center of view.
        // Position of time T in ruler coordinates: x = startX + T * pxPerSecond
        let centerX = bounds.width / 2
        let startX = centerX - contentOffsetX // position of time 0 in ruler

        // PR2.4 A) Calculate visible time range (with margin for smooth edges)
        let margin = bounds.width // 1 screen margin
        let visibleStartTime = max(0, (-margin - startX) / pxPerSecond)
        let visibleEndTime = min(durationSeconds, (bounds.width + margin - startX) / pxPerSecond)

        guard visibleStartTime < visibleEndTime else { return }

        // Tick intervals
        let tickInterval = calculateTickInterval()
        let majorInterval = calculateMajorInterval()

        context.setStrokeColor(tickColor.cgColor)
        context.setLineWidth(1)

        // PR2.4 B) Minor ticks by index (no float accumulation)
        let tickIndexStart = Int(floor(visibleStartTime / tickInterval))
        let tickIndexEnd = Int(ceil(visibleEndTime / tickInterval))

        for tickIndex in tickIndexStart...tickIndexEnd {
            let t = CGFloat(tickIndex) * tickInterval
            guard t >= 0 && t <= durationSeconds else { continue }

            let x = startX + t * pxPerSecond
            let tickHeight: CGFloat = 6 // minor tick height

            context.move(to: CGPoint(x: x, y: bounds.height))
            context.addLine(to: CGPoint(x: x, y: bounds.height - tickHeight))
            context.strokePath()
        }

        // PR2.4 C) Major ticks + labels on whole seconds only
        let secStart = max(0, Int(ceil(visibleStartTime)))
        let secEnd = min(Int(durationSeconds), Int(floor(visibleEndTime)))

        var sec = secStart - (secStart % majorInterval) // align to majorInterval
        if sec < secStart { sec += majorInterval }

        while sec <= secEnd {
            let t = CGFloat(sec)
            let x = startX + t * pxPerSecond

            // Draw major tick (taller)
            let majorTickHeight: CGFloat = 12
            context.move(to: CGPoint(x: x, y: bounds.height))
            context.addLine(to: CGPoint(x: x, y: bounds.height - majorTickHeight))
            context.strokePath()

            // Draw label
            drawTimeLabel(at: x, timeSeconds: sec)

            sec += majorInterval
        }
    }

    private func calculateTickInterval() -> CGFloat {
        // Minor tick interval based on zoom level
        if pxPerSecond >= 60 {
            return 0.25 // quarter seconds
        } else if pxPerSecond >= 30 {
            return 0.5 // half seconds
        } else {
            return 1.0 // 1 second
        }
    }

    private func calculateMajorInterval() -> Int {
        // PR2.4: Major ticks on whole seconds only
        if pxPerSecond >= 120 {
            return 1 // every 1 second
        } else if pxPerSecond >= 60 {
            return 5 // every 5 seconds
        } else {
            return 10 // every 10 seconds
        }
    }

    private func drawTimeLabel(at x: CGFloat, timeSeconds: Int) {
        let minutes = timeSeconds / 60
        let seconds = timeSeconds % 60
        let text = String(format: "%d:%02d", minutes, seconds)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor
        ]

        let size = text.size(withAttributes: attributes)
        let labelX = x - size.width / 2
        let labelY: CGFloat = 4

        // PR3.1: Don't draw labels that would overlap with reorder toggle button
        let buttonAreaStart = bounds.width - 80 // button width (~60) + padding
        if labelX + size.width > buttonAreaStart {
            return
        }

        text.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)
    }
}
