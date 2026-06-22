import Metal
import AnimiEngineRenderModel

/// Corrective §1.4 / §7 — per-execution ownership of all Metal textures and staging buffers.
///
/// One `MetalResourceOwner` is created per `execute()` and dropped only after the command buffer completes
/// (plan §4: "resource lifetime through command completion"; "release after completion"). It holds the
/// per-resource raw+normalized textures (correction #2), offscreen/final surface textures, and staging
/// buffers, so they stay alive for the whole submission. Nothing here is process-global.
///
/// Lifecycle proof (C3, §7): `onDeinit` is a package-internal hook set only by tests; its `deinit` calls it
/// so a test can prove the engine released **all engine-owned references** (the owner and everything it
/// retains) after `execute()` returns — on both success and failure. It makes **no** claim about physical
/// `MTLTexture`/`MTLBuffer` destruction (the driver may retain internal references).
final class MetalResourceOwner {
    /// A pixel resource's raw upload texture + its normalized linear-premultiplied draw texture
    /// (correction #2). Scene draws may access **only** `normalized`; `raw` is the normalization input.
    struct PixelResourceTextures {
        let raw: MTLTexture
        let normalized: MTLTexture
    }

    /// resourceID → its raw+normalized pixel textures (pixel inputs), keyed by the original resourceID.
    private(set) var pixelResources: [String: PixelResourceTextures] = [:]
    /// surfaceID → its allocated offscreen/final surface texture.
    private(set) var surfaces: [String: MTLTexture] = [:]
    /// Staging buffers retained until completion (private-upload sources + the readback buffer).
    private(set) var stagingBuffers: [MTLBuffer] = []
    /// Step-11 (§7.7) transient GPU textures (MSAA coverage, resolved coverage, mask accumulators)
    /// owned per execution and released at completion.
    private(set) var transientTextures: [MTLTexture] = []
    /// CP7.8 — opaque CoreVideo backing objects (`CVPixelBuffer`/`CVMetalTexture`) for dynamic texture
    /// bindings, retained until command completion so their IOSurface stays valid for the GPU read (§9).
    private(set) var runtimeBindingRetains: [Any] = []

    /// Package-internal lifecycle hook (C3, §7): set only by tests. Called from `deinit`.
    var onDeinit: (() -> Void)?

    deinit {
        onDeinit?()
    }

    func registerPixelResource(_ textures: PixelResourceTextures, for resourceID: String) {
        pixelResources[resourceID] = textures
    }

    func registerSurface(_ texture: MTLTexture, for surfaceID: String) {
        surfaces[surfaceID] = texture
    }

    func retain(stagingBuffer: MTLBuffer) {
        stagingBuffers.append(stagingBuffer)
    }

    /// Retain a Step-11 transient texture until command completion (§7.7).
    func retainTransient(_ texture: MTLTexture) {
        transientTextures.append(texture)
    }

    /// CP7.8 — retain a dynamic texture binding's CoreVideo backing (`CVPixelBuffer`/`CVMetalTexture`)
    /// until command completion, so the IOSurface behind the bound raw texture cannot be recycled while
    /// the GPU reads it (§9 lifetime). The objects are held opaquely; the owner never inspects them.
    func retainRuntimeBinding(_ objects: [Any]) {
        runtimeBindingRetains.append(contentsOf: objects)
    }

    /// The **normalized** texture a scene draw must sample (correction #2: never the raw texture).
    func normalizedTexture(for resourceID: String) throws -> MTLTexture {
        guard let entry = pixelResources[resourceID] else {
            throw MetalRenderError.missingResource(resourceID: resourceID)
        }
        return entry.normalized
    }

    /// An offscreen/final surface texture.
    func surface(for surfaceID: String) throws -> MTLTexture {
        guard let texture = surfaces[surfaceID] else {
            throw MetalRenderError.missingResource(resourceID: surfaceID)
        }
        return texture
    }
}
