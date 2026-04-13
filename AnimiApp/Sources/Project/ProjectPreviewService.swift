import Foundation

/// App-level seam for preview resolution.
///
/// Replaces direct `TemplateDescriptor.previewURL` access with an
/// indirection that allows future expansion to saved-project previews.
@MainActor
public final class ProjectPreviewService {

    private let catalogProvider: TemplateCatalogProviding

    init(catalogProvider: TemplateCatalogProviding) {
        self.catalogProvider = catalogProvider
    }

    enum PreviewResult {
        case videoReady(URL)
        case notAvailable
    }

    func resolveTemplatePreview(templateId: TemplateID) -> PreviewResult {
        guard let template = catalogProvider.template(by: templateId),
              let url = template.previewURL else {
            return .notAvailable
        }
        return .videoReady(url)
    }

    // Future seam: func resolveProjectPreview(projectId: UUID) -> PreviewResult
}
