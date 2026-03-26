import UIKit
import TVECore

/// Overlay view displaying per-block ingest status indicators (processing spinner, failure badge).
/// Positioned above EditorOverlayView in the preview container z-order.
/// Non-interactive — passes all touches through.
final class MediaIngestStatusOverlayView: UIView {

    // MARK: - Properties

    /// Canvas-to-View affine transform. Set by controller on layout changes.
    var canvasToView: CGAffineTransform = .identity

    /// Managed subview containers keyed by blockId, for efficient reuse/removal.
    private var containersByBlockId: [String: UIView] = [:]

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Update

    /// Updates overlay indicators based on current ingest statuses.
    /// - Parameters:
    ///   - overlays: Block overlay geometries from ScenePlayer.
    ///   - statusesByBlockId: Current ingest status per block ID.
    ///   - showsStatus: Whether status indicators should be displayed.
    func update(
        overlays: [MediaInputOverlay],
        statusesByBlockId: [String: IngestSlotStatus],
        showsStatus: Bool
    ) {
        guard showsStatus else {
            clearAll()
            return
        }

        var activeBlockIds = Set<String>()

        for overlay in overlays {
            let blockId = overlay.blockId
            guard let status = statusesByBlockId[blockId] else {
                // No status or idle — remove if exists
                removeContainer(for: blockId)
                continue
            }

            switch status {
            case .processing:
                activeBlockIds.insert(blockId)
                showProcessing(for: blockId, rectCanvas: overlay.rectCanvas)

            case .failed:
                activeBlockIds.insert(blockId)
                showFailed(for: blockId, rectCanvas: overlay.rectCanvas)

            case .idle, .ready:
                removeContainer(for: blockId)
            }
        }

        // Remove containers for blocks no longer in overlays
        let staleIds = Set(containersByBlockId.keys).subtracting(activeBlockIds)
        for blockId in staleIds {
            removeContainer(for: blockId)
        }
    }

    // MARK: - Private: Processing Indicator

    private func showProcessing(for blockId: String, rectCanvas: RectD) {
        let viewRect = canvasRect(rectCanvas)
        let container = ensureContainer(for: blockId)
        container.frame = viewRect

        // Rebuild contents if needed (tag 100 = processing, 200 = failed)
        if container.tag != 100 {
            container.subviews.forEach { $0.removeFromSuperview() }
            container.tag = 100

            // Semi-transparent overlay
            container.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            container.layer.cornerRadius = 4

            // Centered stack: spinner + label
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = .white
            spinner.startAnimating()
            spinner.translatesAutoresizingMaskIntoConstraints = false

            let label = UILabel()
            label.text = "Loading..."
            label.textColor = .white
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false

            let stack = UIStackView(arrangedSubviews: [spinner, label])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        } else {
            container.frame = viewRect
        }
    }

    // MARK: - Private: Failure Badge

    private func showFailed(for blockId: String, rectCanvas: RectD) {
        let viewRect = canvasRect(rectCanvas)
        let container = ensureContainer(for: blockId)
        container.frame = viewRect

        if container.tag != 200 {
            container.subviews.forEach { $0.removeFromSuperview() }
            container.tag = 200
            container.backgroundColor = .clear

            // Red error pill anchored to top-right
            let pill = UIView()
            pill.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
            pill.layer.cornerRadius = 8
            pill.translatesAutoresizingMaskIntoConstraints = false

            let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
            icon.tintColor = .white
            icon.translatesAutoresizingMaskIntoConstraints = false

            let label = UILabel()
            label.text = "Failed"
            label.textColor = .white
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false

            let stack = UIStackView(arrangedSubviews: [icon, label])
            stack.axis = .horizontal
            stack.spacing = 3
            stack.translatesAutoresizingMaskIntoConstraints = false

            pill.addSubview(stack)
            container.addSubview(pill)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
                stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
                stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
                stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
                icon.widthAnchor.constraint(equalToConstant: 12),
                icon.heightAnchor.constraint(equalToConstant: 12),
                pill.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            ])
        } else {
            container.frame = viewRect
        }
    }

    // MARK: - Private: Container Management

    private func ensureContainer(for blockId: String) -> UIView {
        if let existing = containersByBlockId[blockId] {
            return existing
        }
        let container = UIView()
        container.clipsToBounds = true
        addSubview(container)
        containersByBlockId[blockId] = container
        return container
    }

    private func removeContainer(for blockId: String) {
        containersByBlockId[blockId]?.removeFromSuperview()
        containersByBlockId.removeValue(forKey: blockId)
    }

    private func clearAll() {
        for (_, container) in containersByBlockId {
            container.removeFromSuperview()
        }
        containersByBlockId.removeAll()
    }

    private func canvasRect(_ rect: RectD) -> CGRect {
        let origin = CGPoint(x: rect.x, y: rect.y).applying(canvasToView)
        let size = CGSize(width: rect.width, height: rect.height)
        let transformedSize = CGSize(
            width: size.width * abs(canvasToView.a) + size.height * abs(canvasToView.c),
            height: size.width * abs(canvasToView.b) + size.height * abs(canvasToView.d)
        )
        return CGRect(origin: origin, size: transformedSize)
    }
}
