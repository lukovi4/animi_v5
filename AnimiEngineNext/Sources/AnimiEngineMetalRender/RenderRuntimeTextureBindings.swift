import Metal

/// CP7.8 — runtime GPU texture bindings for dynamic texture-backed pixel inputs (user video frames).
///
/// This is the execution-time counterpart of a `RenderResourceDescriptor` with
/// `kind == .dynamicTexturePixelInput`: the canonical graph carries ONLY value metadata (source id,
/// dims, format, orientation/quarter-turn), and the actual raw `MTLTexture` is supplied here, keyed by
/// the descriptor's `resourceID` (== its `dynamicTextureSourceID`).
///
/// These types live in the MetalRender execution layer ONLY. They are NOT `Sendable`, NOT part of the
/// canonical RenderModel/RenderGraph, and never serialized or hashed — a runtime GPU handle must never
/// enter a canonical value (CP7.8 hard rule 1). The executor consumes bindings ONLY on the
/// `render(_:into:textureBindings:)` path; the `execute(_:)` readback/ReferenceData path never sees them.
///
/// Lifetime (CP7.8 §9): a `RuntimeTextureHandle` strongly retains the `CVPixelBuffer` (IOSurface backing)
/// and `CVMetalTexture` (Metal↔IOSurface mapping) behind its `texture` via `retain`, so the IOSurface
/// cannot be recycled while a command buffer reads it. The executor keeps the whole
/// `RenderRuntimeTextureBindings` alive until its command buffer completes.

/// A raw, display-untransformed GPU texture for one dynamic pixel input, plus the CoreVideo objects that
/// back it (held until command-buffer completion). The texture is the decoder's native-orientation BGRA.
public struct RuntimeTextureHandle {
    /// The raw decoded BGRA texture (track-native orientation; the normalization pass applies the
    /// quarter-turn from the descriptor). `.bgra8Unorm`, `.shaderRead`, on the session device.
    public let texture: MTLTexture
    /// Opaque retained backing (e.g. `CVPixelBuffer`, `CVMetalTexture`) kept alive until the consuming
    /// command buffer completes. The executor never inspects these — it only holds them.
    public let retain: [Any]

    public init(texture: MTLTexture, retain: [Any]) {
        self.texture = texture
        self.retain = retain
    }
}

/// The map `resourceID → RuntimeTextureHandle` passed alongside a graph to `render(_:into:textureBindings:)`.
/// Every `dynamicTexturePixelInput` resource in the graph MUST have a binding here, or the executor fails
/// closed with a typed error (no silent fallback).
public struct RenderRuntimeTextureBindings {
    private let bindings: [String: RuntimeTextureHandle]

    /// An empty binding map — the default for the readback / photo-only paths.
    public static let none = RenderRuntimeTextureBindings([:])

    public init(_ bindings: [String: RuntimeTextureHandle]) {
        self.bindings = bindings
    }

    public func handle(for resourceID: String) -> RuntimeTextureHandle? {
        bindings[resourceID]
    }

    public var isEmpty: Bool { bindings.isEmpty }
}
