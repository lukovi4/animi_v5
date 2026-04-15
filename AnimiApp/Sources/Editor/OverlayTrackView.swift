import UIKit

// MARK: - Overlay Track Snapshot (PR9: Text Overlay)

/// Data snapshot for overlay track items.
struct OverlayTrackSnapshot {
    let items: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String, itemKind: ItemKind)]
    let selectedItemId: UUID?
}

// MARK: - Overlay Track View (PR9: Reusable for text + future stickers)

/// Track view for overlay items (text, stickers) on the timeline.
/// Uses data/layout split pattern matching SceneTrackView.
final class OverlayTrackView: UIView {

    // MARK: - Callbacks

    /// Called when an overlay item is tapped. Carries explicit ItemKind from snapshot.
    var onSelectItem: ((UUID, ItemKind) -> Void)?

    /// Called when an overlay item is dragged to move.
    var onMoveItem: ((UUID, TimeUs, InteractionPhase) -> Void)?

    /// Called when an overlay item's trailing edge is dragged to trim.
    var onTrimItem: ((UUID, TimeUs, TrimEdge, InteractionPhase) -> Void)?

    // MARK: - State

    private var currentItems: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String, itemKind: ItemKind)] = []
    private var selectedItemId: UUID?
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var leftPadding: CGFloat = 0

    // MARK: - Subviews

    private var clipViews: [UUID: OverlayClipView] = [:]

    // MARK: - Appearance

    private let clipColor: UIColor = .systemTeal
    private let clipCornerRadius: CGFloat = 6

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isHidden = true // Hidden until items exist
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Data Path

    /// Applies a data snapshot, creating/removing/reusing clip subviews.
    func applySnapshot(_ snapshot: OverlayTrackSnapshot) {
        currentItems = snapshot.items
        selectedItemId = snapshot.selectedItemId

        let newIds = Set(snapshot.items.map(\.id))
        let existingIds = Set(clipViews.keys)

        // Remove stale clips
        for id in existingIds.subtracting(newIds) {
            clipViews[id]?.removeFromSuperview()
            clipViews.removeValue(forKey: id)
        }

        // Create or update clips
        for item in snapshot.items {
            if let existing = clipViews[item.id] {
                existing.configure(label: item.label, isSelected: item.id == snapshot.selectedItemId, itemKind: item.itemKind)
            } else {
                let clip = OverlayClipView()
                clip.configure(label: item.label, isSelected: item.id == snapshot.selectedItemId, itemKind: item.itemKind)
                clip.onTap = { [weak self] in self?.onSelectItem?(item.id, item.itemKind) }
                clip.onMove = { [weak self] newStartUs, phase in
                    self?.onMoveItem?(item.id, newStartUs, phase)
                }
                clip.onTrim = { [weak self] newDurationUs, phase in
                    self?.onTrimItem?(item.id, newDurationUs, .trailing, phase)
                }
                addSubview(clip)
                clipViews[item.id] = clip
            }
        }
    }

    // MARK: - Layout Path

    /// Configures layout parameters.
    func configure(pxPerSecond: CGFloat, leftPadding: CGFloat) {
        self.pxPerSecond = pxPerSecond
        self.leftPadding = leftPadding
        layoutItems()
    }

    /// Sets the selected item ID and updates highlight.
    func setSelectedItem(_ itemId: UUID?) {
        selectedItemId = itemId
        for (id, clip) in clipViews {
            clip.setSelected(id == itemId)
        }
    }

    private func layoutItems() {
        for item in currentItems {
            guard let clip = clipViews[item.id] else { continue }
            let startSeconds = CGFloat(usToSeconds(item.startUs))
            let durationSeconds = CGFloat(usToSeconds(item.durationUs))
            let x = leftPadding + startSeconds * pxPerSecond
            let width = max(20, durationSeconds * pxPerSecond)
            clip.frame = CGRect(x: x, y: 2, width: width, height: bounds.height - 4)

            // Store layout info for gesture computation
            clip.itemStartUs = item.startUs
            clip.itemDurationUs = item.durationUs
            clip.pxPerSecond = pxPerSecond
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutItems()
    }
}

// MARK: - Overlay Clip View

/// Individual clip view for an overlay item on the timeline.
private final class OverlayClipView: UIView {

    var onTap: (() -> Void)?
    var onMove: ((TimeUs, InteractionPhase) -> Void)?
    var onTrim: ((TimeUs, InteractionPhase) -> Void)?

    var itemStartUs: TimeUs = 0
    var itemDurationUs: TimeUs = 0
    var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond

    private var dragStartX: CGFloat = 0
    private var dragStartUs: TimeUs = 0
    private var trimStartDurationUs: TimeUs = 0

    private let iconLabel: UILabel = {
        let label = UILabel()
        label.text = "Aa"
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .white
        return label
    }()

    private let textLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 10, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let trimHandle: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        v.layer.cornerRadius = 2
        return v
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemTeal
        layer.cornerRadius = 6
        clipsToBounds = true

        addSubview(iconLabel)
        addSubview(textLabel)
        addSubview(trimHandle)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let bodyPan = UIPanGestureRecognizer(target: self, action: #selector(handleBodyPan(_:)))
        addGestureRecognizer(bodyPan)

        let trimPan = UIPanGestureRecognizer(target: self, action: #selector(handleTrimPan(_:)))
        trimHandle.addGestureRecognizer(trimPan)
        trimHandle.isUserInteractionEnabled = true

        // Body pan should not interfere with trim pan
        bodyPan.require(toFail: trimPan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(label: String, isSelected: Bool, itemKind: ItemKind) {
        textLabel.text = label
        switch itemKind {
        case .sticker:
            iconLabel.text = "\u{1F600}" // face emoji as placeholder, or use SF Symbol approach
            backgroundColor = .systemPurple
        default:
            iconLabel.text = "Aa"
            backgroundColor = .systemTeal
        }
        setSelected(isSelected)
    }

    func setSelected(_ selected: Bool) {
        layer.borderWidth = selected ? 2 : 0
        layer.borderColor = selected ? UIColor.white.cgColor : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        iconLabel.frame = CGRect(x: 6, y: (h - 14) / 2, width: 18, height: 14)
        textLabel.frame = CGRect(x: 26, y: (h - 14) / 2, width: bounds.width - 40, height: 14)
        trimHandle.frame = CGRect(x: bounds.width - 8, y: 4, width: 4, height: h - 8)
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handleBodyPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: superview)

        switch recognizer.state {
        case .began:
            dragStartX = frame.origin.x
            dragStartUs = itemStartUs
            onMove?(itemStartUs, .began)
        case .changed:
            let deltaSeconds = Double(translation.x) / Double(pxPerSecond)
            let deltaUs = TimeUs(deltaSeconds * 1_000_000)
            let newStartUs = max(0, dragStartUs + deltaUs)
            onMove?(newStartUs, .changed)
        case .ended:
            let deltaSeconds = Double(translation.x) / Double(pxPerSecond)
            let deltaUs = TimeUs(deltaSeconds * 1_000_000)
            let newStartUs = max(0, dragStartUs + deltaUs)
            onMove?(newStartUs, .ended)
        case .cancelled:
            onMove?(dragStartUs, .cancelled)
        default:
            break
        }
    }

    @objc private func handleTrimPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: superview)

        switch recognizer.state {
        case .began:
            trimStartDurationUs = itemDurationUs
            onTrim?(itemDurationUs, .began)
        case .changed:
            let deltaSeconds = Double(translation.x) / Double(pxPerSecond)
            let deltaUs = TimeUs(deltaSeconds * 1_000_000)
            let newDurationUs = max(500_000, trimStartDurationUs + deltaUs)
            onTrim?(newDurationUs, .changed)
        case .ended:
            let deltaSeconds = Double(translation.x) / Double(pxPerSecond)
            let deltaUs = TimeUs(deltaSeconds * 1_000_000)
            let newDurationUs = max(500_000, trimStartDurationUs + deltaUs)
            onTrim?(newDurationUs, .ended)
        case .cancelled:
            onTrim?(trimStartDurationUs, .cancelled)
        default:
            break
        }
    }
}
