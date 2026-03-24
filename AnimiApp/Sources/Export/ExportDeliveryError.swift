import Foundation

enum ExportDeliveryError: LocalizedError {
    case permissionDenied
    case permissionRestricted
    case authorizationFailed
    case exportFileMissing
    case saveFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:     return "Photo library access was denied."
        case .permissionRestricted: return "Photo library access is restricted on this device."
        case .authorizationFailed:  return "Could not authorize photo library access."
        case .exportFileMissing:    return "The exported video file is missing."
        case .saveFailed(let err):  return err?.localizedDescription ?? "Failed to save video to Photos."
        }
    }
}
