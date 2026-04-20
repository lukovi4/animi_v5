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

    /// Called when a new clip subview is created, so TimelineView can set up gesture arbitration.
    var onClipCreated: ((OverlayClipView) -> Void)?

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
                onClipCreated?(clip)
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
///
/// Gesture architecture: selection-gated, two separate gestures.
/// - Tap to select (always active)
/// - Long-press-drag to move (enabled only when selected)
/// - Trailing-zone pan to trim (enabled only when selected, gated by delegate)
///
/// The clip's hit area is expanded 44pt to the right via `point(inside:with:)`
/// only when selected. Each overlay item has its own row, so the expansion is safe.
///
/// Trim pill is visual-only (no gesture role).
final class OverlayClipView: UIView, UIGestureRecognizerDelegate {

    var onTap: (() -> Void)?
    var onMove: ((TimeUs, InteractionPhase) -> Void)?
    var onTrim: ((TimeUs, InteractionPhase) -> Void)?

    var itemStartUs: TimeUs = 0
    var itemDurationUs: TimeUs = 0
    var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond

    private(set) var isSelected: Bool = false
    private var moveInitialLocationInSuperview: CGFloat = 0
    private var dragStartUs: TimeUs = 0
    private var trimStartDurationUs: TimeUs = 0

    // MARK: - Subviews

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

    /// Visual trim indicator at trailing edge. No gesture role.
    private let trimPill: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        v.layer.cornerRadius = 2
        v.isUserInteractionEnabled = false
        return v
    }()

    // MARK: - Gestures (exposed for scroll arbitration)

    /// Long-press gesture for move. Disabled when unselected.
    /// Gated via delegate: only begins in visible body zone.
    private(set) lazy var moveLongPressGesture: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handleMoveLongPress(_:)))
        g.minimumPressDuration = 0.3
        g.allowableMovement = 10
        g.isEnabled = false
        g.delegate = self
        return g
    }()

    /// Pan gesture for trailing trim. Disabled when unselected.
    /// Gated via delegate: only begins in expanded trailing zone.
    private(set) lazy var trimPanGesture: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(handleTrimPan(_:)))
        g.isEnabled = false
        g.delegate = self
        return g
    }()

    /// Tap gesture for selection. Gated via delegate: only in visible bounds.
    private lazy var tapGesture: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        g.delegate = self
        return g
    }()

    // MARK: - Constants

    /// Trailing hit expansion beyond visible bounds for trim target.
    static let trailingHitExpansion: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemTeal
        layer.cornerRadius = 6
        clipsToBounds = true

        addSubview(iconLabel)
        addSubview(textLabel)
        addSubview(trimPill)

        addGestureRecognizer(tapGesture)
        addGestureRecognizer(moveLongPressGesture)
        addGestureRecognizer(trimPanGesture)
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
        isSelected = selected
        layer.borderWidth = selected ? 2 : 0
        layer.borderColor = selected ? UIColor.white.cgColor : nil
        moveLongPressGesture.isEnabled = selected
        trimPanGesture.isEnabled = selected
    }

    // MARK: - Expanded Hit Testing

    /// Expands touch area 44pt beyond the trailing edge only when selected.
    /// Unselected clips don't expand — no stolen scroll touches beyond visible bounds.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isSelected {
            let expanded = bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: -Self.trailingHitExpansion))
            return expanded.contains(point)
        }
        return bounds.contains(point)
    }

    /// Interaction zone classification for a local X coordinate.
    enum InteractionZone {
        /// Inside visible clip bounds — move/select territory.
        case visibleBody
        /// Beyond visible bounds in the 44pt trailing expansion — trim territory.
        case trimZone
    }

    /// Classifies a local X coordinate into an interaction zone.
    /// Returns nil if the coordinate is outside all zones.
    func interactionZone(forLocalX localX: CGFloat) -> InteractionZone? {
        if localX >= 0 && localX < bounds.width {
            return .visibleBody
        } else if localX >= bounds.width && localX < bounds.width + Self.trailingHitExpansion {
            return .trimZone
        }
        return nil
    }

    /// Whether a local X coordinate falls in the trim zone (beyond visible bounds).
    func isInTrimZone(localX: CGFloat) -> Bool {
        interactionZone(forLocalX: localX) == .trimZone
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h = bounds.height

        iconLabel.frame = CGRect(x: 6, y: (h - 14) / 2, width: 18, height: 14)
        textLabel.frame = CGRect(x: 26, y: (h - 14) / 2, width: max(0, w - 40), height: 14)

        // Visual pill at trailing edge
        let pillW: CGFloat = 4
        let pillH: CGFloat = min(18, h - 8)
        trimPill.frame = CGRect(
            x: w - 8,
            y: (h - pillH) / 2,
            width: pillW,
            height: pillH
        )
    }

    // MARK: - Gesture Handlers

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handleMoveLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let sv = superview else { return }
        let locationX = recognizer.location(in: sv).x
        switch recognizer.state {
        case .began:
            dragStartUs = itemStartUs
            moveInitialLocationInSuperview = locationX
            onMove?(itemStartUs, .began)
        case .changed:
            let deltaSeconds = Double(locationX - moveInitialLocationInSuperview) / Double(pxPerSecond)
            let deltaUs = TimeUs(deltaSeconds * 1_000_000)
            onMove?(max(0, dragStartUs + deltaUs), .changed)
        case .ended:
            let deltaSeconds = Double(locationX - moveInitialLocationInSuperview) / Double(pxPerSecond)
            let deltaUs = TimeUs(deltaSeconds * 1_000_000)
            onMove?(max(0, dragStartUs + deltaUs), .ended)
        case .cancelled, .failed:
            onMove?(dragStartUs, .cancelled)
        default: break
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
            onTrim?(max(500_000, trimStartDurationUs + deltaUs), .changed)
        case .ended:
            let deltaSeconds = Double(translation.x) / Double(pxPerSecond)
            let deltaUs = TimeUs(deltaSeconds * 1_000_000)
            onTrim?(max(500_000, trimStartDurationUs + deltaUs), .ended)
        case .cancelled:
            onTrim?(trimStartDurationUs, .cancelled)
        default: break
        }
    }


    // MARK: - UIGestureRecognizerDelegate

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let localX = gestureRecognizer.location(in: self).x
        let zone = interactionZone(forLocalX: localX)

        if gestureRecognizer === trimPanGesture {
            return zone == .trimZone
        }
        if gestureRecognizer === moveLongPressGesture {
            return zone == .visibleBody
        }
        if gestureRecognizer === tapGesture {
            return zone == .visibleBody
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
