import Foundation
import Metal

/// Task-003 plan §9.3 (approved R2) — the shader-library loading seam.
///
/// `MTLLibrary` is obtained through this protocol so the loading strategy can change **without touching
/// `MetalRenderSession`** (plan §9.3, correction #13). The canonical production loader is
/// `BundledShaderLibraryLoader`; `RuntimeSourceShaderLoader` is retained as a narrow injectable loader for
/// tests. Only `Bundle.module` is used — never `Bundle.main`, never a platform check, never a silent
/// fallback.
protocol ShaderLibraryLoader {
    func makeLibrary(device: MTLDevice) throws -> MTLLibrary
}

/// The bundled shader resource basename.
private enum ShaderResource {
    static let name = "AnimiEngineRender"
    static let metalExtension = "metal"
}

/// **Canonical production loader.** Loads the Metal library from the package resource bundle
/// (`Bundle.module`) using whichever form the build pipeline produced — without a platform check:
///
/// 1. **If `AnimiEngineRender.metal` source is present in `Bundle.module`** (the macOS `swift build`
///    pipeline copies the `.metal` as a resource): read it and compile via `device.makeLibrary(source:)`.
///    A read error or a compile error is a **typed failure** (`shaderSourceUnavailable` /
///    `shaderCompilationFailed`); it does **NOT** silently fall through to the metallib path.
///
/// 2. **If the source is absent** (the Xcode resource pipeline compiles `.metal` into a `default.metallib`
///    inside the same bundle): load the compiled library via
///    `device.makeDefaultLibrary(bundle: Bundle.module)`. Any failure is the typed
///    `shaderLibraryUnavailable`.
///
/// This is the device-gate finding's fix: on iPhone (Xcode) the bundle ships a compiled `default.metallib`,
/// while on macOS (`swift build`) it ships the `.metal` source — `Bundle.module` plus the
/// source-present-vs-absent decision selects the right one with no `Bundle.main`, no `#if os(...)`, and no
/// silent fallback.
struct BundledShaderLibraryLoader: ShaderLibraryLoader {
    func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let url = Bundle.module.url(
            forResource: ShaderResource.name, withExtension: ShaderResource.metalExtension) {
            // Source present (macOS swift build) → compile it. Failures are typed; no metallib fallback.
            let source: String
            do {
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw MetalRenderError.shaderSourceUnavailable
            }
            do {
                return try device.makeLibrary(source: source, options: nil)
            } catch {
                throw MetalRenderError.shaderCompilationFailed(detail: String(describing: error))
            }
        }
        // Source absent (Xcode compiled it to default.metallib) → load the compiled library.
        do {
            return try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            throw MetalRenderError.shaderLibraryUnavailable(detail: String(describing: error))
        }
    }
}

/// Narrow **injectable test loader**: always compiles the bundled `AnimiEngineRender.metal` source at
/// runtime via `device.makeLibrary(source:)`. Used by tests that want to pin the source-compilation path;
/// production uses `BundledShaderLibraryLoader`. Only `Bundle.module` is used.
struct RuntimeSourceShaderLoader: ShaderLibraryLoader {
    static let resourceName = ShaderResource.name
    static let resourceExtension = ShaderResource.metalExtension

    func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        guard let url = Bundle.module.url(
            forResource: Self.resourceName, withExtension: Self.resourceExtension)
        else {
            throw MetalRenderError.shaderSourceUnavailable
        }
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MetalRenderError.shaderSourceUnavailable
        }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw MetalRenderError.shaderCompilationFailed(detail: String(describing: error))
        }
    }
}
