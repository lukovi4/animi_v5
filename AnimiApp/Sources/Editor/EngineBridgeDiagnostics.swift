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

// MARK: - CP6: AnimiEngineNext video EXPORT bridge (DEBUG only)
//
// Independent opt-in flag for routing VIDEO EXPORT frames through AnimiEngineNext (CP6),
// separate from the preview flag above. The production export default is unaffected unless a
// developer explicitly opts in at runtime. Compiled only in DEBUG; defaults to OFF.
//
// Photo/image scope only: any unsupported capability (video/text/sticker/custom background,
// unknown transition) FAILS CLOSED with a typed visible error — never a silent old-render fallback.
enum NextExportEngineToggles {
    /// When true, `EditorRuntimeExportController` renders exported frames through AnimiEngineNext
    /// (CP6) instead of the production TVECore export runners. Default OFF.
    ///
    /// Launch argument: `-DebugExportWithNextEngine YES`
    /// Runtime toggle: `UserDefaults.standard.set(true, forKey: "DebugExportWithNextEngine")`
    static var exportWithNextEngine: Bool {
        UserDefaults.standard.bool(forKey: "DebugExportWithNextEngine")
    }

    static let defaultsKey = "DebugExportWithNextEngine"
}
#endif
