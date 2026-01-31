import UIKit
import TVECore

/// Transparent overlay view drawn on top of Metal rendering surface.
/// Displays interactive block outlines using CAShapeLayer.
///
/// PR-19: Editor overlay — CAShapeLayer-based (lead-approved).
/// `isUserInteractionEnabled = false` — all gestures go to metalView underneath.
final class EditorOverlayView: UIView {

    // MARK: - Properties

    /// Canvas-to-View affine transform. Set by controller on layout changes.
    /// Must match the Metal renderer's contain (aspect-fit) mapping.
    var canvasToView: CGAffineTransform = .identity

    // MARK: - Layers

    private var selectedLayer: CAShapeLayer?
    private var inactiveLayers: [CAShapeLayer] = []

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Update

    /// Update overlay display with current block overlays.
    ///
    /// - Parameters:
    ///   - overlays: From `player.overlays(frame:)` — hit paths in canvas coords.
    ///   - selectedBlockId: Currently selected block (nil = none selected).
    func update(overlays: [MediaInputOverlay], selectedBlockId: String?) {
        // Remove old layers
        selectedLayer?.removeFromSuperlayer()
        selectedLayer = nil
        inactiveLayers.forEach { $0.removeFromSuperlayer() }
        inactiveLayers.removeAll()

        guard !overlays.isEmpty else { return }

        for overlay in overlays {
            let isSelected = overlay.blockId == selectedBlockId

            let shapeLayer = CAShapeLayer()
            shapeLayer.frame = bounds

            // Convert BezierPath (canvas coords) -> CGPath -> view coords
            let canvasPath = overlay.hitPath.cgPath
            var transform = canvasToView
            let viewPath = canvasPath.copy(using: &transform)

            shapeLayer.path = viewPath
            shapeLayer.fillColor = nil
            shapeLayer.contentsScale = UIScreen.main.scale  // retina-sharp lines

            if isSelected {
                shapeLayer.strokeColor = UIColor.systemBlue.cgColor
                shapeLayer.lineWidth = 2.0
                shapeLayer.lineDashPattern = nil
                self.selectedLayer = shapeLayer
            } else {
                shapeLayer.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
                shapeLayer.lineWidth = 1.0
                shapeLayer.lineDashPattern = [4, 4]
                inactiveLayers.append(shapeLayer)
                layer.addSublayer(shapeLayer)
            }
        }

        // Selected added once, on top of all inactive layers
        if let sel = selectedLayer {
            layer.addSublayer(sel)
        }
    }
}
