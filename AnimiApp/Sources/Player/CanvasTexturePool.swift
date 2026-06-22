#if DEBUG
import Foundation
import Metal

// MARK: - CP7.7-next: bounded canvas-texture pool for GPU-direct preview (DEBUG only)
//
// The GPU-direct preview path renders each frame into a CANVAS-sized MTLTexture (NOT the MTKView drawable,
// which is the view/letterbox size — `MetalRenderSession.render(_:into:)` requires the target to equal the
// canvas) and then MPS-scales that texture into the drawable.
//
// LIFETIME (provably-safe reuse). A canvas texture must NOT be handed to a renderer while ANY GPU command
// buffer is still reading it. An earlier version returned a replaced front texture to the pool SYNCHRONOUSLY
// while its MPS present command buffer was still in flight, so the pool re-checked-out that texture and
// `render(into:)` could overwrite it mid-read (a render-vs-present reuse hazard → potential corruption).
// This pool's lifetime gate is an independent correctness invariant.
//
// This pool now tracks, per texture, BOTH:
//   * `isFront`        — it is the currently displayed front buffer (may be re-presented on a redundant draw);
//   * `inFlightReads`  — the number of committed-but-not-yet-completed MPS present command buffers reading it.
// A texture is eligible for checkout ONLY when `!isFront && inFlightReads == 0`. So illegal reuse is
// impossible: a texture that is on screen, or still being sampled by a GPU present, can never be rendered into.
//
// Thread-safety: checkout/setFront happen on the render queue + main; `retainForPresent`/`releaseAfterPresent`
// fire from a GPU completion thread. One lock guards all mutable state.

/// A checked-out canvas texture handle. The underlying `MTLTexture` is owned by the pool. Reuse-eligibility
/// is `!isFront && inFlightReads == 0` (see pool). Identity is reference identity.
final class CanvasTextureHandle {
    let texture: MTLTexture
    /// True while this is the currently displayed front buffer.
    fileprivate(set) var isFront: Bool = false
    /// Number of committed, not-yet-completed MPS present command buffers sampling this texture.
    fileprivate(set) var inFlightReads: Int = 0
    /// True once `render(into:)` has finished writing it (GPU write complete) — i.e. presentable.
    fileprivate(set) var rendered: Bool = false
    /// The single reuse gate: a texture is checkout-eligible ONLY when `released == true`. It is set false
    /// at checkout (the texture is now in use: rendering → presenting) and set true again ONLY when the
    /// texture is provably idle — no GPU command buffer reads or writes it and it is not on screen. This is
    /// what makes the reuse hazard impossible: a rendering/presenting/front texture is never `released`.
    fileprivate(set) var released: Bool = false

    fileprivate init(texture: MTLTexture) { self.texture = texture }

    /// True when no present read is in flight AND it is not the front buffer (the two GPU-visibility
    /// conditions). `release` may flip `released` true only when this holds.
    fileprivate var isIdle: Bool { !isFront && inFlightReads == 0 }

    /// Test-only: a handle NOT owned by any pool.
    static func makeForTesting(texture: MTLTexture) -> CanvasTextureHandle {
        CanvasTextureHandle(texture: texture)
    }
    /// Test-only mirror of the reuse-eligibility gate.
    var isReusableForTesting: Bool { released }
}

/// Bounded pool of canvas-sized `.bgra8Unorm` `[.renderTarget,.shaderRead]` `.private` textures.
final class CanvasTexturePool {
    private let device: MTLDevice
    private let maxTextures: Int

    private let lock = NSLock()
    /// Canvas pixel size this pool's textures are allocated for. A size change drains + reallocates.
    private var canvasWidth = 0
    private var canvasHeight = 0
    /// Every texture the pool owns, in allocation order.
    private var all: [CanvasTextureHandle] = []

    /// `maxTextures` ≈ 8: render outpaces vsync-locked present, so several frames can be in flight, AND the
    /// front buffer holds one slot. One 1080×1920 bgra8 ≈ 8.3MB → ~66MB.
    init(device: MTLDevice, maxTextures: Int = 8) {
        self.device = device
        self.maxTextures = max(2, maxTextures)
    }

    /// Check out a REUSE-ELIGIBLE texture for `width×height`, or allocate a new one (bounded). Returns nil
    /// only if every owned texture is still front/in-flight AND the cap is reached — the caller then keeps
    /// the last good frame (soft skip). A canvas-size change drains the pool first.
    func checkout(width: Int, height: Int) -> CanvasTextureHandle? {
        lock.lock(); defer { lock.unlock() }
        guard width > 0, height > 0 else { return nil }

        if width != canvasWidth || height != canvasHeight {
            canvasWidth = width; canvasHeight = height
            all.removeAll()   // old textures still in flight are released when their reads drain (unowned no-op)
        }

        if let free = all.first(where: { $0.released }) {
            free.released = false   // taken: now in use (rendering → presenting) until provably idle again
            free.rendered = false
            return free
        }
        guard all.count < maxTextures else { return nil }  // bounded — never allocate past the cap
        guard let tex = makeTexture(width: width, height: height) else { return nil }
        let handle = CanvasTextureHandle(texture: tex)  // released defaults false → in use immediately
        all.append(handle)
        return handle
    }

    /// Re-checkout the SAME idle texture would be unsafe mid-flight; reuse is gated entirely by `released`.
    /// `releaseIfIdle` flips `released` true ONLY when the texture is provably idle (not front, no reads).
    private func releaseIfIdle(_ handle: CanvasTextureHandle) {
        if handle.isIdle { handle.released = true }
    }

    /// Mark `render(into:)` complete (GPU write done) — the texture is now presentable.
    func markRendered(_ handle: CanvasTextureHandle) {
        lock.lock(); defer { lock.unlock() }
        guard all.contains(where: { $0 === handle }) else { return }
        handle.rendered = true
    }

    /// Explicitly return a checked-out texture that was NEVER presented (render failed, or a stale-epoch /
    /// superseded handle the editor never adopted). Safe to reuse immediately ONLY because it is idle
    /// (no front, no reads) — asserted by `releaseIfIdle`.
    func releaseUnpresented(_ handle: CanvasTextureHandle) {
        lock.lock(); defer { lock.unlock() }
        guard all.contains(where: { $0 === handle }) else { return }
        releaseIfIdle(handle)
    }

    /// A MPS present command buffer that samples `handle` was just COMMITTED — count one in-flight read.
    /// Pair EXACTLY with `releaseAfterPresent` in that command buffer's completion handler.
    func retainForPresent(_ handle: CanvasTextureHandle) {
        lock.lock(); defer { lock.unlock() }
        guard all.contains(where: { $0 === handle }) else { return }
        handle.inFlightReads += 1
        handle.released = false   // a texture being read is never reuse-eligible
    }

    /// A present command buffer sampling `handle` COMPLETED — drop one in-flight read. Called from the
    /// command buffer completion handler (GPU finished reading). Becomes reuse-eligible iff now idle.
    func releaseAfterPresent(_ handle: CanvasTextureHandle) {
        lock.lock(); defer { lock.unlock() }
        guard all.contains(where: { $0 === handle }) else { return }
        if handle.inFlightReads > 0 { handle.inFlightReads -= 1 }
        releaseIfIdle(handle)
    }

    /// Promote `handle` to the displayed front buffer; demote the previous front. The demoted front becomes
    /// reuse-eligible ONLY if it is now idle (its in-flight reads already drained) — otherwise it stays
    /// non-reusable until its `releaseAfterPresent` fires.
    func setFront(_ handle: CanvasTextureHandle) {
        lock.lock(); defer { lock.unlock() }
        for t in all where t.isFront && t !== handle {
            t.isFront = false
            releaseIfIdle(t)
        }
        if all.contains(where: { $0 === handle }) { handle.isFront = true; handle.released = false }
    }

    /// Drop the front mark from the current front (e.g. media change / teardown). It becomes reuse-eligible
    /// only once idle.
    func clearFront() {
        lock.lock(); defer { lock.unlock() }
        for t in all where t.isFront {
            t.isFront = false
            releaseIfIdle(t)
        }
    }

    /// Drop all textures (memory pressure / releasePreviewResources). In-flight reads still complete; their
    /// `releaseAfterPresent` no-ops (unowned) and the `MTLTexture` is released when the last reference drops.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        all.removeAll()
        canvasWidth = 0; canvasHeight = 0
    }

    /// Test/diagnostic snapshot.
    var snapshotForTesting: (total: Int, reusable: Int, front: Int, inFlight: Int) {
        lock.lock(); defer { lock.unlock() }
        return (
            all.count,
            all.filter { $0.released }.count,
            all.filter { $0.isFront }.count,
            all.filter { $0.inFlightReads > 0 }.count)
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]   // renderTarget for render(into:), shaderRead for MPS
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }
}
#endif
