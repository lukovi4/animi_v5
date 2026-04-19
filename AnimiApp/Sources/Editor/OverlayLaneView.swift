import UIKit

// MARK: - Overlay Lane Snapshot

/// Data snapshot for a single overlay lane (text or sticker).
/// Each item occupies its own visual row — no packing.
struct OverlayLaneSnapshot {
    struct Item {
        let id: UUID
        let startUs: TimeUs
        let durationUs: TimeUs
        let label: String
    }
    let items: [Item]
    let selectedItemId: UUID?
}

// MARK: - Overlay Lane View

/// Lane view for overlay items of a single kind (text or sticker) on the timeline.
/// Uses data/layout split pattern matching SceneTrackView.
final class OverlayLaneView: UIView {

    // MARK: - Lane Kind

    let laneKind: ItemKind

    // MARK: - Callbacks

    /// Called when an overlay item is tapped. Lane provides its own kind.
    var onSelectItem: ((UUID) -> Void)?

    /// Called when an overlay item is dragged to move.
    var onMoveItem: ((UUID, TimeUs, InteractionPhase) -> Void)?

    /// Called when an overlay item's trailing edge is dragged to trim.
    var onTrimItem: ((UUID, TimeUs, TrimEdge, InteractionPhase) -> Void)?

    // MARK: - State

    private var currentItems: [OverlayLaneSnapshot.Item] = []
    private var selectedItemId: UUID?
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var leftPadding: CGFloat = 0

    // MARK: - Subviews

    private var clipViews: [UUID: OverlayClipView] = [:]

    // MARK: - Initialization

    init(laneKind: ItemKind) {
        self.laneKind = laneKind
        super.init(frame: .zero)
        backgroundColor = .clear
        isHidden = true
        accessibilityIdentifier = laneKind == .text ? "textOverlayLane" : "stickerOverlayLane"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Data Path

    /// Applies a lane snapshot, creating/removing/reusing clip subviews.
    func applySnapshot(_ snapshot: OverlayLaneSnapshot) {
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
                existing.configure(label: item.label, isSelected: item.id == snapshot.selectedItemId, laneKind: laneKind)
            } else {
                let clip = OverlayClipView()
                clip.accessibilityIdentifier = "overlayClip_\(item.id.uuidString)"
                clip.configure(label: item.label, isSelected: item.id == snapshot.selectedItemId, laneKind: laneKind)
                clip.onTap = { [weak self] in self?.onSelectItem?(item.id) }
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
        let rowHeight: CGFloat = 28
        for (index, item) in currentItems.enumerated() {
            guard let clip = clipViews[item.id] else { continue }
            let startSeconds = CGFloat(usToSeconds(item.startUs))
            let durationSeconds = CGFloat(usToSeconds(item.durationUs))
            let x = leftPadding + startSeconds * pxPerSecond
            let width = max(20, durationSeconds * pxPerSecond)
            let y: CGFloat = 2 + CGFloat(index) * rowHeight
            clip.frame = CGRect(x: x, y: y, width: width, height: rowHeight - 2)

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

    func configure(label: String, isSelected: Bool, laneKind: ItemKind) {
        textLabel.text = label
        switch laneKind {
        case .sticker:
            iconLabel.text = "\u{1F600}"
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
