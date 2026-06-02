import UIKit

// MARK: - Text Editor ViewController (PR9: Minimal V1 Modal)

/// Minimal text overlay editor presented as form sheet.
/// Allows editing text content, font size, and color.
final class TextEditorViewController: UIViewController {

    // MARK: - Callbacks

    /// Called when user commits changes. Delivers the updated TextPayload.
    var onCommit: ((TextPayload) -> Void)?

    // MARK: - State

    /// Pre-populated payload when editing existing text. nil for new text.
    private var existingPayload: TextPayload?

    // MARK: - Preset Colors

    private let presetColors: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"),
        ("Black", "#000000"),
        ("Red", "#FF3B30"),
        ("Orange", "#FF9500"),
        ("Yellow", "#FFCC00"),
        ("Green", "#34C759"),
        ("Blue", "#007AFF"),
        ("Purple", "#AF52DE"),
    ]

    private var selectedColorIndex: Int = 0

    // MARK: - Subviews

    private lazy var textView: UITextView = {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.font = .systemFont(ofSize: 18)
        tv.layer.borderColor = UIColor.separator.cgColor
        tv.layer.borderWidth = 1
        tv.layer.cornerRadius = 8
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.backgroundColor = .secondarySystemBackground
        return tv
    }()

    private lazy var fontSizeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }()

    private lazy var fontSizeSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        // Use the shared text-style bounds so the modal can never silently shrink
        // a pinch-grown text below its current size. `populateFromPayload` further
        // widens the max to include the current font size when needed.
        slider.minimumValue = Float(TextOverlayTransformSession.minFontSize)
        slider.maximumValue = Float(TextOverlayTransformSession.maxFontSize)
        slider.value = Float(TextStyle.defaultFontSize)
        slider.addTarget(self, action: #selector(fontSizeChanged), for: .valueChanged)
        return slider
    }()

    private lazy var colorStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        return stack
    }()

    private var colorButtons: [UIButton] = []

    // MARK: - Initialization

    /// Creates a text editor.
    /// - Parameter payload: Existing payload to edit, or nil for new text.
    init(payload: TextPayload? = nil) {
        self.existingPayload = payload
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupNavBar()
        setupLayout()
        populateFromPayload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    // MARK: - Setup

    private func setupNavBar() {
        title = existingPayload != nil ? "Edit Text" : "Add Text"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
    }

    private func setupLayout() {
        view.addSubview(textView)
        view.addSubview(fontSizeLabel)
        view.addSubview(fontSizeSlider)
        view.addSubview(colorStackView)

        // Create color buttons
        for (index, preset) in presetColors.enumerated() {
            let button = UIButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.backgroundColor = UIColor(hex: preset.hex)
            button.layer.cornerRadius = 16
            button.layer.borderWidth = 2
            button.layer.borderColor = UIColor.clear.cgColor
            button.tag = index
            button.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 32),
                button.heightAnchor.constraint(equalToConstant: 32),
            ])
            colorStackView.addArrangedSubview(button)
            colorButtons.append(button)
        }

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 120),

            fontSizeLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 20),
            fontSizeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            fontSizeSlider.topAnchor.constraint(equalTo: fontSizeLabel.bottomAnchor, constant: 8),
            fontSizeSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fontSizeSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            colorStackView.topAnchor.constraint(equalTo: fontSizeSlider.bottomAnchor, constant: 20),
            colorStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        updateFontSizeLabel()
    }

    private func populateFromPayload() {
        guard let payload = existingPayload else {
            selectColor(at: 0)
            return
        }

        textView.text = payload.text
        if let fontSize = payload.fontSize {
            // Never clamp a pinch-grown size: widen the slider max to include the
            // current value so opening + saving the editor preserves it.
            if Float(fontSize) > fontSizeSlider.maximumValue {
                fontSizeSlider.maximumValue = Float(fontSize)
            }
            fontSizeSlider.value = Float(fontSize)
        }
        if let colorHex = payload.colorHex,
           let index = presetColors.firstIndex(where: { $0.hex == colorHex }) {
            selectColor(at: index)
        } else {
            selectColor(at: 0)
        }
        updateFontSizeLabel()
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        let text = textView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            dismiss(animated: true)
            return
        }

        var payload = existingPayload ?? TextPayload()
        payload.text = text
        payload.fontSize = CGFloat(fontSizeSlider.value)
        payload.colorHex = presetColors[selectedColorIndex].hex

        onCommit?(payload)
        dismiss(animated: true)
    }

    @objc private func fontSizeChanged() {
        updateFontSizeLabel()
    }

    @objc private func colorTapped(_ sender: UIButton) {
        selectColor(at: sender.tag)
    }

    // MARK: - Helpers

    private func selectColor(at index: Int) {
        selectedColorIndex = index
        for (i, button) in colorButtons.enumerated() {
            button.layer.borderColor = (i == index) ? UIColor.label.cgColor : UIColor.clear.cgColor
        }
    }

    private func updateFontSizeLabel() {
        fontSizeLabel.text = "Font Size: \(Int(fontSizeSlider.value))pt"
    }
}

// MARK: - UIColor Hex Helper

private extension UIColor {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
