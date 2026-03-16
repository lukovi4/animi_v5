import UIKit

// MARK: - Transition Boundary View (PR-G)

/// Control displayed at scene boundaries for editing transitions.
/// Tap to open transition picker.
final class TransitionBoundaryView: UIControl {

    // MARK: - Properties

    /// ID of the outgoing scene (scene A).
    let fromSceneId: UUID

    /// ID of the incoming scene (scene B).
    let toSceneId: UUID

    /// Current transition for this boundary.
    private(set) var transition: SceneTransition = .none

    /// Visual size of the badge (20x20).
    static let visualSize: CGFloat = 20

    // MARK: - Views

    private let badgeView: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 4
        view.isUserInteractionEnabled = false
        return view
    }()

    private let iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .center
        imageView.tintColor = .white
        imageView.isUserInteractionEnabled = false
        return imageView
    }()

    // MARK: - Initialization

    init(fromSceneId: UUID, toSceneId: UUID) {
        self.fromSceneId = fromSceneId
        self.toSceneId = toSceneId
        super.init(frame: .zero)
        setupViews()
        configureVisualState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        addSubview(badgeView)
        badgeView.addSubview(iconView)

        // Enable accessibility
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    // MARK: - Configuration

    /// Updates visual state based on transition.
    /// - Parameter transition: Current transition for this boundary
    func configure(transition: SceneTransition) {
        self.transition = transition
        configureVisualState()
    }

    private func configureVisualState() {
        if transition.type == .none {
            // Subdued add badge for no transition
            badgeView.backgroundColor = UIColor.systemGray5
            iconView.image = UIImage(systemName: "plus")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            )
            iconView.tintColor = .systemGray
        } else {
            // Accent badge for active transition
            badgeView.backgroundColor = UIColor.systemBlue
            iconView.image = UIImage(systemName: "arrow.left.arrow.right")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            )
            iconView.tintColor = .white
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let size = Self.visualSize
        badgeView.frame = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )

        iconView.frame = badgeView.bounds
    }

    // MARK: - Hit Testing

    /// Upward-biased hit target: ~32x32, expanded more upward to avoid trim handle conflict.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let expanded = CGRect(
            x: bounds.minX - 6,
            y: bounds.minY - 10,  // More expansion upward
            width: bounds.width + 12,
            height: bounds.height + 12
        )
        return expanded.contains(point)
    }

    // MARK: - Accessibility

    override var accessibilityLabel: String? {
        get {
            switch transition.type {
            case .none:
                return "Transition: None"
            case .fade:
                return "Transition: Fade"
            case .slide(let dir):
                return "Transition: Slide \(dir.rawValue.capitalized)"
            case .push(let dir):
                return "Transition: Push \(dir.rawValue.capitalized)"
            case .dipToBlack:
                return "Transition: Dip to Black"
            case .dipToWhite:
                return "Transition: Dip to White"
            }
        }
        set {}
    }
}
