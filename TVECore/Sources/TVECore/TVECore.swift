// TVECore - Template Video Engine Core
// Main entry point for the engine

import Foundation

/// TVECore version information
public enum TVECore {
    /// Current version of TVECore
    public static let version = "0.1.0"
}

// MARK: - Public API Exports

// Models
@_exported import struct Foundation.URL

// Note: All model types are already public and will be available
// when importing TVECore. This file serves as the main entry point
// and version information provider.
