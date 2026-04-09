import Foundation

/// Describes how a project was created — replaces template-only identity.
public enum ProjectOrigin: Codable, Equatable, Sendable {
    case template(templateId: String)
    case blank(starterSceneTypeId: String)
    case duplicate(sourceProjectId: UUID)

    /// Extracts templateId from `.template` case; nil for blank/duplicate.
    public var templateId: String? {
        if case .template(let id) = self { return id }
        return nil
    }

    /// Human-readable title for listing/display purposes.
    public var displayTitle: String {
        switch self {
        case .template(let templateId):
            return templateId
        case .blank:
            return "Blank Project"
        case .duplicate:
            return "Duplicated Project"
        }
    }
}
