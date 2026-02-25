import UIKit

// MARK: - Scene Track View (PR2: Multi-scene support, PR3: Reorder, PR4: Data/Layout split)

/// Visualizes scene clips on the timeline.
/// Renders multiple SceneClipViews based on scenes array.
/// PR2: Supports selection and trim handles.
/// PR3: Supports reorder mode with drag & drop.
/// PR4: Conforms to TrackViewContract - separates data (applySnapshot) from layout (layoutItems).
final class SceneTrackView: UIView, TrackViewContract {

    // MARK: - Callbacks

    /// Called when a scene clip is selected.
    var onSelectScene: ((UUID) -> Void)?

    /// Called when a scene clip is being trimmed.
    var onTrimScene: ((UUID, TimeUs, TrimEdge, InteractionPhase) -> Void)?

    /// PR3: Called when a scene clip is being reordered.
    var onReorderScene: ((UUID, Int, InteractionPhase) -> Void)?

    /// PR2 fix: Called when a clip view is created (for gesture conflict resolution).
    var onClipCreated: ((SceneClipView) -> Void)?

    // MARK: - Data State (PR4: data path)

    private var scenes: [SceneDraft] = []
    private var selectedSceneId: UUID?
    /// PR2 fix: Min duration for trim clamp (0.1s per spec)
    private var minDurationUs: TimeUs = ProjectDraft.minSceneDurationUs

    // MARK: - Layout State (PR4: layout path)

    private var layoutContext: TimelineLayoutContext = TimelineLayoutContext(
        pxPerSecond: EditorConfig.basePxPerSecond,
        leftPadding: 0
    )

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

    // MARK: - TrackViewContract (PR4)

    /// Applies data snapshot. Called when scenes change, NOT during scroll/zoom.
    /// Creates/removes clip views as needed (diff by IDs).
    /// - Parameter snapshot: Data snapshot with scenes, selection, constraints
    func applySnapshot(_ snapshot: SceneTrackSnapshot) {
        #if DEBUG
        TimelinePerfCounters.incrementApplySnapshot(.scene)
        #endif

        let oldIds = Set(scenes.map { $0.id })
        let newIds = Set(snapshot.scenes.map { $0.id })

        // Store new data
        self.scenes = snapshot.scenes
        self.selectedSceneId = snapshot.selectedSceneId
        self.minDurationUs = snapshot.minDurationUs

        // Diff: determine what changed
        let addedIds = newIds.subtracting(oldIds)
        let removedIds = oldIds.subtracting(newIds)
        let existingIds = oldIds.intersection(newIds)

        // Remove clips for removed scenes
        for id in removedIds {
            clipViews[id]?.removeFromSuperview()
            clipViews.removeValue(forKey: id)
        }

        // Create clips for added scenes
        for scene in snapshot.scenes where addedIds.contains(scene.id) {
            createClipView(for: scene)
        }

        // Update data for existing clips (no frame changes here!)
        for scene in snapshot.scenes where existingIds.contains(scene.id) {
            guard let clipView = clipViews[scene.id] else { continue }

            let clipSnapshot = SceneClipSnapshot(
                durationUs: scene.durationUs,
                isSelected: scene.id == snapshot.selectedSceneId,
                minDurationUs: snapshot.minDurationUs
            )
            clipView.applySnapshot(clipSnapshot)
            clipView.setSelected(scene.id == snapshot.selectedSceneId)
        }

        // Update selection for new clips
        for id in addedIds {
            clipViews[id]?.setSelected(id == snapshot.selectedSceneId)
        }

        // Trigger layout (frames will be set in layoutItems)
        setNeedsLayout()
    }

    /// Performs layout-only update (frames, positions).
    /// Called during scroll/zoom, must NOT trigger data updates.
    /// - Parameter context: Layout context with pxPerSecond and leftPadding
    func layoutItems(_ context: TimelineLayoutContext) {
        #if DEBUG
        TimelinePerfCounters.incrementLayout(.scene)
        #endif

        self.layoutContext = context
        var currentX = context.leftPadding

        for scene in scenes {
            guard let clipView = clipViews[scene.id] else { continue }

            let durationSeconds = CGFloat(usToSeconds(scene.durationUs))
            let clipWidth = durationSeconds * context.pxPerSecond

            // Set frame (layout only)
            clipView.frame = CGRect(
                x: currentX,
                y: 0,
                width: clipWidth,
                height: bounds.height
            )

            // Apply layout params to clip (for gesture calculations)
            clipView.applyLayout(pxPerSecond: context.pxPerSecond)

            currentX += clipWidth
        }

        // Update insertion line position if active
        if let draggingId = draggingSceneId, currentTargetIndex >= 0 {
            updateInsertionLine(for: currentTargetIndex, draggingSceneId: draggingId)
        }
    }

    // MARK: - Layout Context Setter (PR4)

    /// Updates layout context and triggers layout.
    /// Called by TimelineView when zoom/scroll changes.
    /// - Parameter context: New layout context
    func setLayoutContext(_ context: TimelineLayoutContext) {
        self.layoutContext = context
        setNeedsLayout()
    }

    // MARK: - Selection (PR4: separate from applySnapshot)

    /// Sets selected scene by ID. Only updates visual state.
    /// - Parameter sceneId: Scene ID to select, or nil to clear
    func setSelectedScene(_ sceneId: UUID?) {
        selectedSceneId = sceneId
        for (id, clipView) in clipViews {
            clipView.setSelected(id == sceneId)
        }
    }

    // MARK: - Legacy Configuration (PR4 deprecated)

    /// Configures track with scenes array.
    /// PR4: Deprecated - use applySnapshot + setLayoutContext instead
    @available(*, deprecated, message: "Use applySnapshot + setLayoutContext instead")
    func configure(scenes: [SceneDraft], pxPerSecond: CGFloat, leftPadding: CGFloat, minDurationUs: TimeUs) {
        let snapshot = SceneTrackSnapshot(
            scenes: scenes,
            selectedSceneId: selectedSceneId,
            minDurationUs: minDurationUs
        )
        applySnapshot(snapshot)
        setLayoutContext(TimelineLayoutContext(pxPerSecond: pxPerSecond, leftPadding: leftPadding))
    }

    /// Updates pixels per second and leftPadding (when timeline zooms).
    /// PR4: Deprecated - use setLayoutContext instead
    @available(*, deprecated, message: "Use setLayoutContext instead")
    func setPxPerSecond(_ pxPerSec: CGFloat, leftPadding: CGFloat) {
        setLayoutContext(TimelineLayoutContext(pxPerSecond: pxPerSec, leftPadding: leftPadding))
    }

    /// Updates scenes and refreshes layout.
    /// PR4: Deprecated - use applySnapshot instead
    @available(*, deprecated, message: "Use applySnapshot instead")
    func updateScenes(_ scenes: [SceneDraft]) {
        let snapshot = SceneTrackSnapshot(
            scenes: scenes,
            selectedSceneId: selectedSceneId,
            minDurationUs: minDurationUs
        )
        applySnapshot(snapshot)
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
        configure(scenes: [singleScene], pxPerSecond: pxPerSecond, leftPadding: leftPadding, minDurationUs: ProjectDraft.minSceneDurationUs)
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

    // MARK: - Private (PR4)

    /// Creates a new clip view for a scene. Callbacks are set once at creation.
    /// - Parameter scene: Scene data for the clip
    private func createClipView(for scene: SceneDraft) {
        let clipView = SceneClipView(sceneId: scene.id, durationUs: scene.durationUs)
        // PR2 v5 fix: Use frame-based layout, NOT Auto Layout
        // (translatesAutoresizingMaskIntoConstraints defaults to true)

        // PR4: Apply initial data snapshot
        let clipSnapshot = SceneClipSnapshot(
            durationUs: scene.durationUs,
            isSelected: scene.id == selectedSceneId,
            minDurationUs: minDurationUs
        )
        clipView.applySnapshot(clipSnapshot)

        // Wire callbacks ONCE at creation (PR4: not in applySnapshot)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // PR4: Only call layout path, no data updates
        layoutItems(layoutContext)
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

        // Calculate clip boundaries (PR4: use layoutContext)
        var boundaries: [CGFloat] = [layoutContext.leftPadding]
        var currentX = layoutContext.leftPadding

        for scene in scenes {
            let durationSeconds = CGFloat(usToSeconds(scene.durationUs))
            let clipWidth = durationSeconds * layoutContext.pxPerSecond
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

        // PR3.1: Calculate X position for insertion line (PR4: use layoutContext)
        // - index 0: leftPadding
        // - index N (scenes.count): end of last clip
        var lineX = layoutContext.leftPadding

        for (index, scene) in scenes.enumerated() {
            if index == targetIndex {
                break
            }
            let durationSeconds = CGFloat(usToSeconds(scene.durationUs))
            lineX += durationSeconds * layoutContext.pxPerSecond
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
