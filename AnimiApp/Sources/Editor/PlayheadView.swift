import UIKit

// MARK: - Playhead View (PR2)

/// Vertical line overlay indicating current playback position.
/// Stays fixed at center X while timeline scrolls underneath.
/// Spans across ruler and timeline (set by constraints in parent).
final class PlayheadView: UIView {

    // MARK: - Appearance

    private let lineColor: UIColor = .systemRed
    private let topIndicatorSize: CGFloat = 10

    // MARK: - Subviews

    private lazy var lineLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = lineColor.cgColor
        return layer
    }()

    private lazy var topIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = lineColor
        view.layer.cornerRadius = topIndicatorSize / 2
        return view
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear
        isUserInteractionEnabled = false

        layer.addSublayer(lineLayer)
        addSubview(topIndicator)

        NSLayoutConstraint.activate([
            topIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            topIndicator.topAnchor.constraint(equalTo: topAnchor),
            topIndicator.widthAnchor.constraint(equalToConstant: topIndicatorSize),
            topIndicator.heightAnchor.constraint(equalToConstant: topIndicatorSize),
        ])
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        updateLineLayer()
    }

    private func updateLineLayer() {
        let path = UIBezierPath()
        let centerX = bounds.width / 2

        // Line from below top indicator to bottom
        path.move(to: CGPoint(x: centerX, y: topIndicatorSize))
        path.addLine(to: CGPoint(x: centerX, y: bounds.height))

        lineLayer.path = path.cgPath
        lineLayer.strokeColor = lineColor.cgColor
        lineLayer.lineWidth = 2
        lineLayer.fillColor = nil
    }
}
