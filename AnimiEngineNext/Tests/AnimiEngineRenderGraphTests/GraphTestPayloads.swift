import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel

/// Test-only helper: a minimal valid `RenderCommandPayload` for a given category (corrected payload
/// schema), used by graph determinism/validation tests that only care about category/ordinal structure.
enum GraphTestPayloads {
    static func minimal(_ category: RenderCommandCategory) -> RenderCommandPayload {
        let t = FixedAffineTransform2D.identity
        let op = OpacityScalar.opaque
        let rect = (try? FixedRect(x: CanvasScalar(rawValue: 0), y: CanvasScalar(rawValue: 0),
                                   width: CanvasScalar(rawValue: 1), height: CanvasScalar(rawValue: 1)))!
        let mesh = try! SampledPathMesh(
            pathID: 0,
            positions: [CanvasScalar(rawValue: 0), CanvasScalar(rawValue: 0),
                        CanvasScalar(rawValue: 65536), CanvasScalar(rawValue: 0),
                        CanvasScalar(rawValue: 65536), CanvasScalar(rawValue: 65536)],
            indices: [0, 1, 2], closed: true)
        let color = try! SampledSRGBAColor(components: [.one, .zero, .zero, .one])
        let maskOp = SampledMaskOperation(mode: .add, inverted: false, opacity: op, mesh: mesh, pathToTarget: t)
        let pixels = try! ResolvedPixelInput(
            id: try! PixelInputID("r"),
            dimensions: try! PixelDimensions(width: 1, height: 1, bytesPerRow: 4, format: .bgra8),
            bytes: Data(count: 4))
        let lin = RenderSurface.linearCanvas
        switch category {
        case .clearBackground: return .clearBackground(color: .transparentBlack, targetSurfaceID: lin)
        case .declareResource: return .declareResource(RenderResourceDescriptor(pixelInputID: "r", pixels: pixels, colorContract: .task003))
        case .offscreenSurface: return .offscreenSurface(RenderResourceDescriptor(offscreenID: lin, width: 1, height: 1, profile: .intermediate(.rgba16FloatLinear), colorContract: .task003))
        case .beginScene: return .beginScene(sceneID: "sc", role: .sole, targetSurfaceID: lin)
        case .endScene: return .endScene(sceneID: "sc", role: .sole, targetSurfaceID: lin)
        case .drawImage: return .drawImage(resourceID: "r", transform: t, opacity: op, targetSurfaceID: lin)
        case .drawVideoFrame: return .drawVideoFrame(resourceID: "r", transform: t, opacity: op, targetSurfaceID: lin)
        case .drawShape: return .drawShape(shape: try! SampledShape(fillMesh: mesh, fillColor: color, fillOpacity: op, stroke: nil, groupOpacity: op), transform: t, opacity: op, targetSurfaceID: lin)
        case .beginClip: return .beginClip(rect: rect)
        case .endClip: return .endClip
        case .beginMask: return .beginMask(operations: [maskOp], contentSurfaceID: "content", targetSurfaceID: lin)
        case .endMask: return .endMask(contentSurfaceID: "content", targetSurfaceID: lin)
        case .matteLink: return .matteLink(mode: .alpha, sourceLayerID: 1, consumerLayerID: 2, sourceSurfaceID: "s", consumerSurfaceID: "c", targetSurfaceID: lin)
        case .fadeTransition: return .fadeTransition(easedProgress: .zero, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: lin)
        case .slideTransition: return .slideTransition(direction: .left, easedProgress: .zero, offsetX: 0, offsetY: 0, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: lin)
        case .overlay: return .overlay(resourceID: "r", transform: t, opacity: op, compositionOrder: 0, targetSurfaceID: lin)
        case .finalLinearToSRGB: return .finalLinearToSRGB(sourceSurfaceID: lin, targetSurfaceID: RenderSurface.sRGBSurface)
        case .finalOutput: return .finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface)
        }
    }
}
