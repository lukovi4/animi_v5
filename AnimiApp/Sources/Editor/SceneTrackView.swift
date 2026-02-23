import UIKit

// MARK: - Scene Track View (PR2: Multi-scene support)

/// Visualizes scene clips on the timeline.
/// Renders multiple SceneClipViews based on scenes array.
/// PR2: Supports selection and trim handles.
final class SceneTrackView: UIView {

    // MARK: - Callbacks

    /// Called when a scene clip is selected.
    var onSelectScene: ((UUID) -> Void)?

    /// Called when a scene clip is being trimmed.
    var onTrimScene: ((UUID, TimeUs, TrimEdge, InteractionPhase) -> Void)?

    /// PR2 fix: Called when a clip view is created (for gesture conflict resolution).
    var onClipCreated: ((SceneClipView) -> Void)?

    // MARK: - Configuration

    private var scenes: [SceneDraft] = []
    private var pxPerSecond: CGFloat = EditorConfig.basePxPerSecond
    private var leftPadding: CGFloat = 0
    private var selectedSceneId: UUID?
    /// PR2 fix: Min duration for trim clamp (1 frame at templateFPS)
    private var minDurationUs: TimeUs = 33_333

    // MARK: - Clip Views

    private var clipViews: [UUID: SceneClipView] = [:]

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

            addSubview(clipView)
            clipViews[scene.id] = clipView

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
}
