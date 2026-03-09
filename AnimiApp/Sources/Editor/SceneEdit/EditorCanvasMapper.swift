import UIKit
import TVECore

// MARK: - PR-D: Editor Canvas Mapper

/// Pure math for canvas ↔ view coordinate transforms.
/// Uses aspect-fit (contain) mapping matching Metal renderer.
///
/// - Note: `SizeD` for canvasSize (engine uses double), `CGSize` for viewSize (UIKit).
struct EditorCanvasMapper {

    /// Canvas size in scene units (Double precision for canvas math).
    var canvasSize: SizeD = .zero

    /// View size in UIKit points.
    var viewSize: CGSize = .zero

    // MARK: - Transforms

    /// Returns canvas-to-view affine transform (aspect-fit).
    /// Matches Metal renderer's contain mapping.
    func canvasToViewTransform() -> CGAffineTransform {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return .identity
        }

        let targetRect = RectD(
            x: 0,
            y: 0,
            width: Double(viewSize.width),
            height: Double(viewSize.height)
        )

        let m = GeometryMapping.animToInputContain(animSize: canvasSize, inputRect: targetRect)
        return CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
    }

    /// Converts view point to canvas point.
    func viewToCanvas(_ viewPoint: CGPoint) -> CGPoint {
        viewPoint.applying(canvasToViewTransform().inverted())
    }

    /// Converts canvas point to view point.
    func canvasToView(_ canvasPoint: CGPoint) -> CGPoint {
        canvasPoint.applying(canvasToViewTransform())
    }

    /// Converts view delta to canvas delta (scale only, no offset).
    /// Used for pan gesture translation.
    func viewDeltaToCanvas(_ delta: CGPoint) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return delta
        }

        let containScale = min(
            Double(viewSize.width) / canvasSize.width,
            Double(viewSize.height) / canvasSize.height
        )

        guard containScale > 0 else { return delta }

        return CGPoint(
            x: Double(delta.x) / containScale,
            y: Double(delta.y) / containScale
        )
    }

    /// Returns the scale factor from canvas to view.
    func scale() -> CGFloat {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return 1.0
        }

        return CGFloat(min(
            Double(viewSize.width) / canvasSize.width,
            Double(viewSize.height) / canvasSize.height
        ))
    }
}
