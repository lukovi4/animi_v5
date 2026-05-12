import Foundation

/// Default audio policy for newly imported video slots.
/// Centralizes the "unmuted by default" decision so preview and export share the same defaults.
public enum VideoAudioPolicy {
    public static let defaultIsMuted: Bool = false
    public static let defaultVolume: Float = 1.0
}
