import Foundation

// MARK: - CP2: AnimiEngineNext single-scene preview bridge (DEBUG only)
//
// This file gates the experimental CP2 vertical slice that renders ONE frame of a
// single-scene template through AnimiEngineNext instead of the production TVECore path.
//
// The flag defaults to OFF. The production default render path is unaffected unless a
// developer explicitly opts in at runtime. The entire bridge is compiled only in DEBUG.
//
// Mirrors the established `ScrubDebugToggles` idiom (UserDefaults-backed, launch-argument
// settable, e.g. `-DebugRenderWithNextEngine YES`).

#if DEBUG
enum NextEngineBridgeToggles {
    /// When true, `EditorViewController.draw(in:)` attempts to render the current
    /// single-scene frame through AnimiEngineNext (CP2). Default OFF.
    ///
    /// Launch argument: `-DebugRenderWithNextEngine YES`
    /// Runtime toggle: `UserDefaults.standard.set(true, forKey: "DebugRenderWithNextEngine")`
    static var renderWithNextEngine: Bool {
        UserDefaults.standard.bool(forKey: "DebugRenderWithNextEngine")
    }

    static let defaultsKey = "DebugRenderWithNextEngine"
}
#endif
