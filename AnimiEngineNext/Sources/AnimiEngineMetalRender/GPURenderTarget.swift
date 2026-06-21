import Metal

/// CP7.6a — a validated external GPU texture the engine may write the final composited sRGB pixels into,
/// as an alternative to the CPU readback path (`MetalRenderSession.execute(_:) -> RenderedFrame`).
///
/// The caller owns `texture` and its lifetime (e.g. a `CVPixelBuffer`-backed texture from a
/// `CVMetalTextureCache`). After `MetalRenderSession.render(_:into:)` returns, the GPU write to
/// `texture` is complete (the call is synchronous: commit + wait, exactly like `execute(_:)`).
///
/// This type carries NO bytes and computes NO hash — it is purely a GPU destination. The byte-exact
/// readback contract (`RenderedFrame.rawOutputHash`, the ReferenceData oracle) stays solely on
/// `execute(_:)`, which is unchanged.
public struct GPURenderTarget {
    public let texture: MTLTexture
    public let alphaMode: AlphaMode

    public init(texture: MTLTexture, alphaMode: AlphaMode) {
        self.texture = texture
        self.alphaMode = alphaMode
    }
}

/// How the engine writes alpha into a `GPURenderTarget`.
public enum AlphaMode: Sendable, Equatable {
    /// Write the final premultiplied sRGB value straight through — byte-identical to what the readback
    /// path produces (used for compositing onto a transparent/own-cleared destination).
    case preserveAlpha
    /// Composite premultiplied-over-transparent onto opaque black: keep the premultiplied B/G/R
    /// (already == colour·alpha over black) and force alpha = 1.0 (255). This is the GPU equivalent of
    /// the export CPU `compositeOpaque` (NextVideoExportRunner). Used for opaque video export.
    case opaqueBlack
}
