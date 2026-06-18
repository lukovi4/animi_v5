import Foundation

/// Payload written to `device.json` (Task-001 plan, "Evidence contract").
///
/// Task 001 makes **no media or hardware-capability calls** — this is a small, explicitly-provided
/// descriptor. Production may supply real values; tests supply fixed values so the artifact is
/// byte-stable. Serialization is deterministic (sorted keys).
public struct DeviceInfo: Equatable, Sendable {
    public let model: String
    public let systemName: String
    public let systemVersion: String

    public init(model: String, systemName: String, systemVersion: String) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
    }

    /// Deterministic, sorted-key JSON encoding (no trailing newline).
    public func canonicalJSON() -> String {
        var output = "{"
        output += "\"model\":"; appendJSONString(model, into: &output)
        output += ",\"systemName\":"; appendJSONString(systemName, into: &output)
        output += ",\"systemVersion\":"; appendJSONString(systemVersion, into: &output)
        output += "}"
        return output
    }
}
