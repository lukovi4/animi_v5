import UIKit

// MARK: - Scene Track View (PR2: Multi-scene support, PR3: Reorder)

/// Visualizes scene clips on the timeline.
/// Renders multiple SceneClipViews based on scenes array.
/// PR2: Supports selection and trim handles.
/// PR3: Supports reorder mode with drag & drop.
final class SceneTrackView: UIView {

    // MARK: - Callbacks

    /// Called when a scene clip is selected.
    var onSelectScene: ((UUID) -> Void)?

    /// Called when a scene clip is being trimmed.
    var onTrimScene: ((UUID, TimeUs, TrimEdge, InteractionPhase) -> Void)?

    /// PR3: Called when a scene clip is being reordered.
    var onReorderScene: ((UUID, Int, InteractionPhase) -> Void)?

    /// PR2 fix: Called when a clip view is created (for gesture conflict resolution).
    var onClipCreated: ((SceneClipView) -> Void)?

    // MARK: - Configuration

    private var scenes: [SceneDraft] = []
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var leftPadding: CGFloat = 0
    private var selectedSceneId: UUID?
    /// PR2 fix: Min duration for trim clamp (0.1s per spec)
    private var minDurationUs: TimeUs = ProjectDraft.minSceneDurationUs

    // MARK: - Reorder Mode (PR3)

    private var isReorderMode: Bool = false
    private var draggingSceneId: UUID?
    private var currentTargetIndex: Int = -1

    /// Insertion line indicator (visible during reorder drag)
    private lazy var insertionLine: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBlue
        view.isHidden = true
        view.layer.cornerRadius = 1
        return view
    }()

    // MARK: - Clip Views

    private var clipViews: [UUID: SceneClipView] = [:]

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupInsertionLine()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupInsertionLine() {
        addSubview(insertionLine)
    }

    // MARK: - Configuration

    /// Configures track with scenes array.
    /// - Parameters:
    ///   - scenes: Array of SceneDraft objects
    ///   - pxPerSecond: Pixels per second for width calculation
    ///   - leftPadding: Left padding where time=0 starts
    ///   - minDurationUs: Minimum duration for trim clamp (1 frame at templateFPS)
    func configure(scenes: [SceneDraft], pxPerSecond: CGFloat, leftPadding: CGFloat, minDurationUs: TimeUs) {
        self.scenes = scenes
        self.pxPerSecond = pxPerSecond
        self.leftPadding = leftPadding
        self.minDurationUs = minDurationUs
        rebuildClipViews()
    }

    /// Updates pixels per second and leftPadding (when timeline zooms).
    func setPxPerSecond(_ pxPerSec: CGFloat, leftPadding: CGFloat) {
        self.pxPerSecond = pxPerSec
        self.leftPadding = leftPadding
        updateClipLayouts()
    }

    /// Updates scenes and refreshes layout.
    /// PR2 v7: Only rebuild if IDs changed, otherwise update frames in-place (for live trim)
    func updateScenes(_ scenes: [SceneDraft]) {
        let oldIds = self.scenes.map { $0.id }
        let newIds = scenes.map { $0.id }

        self.scenes = scenes

        // Rebuild only if structure changed
        if oldIds != newIds || clipViews.count != scenes.count {
            rebuildClipViews()
            return
        }

        // Same clips, just durations updated -> update frames in place
        updateClipLayouts()
    }

    /// Sets selected scene by ID.
    func setSelectedScene(_ sceneId: UUID?) {
        selectedSceneId = sceneId
        for (id, clipView) in clipViews {
            clipView.setSelected(id == sceneId)
        }
    }

    // MARK: - Reorder Mode (PR3)

    /// Sets reorder mode and propagates to clip views.
    /// - Parameter isReorderMode: Whether reorder mode is active
    func setReorderMode(_ isReorderMode: Bool) {
        self.isReorderMode = isReorderMode
        for (_, clipView) in clipViews {
            clipView.setReorderMode(isReorderMode)
        }
        // Hide insertion line when exiting reorder mode
        if !isReorderMode {
            insertionLine.isHidden = true
            draggingSceneId = nil
            currentTargetIndex = -1
        }
    }

    // MARK: - Legacy API (backward compatibility)

    /// Legacy configure for single-scene mode.
    /// Creates a temporary scene with given duration.
    func configure(durationUs: TimeUs, pxPerSecond: CGFloat, leftPadding: CGFloat) {
        // Create a single scene for backward compatibility (uses default minDurationUs ~30fps)
        let singleScene = SceneDraft(id: UUID(), durationUs: durationUs)
        configure(scenes: [singleScene], pxPerSecond: pxPerSecond, leftPadding: leftPadding, minDurationUs: 33_333)
    }

    /// Legacy selection API.
    func setSelected(_ selected: Bool) {
        // Select first scene if selected, otherwise clear
        if selected, let firstScene = scenes.first {
            setSelectedScene(firstScene.id)
        } else {
            setSelectedScene(nil)
        }
    }

    // MARK: - Private

    private func rebuildClipViews() {
        // Remove old clip views
        for (_, clipView) in clipViews {
            clipView.removeFromSuperview()
        }
        clipViews.removeAll()

        // Create new clip views
        for scene in scenes {
            let clipView = SceneClipView(sceneId: scene.id, durationUs: scene.durationUs)
            // PR2 v5 fix: Use frame-based layout, NOT Auto Layout
            // (translatesAutoresizingMaskIntoConstraints defaults to true)
            clipView.setPxPerSecond(pxPerSecond)
            clipView.setSelected(scene.id == selectedSceneId)

            // Wire callbacks
            clipView.onSelect = { [weak self] in
                self?.onSelectScene?(scene.id)
            }

            clipView.onTrimTrailing = { [weak self] newDurationUs, phase in
                self?.onTrimScene?(scene.id, newDurationUs, .trailing, phase)
            }

            // PR3: Reorder callback
            clipView.onReorderDrag = { [weak self] dragX, phase in
                self?.handleReorderDrag(sceneId: scene.id, dragX: dragX, phase: phase)
            }

            addSubview(clipView)
            clipViews[scene.id] = clipView

            // PR3: Apply current reorder mode
            clipView.setReorderMode(isReorderMode)

            // PR2 fix: Notify for gesture conflict resolution
            onClipCreated?(clipView)
        }

        updateClipLayouts()
    }

    private func updateClipLayouts() {
        var currentX = leftPadding

        for scene in scenes {
            guard let clipView = clipViews[scene.id] else { continue }

            let durationSeconds = CGFloat(usToSeconds(scene.durationUs))
            let clipWidth = durationSeconds * pxPerSecond

            clipView.frame = CGRect(
                x: currentX,
                y: 0,
                width: clipWidth,
                height: bounds.height
            )
            clipView.configure(durationUs: scene.durationUs, pxPerSecond: pxPerSecond, minDurationUs: minDurationUs)

            currentX += clipWidth
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateClipLayouts()
    }

    // MARK: - Reorder Handling (PR3)

    /// Handles reorder drag events from clip views.
    /// - Parameters:
    ///   - sceneId: ID of the scene being dragged
    ///   - dragX: X position of the drag in track coordinates
    ///   - phase: Gesture phase
    private func handleReorderDrag(sceneId: UUID, dragX: CGFloat, phase: InteractionPhase) {
        switch phase {
        case .began:
            draggingSceneId = sceneId
            let targetIndex = calculateTargetIndex(for: dragX, draggingSceneId: sceneId)
            currentTargetIndex = targetIndex
            updateInsertionLine(for: targetIndex, draggingSceneId: sceneId)
            onReorderScene?(sceneId, targetIndex, .began)

        case .changed:
            let targetIndex = calculateTargetIndex(for: dragX, draggingSceneId: sceneId)
            if targetIndex != currentTargetIndex {
                currentTargetIndex = targetIndex
                updateInsertionLine(for: targetIndex, draggingSceneId: sceneId)
            }
            onReorderScene?(sceneId, targetIndex, .changed)

        case .ended:
            let targetIndex = calculateTargetIndex(for: dragX, draggingSceneId: sceneId)
            insertionLine.isHidden = true
            draggingSceneId = nil
            currentTargetIndex = -1
            onReorderScene?(sceneId, targetIndex, .ended)

        case .cancelled:
            insertionLine.isHidden = true
            draggingSceneId = nil
            currentTargetIndex = -1
            onReorderScene?(sceneId, -1, .cancelled)
        }
    }

    /// Calculates target index based on drag X position.
    /// - Parameters:
    ///   - dragX: X position in track coordinates
    ///   - draggingSceneId: ID of the scene being dragged
    /// - Returns: Target index where the scene should be inserted
    private func calculateTargetIndex(for dragX: CGFloat, draggingSceneId: UUID) -> Int {
        guard !scenes.isEmpty else { return 0 }

        // Calculate clip boundaries
        var boundaries: [CGFloat] = [leftPadding]
        var currentX = leftPadding

        for scene in scenes {
            let durationSeconds = CGFloat(usToSeconds(scene.durationUs))
            let clipWidth = durationSeconds * pxPerSecond
            currentX += clipWidth
            boundaries.append(currentX)
        }

        // Find insertion index based on dragX
        var targetIndex = 0
        for (index, boundary) in boundaries.enumerated() {
            if dragX < boundary {
                break
            }
            targetIndex = index
        }

        // PR3.1: Clamp to valid insertion range (0...count, not count-1)
        // This allows inserting at the end of the track
        targetIndex = max(0, min(targetIndex, scenes.count))

        return targetIndex
    }

    /// Updates insertion line position based on target index.
    /// PR3.1: Supports insertion at end (targetIndex == scenes.count)
    /// - Parameters:
    ///   - targetIndex: Index where the line should appear (0...scenes.count)
    ///   - draggingSceneId: ID of the scene being dragged
    private func updateInsertionLine(for targetIndex: Int, draggingSceneId: UUID) {
        guard targetIndex >= 0, !scenes.isEmpty else {
            insertionLine.isHidden = true
            return
        }

        // Find current index of dragging scene
        let currentIndex = scenes.firstIndex { $0.id == draggingSceneId } ?? 0

        // PR3.1: Don't show line if dropping results in same position
        // - targetIndex == currentIndex means "insert before me" = no change
        // - targetIndex == currentIndex + 1 means "insert right after me" = no change
        if targetIndex == currentIndex || targetIndex == currentIndex + 1 {
            insertionLine.isHidden = true
            return
        }

        // PR3.1: Calculate X position for insertion line
        // - index 0: leftPadding
        // - index N (scenes.count): end of last clip
        var lineX = leftPadding

        for (index, scene) in scenes.enumerated() {
            if index == targetIndex {
                break
            }
            let durationSeconds = CGFloat(usToSeconds(scene.durationUs))
            lineX += durationSeconds * pxPerSecond
        }
        // Note: if targetIndex == scenes.count, loop completes without break,
        // lineX ends up at the correct position (end of all clips)

        // Position insertion line
        let lineWidth: CGFloat = 3
        insertionLine.frame = CGRect(
            x: lineX - lineWidth / 2,
            y: 2,
            width: lineWidth,
            height: bounds.height - 4
        )
        insertionLine.isHidden = false

        // Bring to front
        bringSubviewToFront(insertionLine)
    }
}
