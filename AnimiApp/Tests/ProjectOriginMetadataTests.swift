import XCTest
import TVECore
@testable import AnimiApp

/// Tests for ProjectOrigin Codable roundtrip, computed properties, and display titles.
final class ProjectOriginMetadataTests: XCTestCase {

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip_template() throws {
        let origin = ProjectOrigin.template(templateId: "tpl_sunset")
        let data = try JSONEncoder().encode(origin)
        let decoded = try JSONDecoder().decode(ProjectOrigin.self, from: data)
        XCTAssertEqual(decoded, origin)
    }

    func testCodableRoundtrip_blank() throws {
        let origin = ProjectOrigin.blank(starterSceneTypeId: "scene_empty")
        let data = try JSONEncoder().encode(origin)
        let decoded = try JSONDecoder().decode(ProjectOrigin.self, from: data)
        XCTAssertEqual(decoded, origin)
    }

    func testCodableRoundtrip_duplicate() throws {
        let sourceId = UUID()
        let origin = ProjectOrigin.duplicate(sourceProjectId: sourceId)
        let data = try JSONEncoder().encode(origin)
        let decoded = try JSONDecoder().decode(ProjectOrigin.self, from: data)
        XCTAssertEqual(decoded, origin)
    }

    // MARK: - templateId Computed Property

    func testTemplateId_template_returnsValue() {
        let origin = ProjectOrigin.template(templateId: "tpl_abc")
        XCTAssertEqual(origin.templateId, "tpl_abc")
    }

    func testTemplateId_blank_returnsNil() {
        let origin = ProjectOrigin.blank(starterSceneTypeId: "scene_1")
        XCTAssertNil(origin.templateId)
    }

    func testTemplateId_duplicate_returnsNil() {
        let origin = ProjectOrigin.duplicate(sourceProjectId: UUID())
        XCTAssertNil(origin.templateId)
    }

    // MARK: - displayTitle

    func testDisplayTitle_template_returnsTemplateId() {
        let origin = ProjectOrigin.template(templateId: "my_template")
        XCTAssertEqual(origin.displayTitle, "my_template")
    }

    func testDisplayTitle_blank_returnsBlankProject() {
        let origin = ProjectOrigin.blank(starterSceneTypeId: "scene_1")
        XCTAssertEqual(origin.displayTitle, "Blank Project")
    }

    func testDisplayTitle_duplicate_returnsDuplicatedProject() {
        let origin = ProjectOrigin.duplicate(sourceProjectId: UUID())
        XCTAssertEqual(origin.displayTitle, "Duplicated Project")
    }
}
