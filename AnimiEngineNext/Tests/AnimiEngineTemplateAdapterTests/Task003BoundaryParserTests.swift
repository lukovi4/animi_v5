import XCTest
import Foundation

/// Task-003 plan §4, G1 — focused negative tests for the structured `dump-package` verification used
/// by `Task003DependencyBoundaryTests`. These feed **synthetic JSON fixtures** (no SwiftPM
/// subprocess) to prove the dependency decoder fails closed and the product verifier rejects aliases,
/// duplicates, multi-target wrappers and any `RenderTestSupport` exposure.
final class Task003BoundaryParserTests: XCTestCase {

    private func decode(_ json: String) throws -> DumpedPackage {
        try DumpedPackage.decode(Data(json.utf8))
    }

    // MARK: - Dependency decoding: positive forms

    func testDecodesEachSupportedDependencyForm() throws {
        let json = """
        {"products":[],"targets":[
          {"name":"T","dependencies":[
            {"byName":["A",null]},
            {"target":["B",null]},
            {"product":["C",null]}
          ]}
        ]}
        """
        let pkg = try decode(json)
        XCTAssertEqual(try pkg.dependencyNames(of: "T"), ["A", "B", "C"])
    }

    // MARK: - Dependency decoding: fail-closed negatives

    func testEmptyDependencyObjectThrows() {
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{}]}]}"#
        XCTAssertThrowsError(try decode(json), "empty dependency object must fail closed")
    }

    func testUnknownDependencyFormThrows() {
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{"sourceControl":["X",null]}]}]}"#
        XCTAssertThrowsError(try decode(json), "unknown dependency form must fail closed")
    }

    func testAmbiguousMultiKeyDependencyThrows() {
        let json = """
        {"products":[],"targets":[{"name":"T","dependencies":[
          {"byName":["A",null],"target":["B",null]}
        ]}]}
        """
        XCTAssertThrowsError(try decode(json), "ambiguous multi-form dependency must fail closed")
    }

    func testNullDependencyNameThrows() {
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{"byName":[null,null]}]}]}"#
        XCTAssertThrowsError(try decode(json), "null dependency name must fail closed")
    }

    func testEmptyStringDependencyNameThrows() {
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{"byName":["",null]}]}]}"#
        XCTAssertThrowsError(try decode(json), "empty dependency name must fail closed")
    }

    func testEmptyDependencyArrayThrows() {
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{"byName":[]}]}]}"#
        XCTAssertThrowsError(try decode(json), "empty dependency value array must fail closed")
    }

    func testSupportedKeyPlusUnknownExtraKeyThrows() {
        // Exactly-one-TOTAL-key rule: a valid form plus any extra key is rejected.
        let json = """
        {"products":[],"targets":[{"name":"T","dependencies":[
          {"byName":["A",null],"unexpected":1}
        ]}]}
        """
        XCTAssertThrowsError(try decode(json), "supported key + extra key must fail closed")
    }

    func testOneElementDependencyArrayThrows() {
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{"byName":["A"]}]}]}"#
        XCTAssertThrowsError(try decode(json), "one-element value array must fail closed")
    }

    func testThreeElementDependencyArrayThrows() {
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{"byName":["A",null,null]}]}]}"#
        XCTAssertThrowsError(try decode(json), "three-element value array must fail closed")
    }

    func testInvalidSecondElementTypeThrows() {
        // The condition slot must be null or an array; a scalar string is invalid.
        let json = #"{"products":[],"targets":[{"name":"T","dependencies":[{"byName":["A","oops"]}]}]}"#
        XCTAssertThrowsError(try decode(json), "scalar second element must fail closed")
    }

    func testArrayConditionSecondElementIsAccepted() throws {
        // A genuine SwiftPM condition list (array) in the second slot is valid.
        let json = """
        {"products":[],"targets":[{"name":"T","dependencies":[
          {"byName":["A",[{"platformNames":["ios"]}]]}
        ]}]}
        """
        let pkg = try decode(json)
        XCTAssertEqual(try pkg.dependencyNames(of: "T"), ["A"])
    }

    func testMissingTargetLookupThrows() throws {
        let pkg = try decode(#"{"products":[],"targets":[]}"#)
        XCTAssertThrowsError(try pkg.dependencyNames(of: "Nope")) { error in
            XCTAssertEqual(error as? BoundaryProofError, .targetNotFound("Nope"))
        }
    }

    // MARK: - Product type: fail-closed

    func testProductTypeWithNoFormThrows() {
        let json = #"{"products":[{"name":"P","targets":["P"],"type":{}}],"targets":[]}"#
        XCTAssertThrowsError(try decode(json), "product type with no form must fail closed")
    }

    func testProductTypeWithMultipleFormsThrows() {
        let json = #"{"products":[{"name":"P","targets":["P"],"type":{"library":["automatic"],"executable":null}}],"targets":[]}"#
        XCTAssertThrowsError(try decode(json), "product type with two forms must fail closed")
    }

    func testUnrecognizedProductFormThrows() {
        // Exactly one key, but an unknown form must throw (not be treated as "not a library").
        let json = #"{"products":[{"name":"P","targets":["P"],"type":{"frobnicator":null}}],"targets":[]}"#
        XCTAssertThrowsError(try decode(json), "unrecognized product form must fail closed")
    }

    func testRecognizedNonLibraryProductFormDecodes() throws {
        // A recognized non-library form (e.g. executable) decodes and is simply not a library.
        let json = #"{"products":[{"name":"P","targets":["P"],"type":{"executable":null}}],"targets":[]}"#
        let pkg = try decode(json)
        XCTAssertEqual(pkg.products.count, 1)
        XCTAssertFalse(pkg.products[0].type.isLibrary)
    }

    // MARK: - Product verification: the exact-four happy case

    private func product(_ name: String, _ targets: [String], library: Bool = true) -> String {
        let type = library ? #"{"library":["automatic"]}"# : #"{"executable":null}"#
        let t = targets.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"name":"\#(name)","targets":[\#(t)],"type":\#(type)}"#
    }

    private func products(from objects: [String]) throws -> [DumpedPackage.Product] {
        try decode("{\"products\":[\(objects.joined(separator: ","))],\"targets\":[]}").products
    }

    private static let fourGood = [
        ("AnimiEngineRenderModel", "AnimiEngineRenderModel"),
        ("AnimiEngineTemplateAdapter", "AnimiEngineTemplateAdapter"),
        ("AnimiEngineRenderGraph", "AnimiEngineRenderGraph"),
        ("AnimiEngineMetalRender", "AnimiEngineMetalRender")
    ]

    private func fourGoodProducts() throws -> [DumpedPackage.Product] {
        try products(from: Self.fourGood.map { product($0.0, [$0.1]) })
    }

    func testApprovedFourProductsHaveNoViolations() throws {
        XCTAssertEqual(task003ProductViolations(in: try fourGoodProducts()), [])
    }

    // MARK: - Product verification: negatives

    func testRejectsProductExposingRenderTestSupport() throws {
        var objs = Self.fourGood.map { product($0.0, [$0.1]) }
        objs.append(product("AnimiEngineRenderTestSupport", ["AnimiEngineRenderTestSupport"]))
        let v = task003ProductViolations(in: try products(from: objs))
        XCTAssertTrue(v.contains { $0.contains("RenderTestSupport") }, "got \(v)")
    }

    func testRejectsAliasProductName() throws {
        // A product named like an approved one but wrapping a different (Task-003) target.
        var objs = Self.fourGood.dropLast().map { product($0.0, [$0.1]) }
        objs.append(product("AnimiEngineMetalRender", ["AnimiEngineRenderModel"]))   // alias/mismatch
        let v = task003ProductViolations(in: try products(from: objs))
        XCTAssertTrue(v.contains { $0.contains("must wrap exactly") }, "got \(v)")
    }

    func testRejectsMultiTargetWrapper() throws {
        var objs = Array(Self.fourGood.dropLast().map { product($0.0, [$0.1]) })
        objs.append(product("AnimiEngineMetalRender",
                            ["AnimiEngineMetalRender", "AnimiEngineRenderModel"]))   // multi-target
        let v = task003ProductViolations(in: try products(from: objs))
        XCTAssertTrue(v.contains { $0.contains("must wrap exactly") }, "got \(v)")
    }

    func testRejectsDuplicateProducts() throws {
        var objs = Self.fourGood.map { product($0.0, [$0.1]) }
        objs.append(product("AnimiEngineRenderModel", ["AnimiEngineRenderModel"]))   // duplicate
        let v = task003ProductViolations(in: try products(from: objs))
        XCTAssertTrue(v.contains { $0.contains("duplicate product") }, "got \(v)")
    }

    func testRejectsExtraTask003Product() throws {
        var objs = Self.fourGood.map { product($0.0, [$0.1]) }
        // An extra product wrapping a Task-003 target under a new name.
        objs.append(product("AnimiEngineMetalRenderExtras", ["AnimiEngineMetalRender"]))
        let v = task003ProductViolations(in: try products(from: objs))
        XCTAssertTrue(v.contains { $0.contains("unexpected Task-003 product") }, "got \(v)")
    }

    func testRejectsMissingApprovedProduct() throws {
        let objs = Self.fourGood.dropLast().map { product($0.0, [$0.1]) }   // only three
        let v = task003ProductViolations(in: try products(from: Array(objs)))
        XCTAssertTrue(v.contains { $0.contains("missing approved product") }, "got \(v)")
    }

    func testRejectsNonLibraryApprovedProduct() throws {
        var objs = Array(Self.fourGood.dropLast().map { product($0.0, [$0.1]) })
        objs.append(product("AnimiEngineMetalRender", ["AnimiEngineMetalRender"], library: false))
        let v = task003ProductViolations(in: try products(from: objs))
        XCTAssertTrue(v.contains { $0.contains("not a library") }, "got \(v)")
    }

    func testIgnoresUnrelatedProducts() throws {
        // Products not touching any Task-003 target are irrelevant and must not cause violations.
        var objs = Self.fourGood.map { product($0.0, [$0.1]) }
        objs.append(product("AnimiEngineCore", ["AnimiEngineCore"]))
        objs.append(product("SomethingElse", ["UnrelatedTarget"]))
        XCTAssertEqual(task003ProductViolations(in: try products(from: objs)), [])
    }
}
