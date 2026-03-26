import UIKit

// MARK: - Video Selection Editor Delegate

/// Delegate protocol for video selection editing events.
/// All methods pass the blockId for session validation.
/// Owner is responsible for dismiss in all paths — editor never dismisses itself.
protocol VideoSelectionEditorDelegate: AnyObject {
    /// Called on every slider/switch change for live preview.
    func videoSelectionEditorDidChange(blockId: String, selection: PersistedVideoSelection)
    /// Called when Done is tapped with a changed selection.
    func videoSelectionEditorDidConfirm(blockId: String, selection: PersistedVideoSelection)
    /// Called when Done is tapped with no changes. Owner must dismiss + cleanup session.
    func videoSelectionEditorDidFinishUnchanged(blockId: String)
    /// Called when Cancel is tapped.
    func videoSelectionEditorDidCancel(blockId: String)
}

// MARK: - Video Selection Editor View Controller

/// Modal editor for video selection parameters (trim, offset, audio).
/// Pure UI + delegate — no store access, no UMS access.
final class VideoSelectionEditorViewController: UIViewController {

    // MARK: - Properties

    weak var delegate: VideoSelectionEditorDelegate?

    private let blockId: String
    private let actualDuration: Double
    private let originalSelection: PersistedVideoSelection
    private var workingSelection: PersistedVideoSelection

    private let epsilon = VideoWindowValidator.epsilon

    // MARK: - UI Elements

    private let trimStartLabel = UILabel()
    private let trimStartSlider = UISlider()
    private let trimEndLabel = UILabel()
    private let trimEndSlider = UISlider()
    private let offsetLabel = UILabel()
    private let offsetSlider = UISlider()
    private let muteSwitch = UISwitch()
    private let muteLabel = UILabel()
    private let volumeLabel = UILabel()
    private let volumeSlider = UISlider()

    // MARK: - Initialization

    init(blockId: String, actualDuration: Double, initialSelection: PersistedVideoSelection) {
        self.blockId = blockId
        self.actualDuration = actualDuration
        self.originalSelection = initialSelection
        self.workingSelection = initialSelection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Edit Video"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )

        setupUI()
        syncUIToSelection()
    }

    // MARK: - UI Setup

    private func setupUI() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        // Trim Start
        trimStartSlider.minimumValue = 0
        trimStartSlider.maximumValue = Float(actualDuration)
        trimStartSlider.addTarget(self, action: #selector(trimStartChanged), for: .valueChanged)
        stackView.addArrangedSubview(makeLabeledRow(label: trimStartLabel, title: "Trim Start", control: trimStartSlider))

        // Trim End
        trimEndSlider.minimumValue = 0
        trimEndSlider.maximumValue = Float(actualDuration)
        trimEndSlider.addTarget(self, action: #selector(trimEndChanged), for: .valueChanged)
        stackView.addArrangedSubview(makeLabeledRow(label: trimEndLabel, title: "Trim End", control: trimEndSlider))

        // Offset
        offsetSlider.addTarget(self, action: #selector(offsetChanged), for: .valueChanged)
        stackView.addArrangedSubview(makeLabeledRow(label: offsetLabel, title: "Offset", control: offsetSlider))

        // Mute
        muteSwitch.addTarget(self, action: #selector(muteChanged), for: .valueChanged)
        muteLabel.text = "Muted"
        muteLabel.font = .preferredFont(forTextStyle: .subheadline)
        let muteRow = UIStackView(arrangedSubviews: [muteLabel, muteSwitch])
        muteRow.axis = .horizontal
        muteRow.spacing = 12
        stackView.addArrangedSubview(muteRow)

        // Volume
        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1.0
        volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        stackView.addArrangedSubview(makeLabeledRow(label: volumeLabel, title: "Volume", control: volumeSlider))
    }

    private func makeLabeledRow(label: UILabel, title: String, control: UIView) -> UIView {
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.text = title

        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .vertical
        row.spacing = 4
        return row
    }

    // MARK: - Sync UI

    private func syncUIToSelection() {
        trimStartSlider.value = Float(workingSelection.trimStart)
        trimEndSlider.value = Float(workingSelection.trimEnd)

        updateOffsetBounds()
        offsetSlider.value = Float(workingSelection.offset)

        muteSwitch.isOn = workingSelection.isMuted
        volumeSlider.value = workingSelection.volume

        updateLabels()
    }

    private func updateOffsetBounds() {
        let minOffset = -workingSelection.trimStart
        let maxOffset = actualDuration - workingSelection.trimEnd
        offsetSlider.minimumValue = Float(minOffset)
        offsetSlider.maximumValue = Float(maxOffset)
    }

    private func updateLabels() {
        trimStartLabel.text = String(format: "Trim Start: %.2fs", workingSelection.trimStart)
        trimEndLabel.text = String(format: "Trim End: %.2fs", workingSelection.trimEnd)
        offsetLabel.text = String(format: "Offset: %.2fs", workingSelection.offset)
        volumeLabel.text = String(format: "Volume: %.0f%%", workingSelection.volume * 100)
    }

    // MARK: - Slider Actions

    @objc private func trimStartChanged() {
        var ts = Double(trimStartSlider.value)
        // Clamp: trimStart <= trimEnd - epsilon
        ts = min(ts, workingSelection.trimEnd - epsilon)
        ts = max(ts, 0)
        workingSelection.trimStart = ts

        // Re-clamp offset
        clampOffset()

        syncUIToSelection()
        notifyChange()
    }

    @objc private func trimEndChanged() {
        var te = Double(trimEndSlider.value)
        // Clamp: trimEnd >= trimStart + epsilon, <= actualDuration
        te = max(te, workingSelection.trimStart + epsilon)
        te = min(te, actualDuration)
        workingSelection.trimEnd = te

        // Re-clamp offset
        clampOffset()

        syncUIToSelection()
        notifyChange()
    }

    @objc private func offsetChanged() {
        workingSelection.offset = Double(offsetSlider.value)
        clampOffset()

        syncUIToSelection()
        notifyChange()
    }

    @objc private func muteChanged() {
        workingSelection.isMuted = muteSwitch.isOn
        notifyChange()
    }

    @objc private func volumeChanged() {
        workingSelection.volume = volumeSlider.value
        updateLabels()
        notifyChange()
    }

    private func clampOffset() {
        let minOffset = -workingSelection.trimStart
        let maxOffset = actualDuration - workingSelection.trimEnd
        workingSelection.offset = min(max(workingSelection.offset, minOffset), maxOffset)
    }

    private func notifyChange() {
        delegate?.videoSelectionEditorDidChange(blockId: blockId, selection: workingSelection)
    }

    // MARK: - Navigation Actions

    @objc private func cancelTapped() {
        delegate?.videoSelectionEditorDidCancel(blockId: blockId)
    }

    @objc private func doneTapped() {
        if workingSelection != originalSelection {
            delegate?.videoSelectionEditorDidConfirm(blockId: blockId, selection: workingSelection)
        } else {
            delegate?.videoSelectionEditorDidFinishUnchanged(blockId: blockId)
        }
    }
}
