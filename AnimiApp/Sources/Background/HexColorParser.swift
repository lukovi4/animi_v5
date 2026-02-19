import Foundation
import TVECore

// MARK: - Hex Color Parser

/// Utility for parsing hex color strings to ClearColor.
/// Supports #RRGGBB and #RRGGBBAA formats.
public enum HexColorParser {

    /// Parses a hex color string to ClearColor.
    ///
    /// Supported formats:
    /// - `#RRGGBB` (alpha = 1.0)
    /// - `#RRGGBBAA`
    /// - `RRGGBB` (without #)
    /// - `RRGGBBAA` (without #)
    ///
    /// - Parameter hex: Hex color string
    /// - Returns: ClearColor or nil if parsing fails
    public static func parse(_ hex: String) -> ClearColor? {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove # prefix if present
        if cleanHex.hasPrefix("#") {
            cleanHex = String(cleanHex.dropFirst())
        }

        // Validate length
        guard cleanHex.count == 6 || cleanHex.count == 8 else {
            return nil
        }

        // Parse hex value
        guard let hexValue = UInt64(cleanHex, radix: 16) else {
            return nil
        }

        let r, g, b, a: Double

        if cleanHex.count == 6 {
            // #RRGGBB
            r = Double((hexValue >> 16) & 0xFF) / 255.0
            g = Double((hexValue >> 8) & 0xFF) / 255.0
            b = Double(hexValue & 0xFF) / 255.0
            a = 1.0
        } else {
            // #RRGGBBAA
            r = Double((hexValue >> 24) & 0xFF) / 255.0
            g = Double((hexValue >> 16) & 0xFF) / 255.0
            b = Double((hexValue >> 8) & 0xFF) / 255.0
            a = Double(hexValue & 0xFF) / 255.0
        }

        return ClearColor(r: r, g: g, b: b, a: a)
    }

    /// Parses a hex color string with fallback to black.
    ///
    /// - Parameter hex: Hex color string
    /// - Returns: ClearColor (black if parsing fails)
    public static func parseOrBlack(_ hex: String) -> ClearColor {
        parse(hex) ?? ClearColor(r: 0, g: 0, b: 0, a: 1)
    }

    /// Converts ClearColor to hex string.
    ///
    /// - Parameters:
    ///   - color: Color to convert
    ///   - includeAlpha: Whether to include alpha component
    /// - Returns: Hex string with # prefix
    public static func toHex(_ color: ClearColor, includeAlpha: Bool = false) -> String {
        let r = UInt8(min(max(color.r, 0), 1) * 255)
        let g = UInt8(min(max(color.g, 0), 1) * 255)
        let b = UInt8(min(max(color.b, 0), 1) * 255)

        if includeAlpha {
            let a = UInt8(min(max(color.a, 0), 1) * 255)
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        } else {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }
}
