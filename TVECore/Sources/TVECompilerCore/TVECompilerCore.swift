// TVECompilerCore — Build-time compiler module
//
// This module contains all source pipeline types that are NOT needed in runtime:
// - ScenePackageLoader / AnimLoader (source JSON loaders)
// - SceneValidator / AnimValidator (validation)
// - AnimIRCompiler (Lottie → AnimIR compilation)
// - SceneCompiler (full scene compilation orchestration)
// - CompiledScenePackageWriter (writes .tve files)
// - Lottie/* types (Lottie JSON parsing models)
// - ScenePackage / LoadedAnimations (source pipeline models)
//
// TVECompilerCore depends on TVECore and re-exports runtime types automatically.
//
// Usage:
// - CLI (TVETemplateCompiler): import TVECompilerCore
// - AnimiApp DEBUG: #if DEBUG import TVECompilerCore #endif
// - AnimiApp Release: import TVECore only (no compiler code linked)

@_exported import TVECore
