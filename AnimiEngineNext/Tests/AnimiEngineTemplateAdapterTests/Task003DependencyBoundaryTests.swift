import XCTest
import Foundation
// Importing every Task-003 production module here links them with only this test target's allowed
// dependencies. That catches a *forbidden transitive dependency* sneaking in, but on its own it does
// NOT prove the *exact* per-target dependency sets — that proof is the structured manifest check
// below, which parses `swift package dump-package` JSON.
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineTemplateAdapter
import AnimiEngineRenderGraph
import AnimiEngineMetalRender

// MARK: - Structured `dump-package` model (shared with the parser/product negative tests)

/// A fail-closed decoding of the subset of `swift package dump-package` JSON this suite verifies.
/// "Fail closed" means an unexpected shape is a hard `DecodingError`, never a silently-dropped or
/// nil-named dependency — an undetected malformed edge could otherwise hide a forbidden dependency.
struct DumpedPackage: Decodable {
    let products: [Product]
    let targets: [Target]

    struct Product: Decodable {
        let name: String
        let targets: [String]
        let type: ProductType
    }

    /// `"type": { "library": [...] }` / `{ "executable": null }` / `{ "plugin": ... }` etc.
    ///
    /// Fail-closed contract:
    ///   * the object must have **exactly one total key** (zero or two+ throws);
    ///   * that key must be an **explicitly recognized** SwiftPM product form — an unknown form
    ///     throws rather than being treated as "not a library".
    struct ProductType: Decodable {
        /// The product forms SwiftPM's `dump-package` is known to emit.
        static let recognizedForms: Set<String> = [
            "library", "executable", "plugin", "snippet", "test", "macro"
        ]

        let isLibrary: Bool
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            let keys = container.allKeys.map { $0.stringValue }
            guard keys.count == 1, let only = keys.first else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "product type must have exactly one total key, got \(keys.sorted())"))
            }
            guard ProductType.recognizedForms.contains(only) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unrecognized product form '\(only)'"))
            }
            isLibrary = (only == "library")
        }
    }

    struct Target: Decodable {
        let name: String
        let dependencies: [Dependency]
    }

    /// A single target dependency. SwiftPM encodes each as an object with exactly one key whose value
    /// is a two-element array `[<name>, <condition-or-null>]`.
    ///
    /// Fail-closed contract:
    ///   * the object must have **exactly one total key** — a supported key plus any extra key throws;
    ///   * that key must be one of `byName` / `target` / `product`;
    ///   * the value array must have **exactly two** elements;
    ///   * element 0 must be a **non-empty String** (the dependency name);
    ///   * element 1 must match the supported condition shape (`null` or an array of conditions);
    ///     any other type (string/number/bool/object) throws;
    ///   * `name` is non-optional — there is no nil/compactMap escape hatch.
    struct Dependency: Decodable {
        static let supportedForms: Set<String> = ["byName", "target", "product"]

        let form: String
        let name: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            let keys = container.allKeys.map { $0.stringValue }

            // Exactly one TOTAL key — a supported key with an extra unknown key is rejected.
            guard keys.count == 1, let form = keys.first else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "dependency must have exactly one total key, got \(keys.sorted())"))
            }
            guard Dependency.supportedForms.contains(form) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "unsupported dependency form '\(form)' (allowed: \(Dependency.supportedForms.sorted()))"))
            }

            // The value is a fixed two-element array: [name, condition].
            let key = DynamicKey(stringValue: form)!
            var array = try container.nestedUnkeyedContainer(forKey: key)

            let name = try array.decode(String.self)              // element 0 — must be a String
            guard !name.isEmpty else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: array.codingPath,
                    debugDescription: "dependency '\(form)' name must be a non-empty string"))
            }
            _ = try array.decode(DependencyCondition.self)        // element 1 — null or [conditions]
            guard array.isAtEnd else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: array.codingPath,
                    debugDescription: "dependency '\(form)' value must have exactly two elements"))
            }

            self.form = form
            self.name = name
        }
    }

    /// The second array element of a dependency: SwiftPM emits either `null` (unconditional) or an
    /// array of platform/configuration conditions. Any scalar/object in this slot is rejected.
    enum DependencyCondition: Decodable {
        case unconditional
        case conditions([JSONAny])
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .unconditional
                return
            }
            // Must be an array; a string/number/bool/object here is invalid.
            if let array = try? single.decode([JSONAny].self) {
                self = .conditions(array)
                return
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "dependency condition must be null or an array of conditions"))
        }
    }

    /// Minimal opaque JSON value, used only to accept (without interpreting) the contents of a
    /// dependency condition array.
    struct JSONAny: Decodable {
        init(from decoder: Decoder) throws {
            // Accept any JSON node without inspecting it.
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { return }
            if (try? container.decode(Bool.self)) != nil { return }
            if (try? container.decode(Double.self)) != nil { return }
            if (try? container.decode(String.self)) != nil { return }
            if (try? container.decode([JSONAny].self)) != nil { return }
            if (try? container.decode([String: JSONAny].self)) != nil { return }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unsupported JSON node"))
        }
    }

    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func decode(_ data: Data) throws -> DumpedPackage {
        try JSONDecoder().decode(DumpedPackage.self, from: data)
    }

    func dependencyNames(of targetName: String) throws -> Set<String> {
        guard let target = targets.first(where: { $0.name == targetName }) else {
            throw BoundaryProofError.targetNotFound(targetName)
        }
        // No compactMap: every dependency has a non-optional name by construction.
        return Set(target.dependencies.map { $0.name })
    }
}

enum BoundaryProofError: Error, Equatable {
    case targetNotFound(String)
}

// MARK: - Pure product verification (shared with negative tests)

/// The four approved 1:1 product→target mappings (§4.1). Each library product must wrap exactly its
/// own same-named target and nothing else.
let task003ApprovedProductMappings: [String: String] = [
    "AnimiEngineRenderModel": "AnimiEngineRenderModel",
    "AnimiEngineTemplateAdapter": "AnimiEngineTemplateAdapter",
    "AnimiEngineRenderGraph": "AnimiEngineRenderGraph",
    "AnimiEngineMetalRender": "AnimiEngineMetalRender"
]

let task003AllTargets: Set<String> = [
    "AnimiEngineRenderModel", "AnimiEngineTemplateAdapter",
    "AnimiEngineRenderGraph", "AnimiEngineMetalRender",
    "AnimiEngineRenderTestSupport"
]

/// Verify the products that touch any Task-003 target. Returns a list of human-readable violations;
/// an empty result means the products exactly match the four approved mappings with no alias,
/// duplicate, multi-target wrapper, or `RenderTestSupport` exposure (§4.1/§4.2).
func task003ProductViolations(in products: [DumpedPackage.Product]) -> [String] {
    var violations: [String] = []

    // Every product whose targets intersect the five Task-003 targets is relevant.
    let relevant = products.filter { !Set($0.targets).isDisjoint(with: task003AllTargets) }

    // Reject duplicate product names among relevant products.
    var seen = Set<String>()
    for product in relevant where !seen.insert(product.name).inserted {
        violations.append("duplicate product '\(product.name)'")
    }

    // Reject any relevant product exposing the support target.
    for product in relevant where product.targets.contains("AnimiEngineRenderTestSupport") {
        violations.append("product '\(product.name)' exposes AnimiEngineRenderTestSupport (§4.2)")
    }

    // The set of relevant product names must equal exactly the four approved names.
    let relevantNames = Set(relevant.map { $0.name })
    let approvedNames = Set(task003ApprovedProductMappings.keys)
    for extra in relevantNames.subtracting(approvedNames).sorted() {
        violations.append("unexpected Task-003 product '\(extra)'")
    }
    for missing in approvedNames.subtracting(relevantNames).sorted() {
        violations.append("missing approved product '\(missing)'")
    }

    // Each approved product must be a single-target library wrapping exactly its own target (no
    // alias: product name == its one target; no multi-target wrapper).
    for (productName, expectedTarget) in task003ApprovedProductMappings {
        let matches = relevant.filter { $0.name == productName }
        guard matches.count == 1, let product = matches.first else { continue }  // count handled above
        if !product.type.isLibrary {
            violations.append("product '\(productName)' is not a library")
        }
        if product.targets != [expectedTarget] {
            violations.append(
                "product '\(productName)' must wrap exactly [\(expectedTarget)], got \(product.targets)")
        }
    }

    return violations.sorted()
}

/// Task-003 plan §4 (package architecture), §13 row "Isolation", acceptance gate G1.
final class Task003DependencyBoundaryTests: XCTestCase {

    // MARK: - Package layout discovery (deterministic, from this file's path)

    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AnimiEngineTemplateAdapterTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AnimiEngineNext (package root)
    }

    private static let forbiddenModules: Set<String> = ["TVECore", "TVECompilerCore", "AnimiApp"]

    private static let task003SourceTargets = [
        "Sources/AnimiEngineRenderModel",
        "Sources/AnimiEngineTemplateAdapter",
        "Sources/AnimiEngineRenderGraph",
        "Sources/AnimiEngineMetalRender",
        "Sources/AnimiEngineRenderTestSupport"
    ]

    private func dumpPackage() throws -> DumpedPackage {
        // Run `swift package dump-package` against a SEPARATE scratch directory. The running test is
        // already holding the package's `.build` lock; pointing the subprocess at its own scratch
        // path avoids contending for that lock (which otherwise deadlocks), and keeps stdout pure
        // JSON. The scratch dir is unique per run and cleaned up afterwards.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("aen-dump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "dump-package",
                             "--package-path", Self.packageRoot().path,
                             "--scratch-path", scratch.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "swift package dump-package failed")
        return try DumpedPackage.decode(data)
    }

    // MARK: - Exact dependency sets (§4.1/§4.2, G1)

    func testExactDependencySetsForAllTask003Targets() throws {
        let pkg = try dumpPackage()

        let expected: [String: Set<String>] = [
            "AnimiEngineRenderModel":     ["AnimiEngineCore"],
            "AnimiEngineTemplateAdapter": ["AnimiEngineCore", "AnimiEngineRenderModel"],
            "AnimiEngineRenderGraph":     ["AnimiEngineCore", "AnimiEngineRenderModel"],
            "AnimiEngineMetalRender":     ["AnimiEngineRenderModel", "AnimiEngineRenderGraph"],
            "AnimiEngineRenderTestSupport": [
                "AnimiEngineCore", "AnimiEngineRenderModel", "AnimiEngineTemplateAdapter",
                "AnimiEngineRenderGraph", "AnimiEngineMetalRender",
                "AnimiEngineDiagnostics", "AnimiEngineTestSupport"
            ]
        ]
        for (target, expectedDeps) in expected {
            let actual = try pkg.dependencyNames(of: target)
            XCTAssertEqual(actual, expectedDeps,
                           "\(target) dependency set mismatch: got \(actual.sorted())")
        }
        XCTAssertEqual(try pkg.dependencyNames(of: "AnimiEngineRenderTestSupport").count, 7)
    }

    func testNoTask003TargetDependsOnForbiddenModules() throws {
        let pkg = try dumpPackage()
        for target in pkg.targets {
            let deps = Set(target.dependencies.map { $0.name })   // no compactMap
            let forbidden = deps.intersection(Self.forbiddenModules)
            XCTAssertTrue(forbidden.isEmpty,
                          "\(target.name) depends on forbidden module(s) \(forbidden.sorted())")
        }
    }

    // MARK: - Products (§4.1 exactly four library products; §4.2 support is not a product)

    func testExactlyFourTask003LibraryProductsAndSupportIsNotAProduct() throws {
        let pkg = try dumpPackage()
        let violations = task003ProductViolations(in: pkg.products)
        XCTAssertTrue(violations.isEmpty, "product verification violations: \(violations)")
    }

    // MARK: - Static source import scan (complements the manifest proof)

    func testNoTask003SourceImportsForbiddenModules() throws {
        let root = Self.packageRoot()
        var scannedFileCount = 0
        for target in Self.task003SourceTargets {
            let dir = root.appendingPathComponent(target, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                scannedFileCount += 1
                for module in Self.forbiddenModules {
                    XCTAssertFalse(
                        text.contains("import \(module)"),
                        "\(file.lastPathComponent) imports forbidden module \(module)")
                }
            }
        }
        XCTAssertGreaterThan(scannedFileCount, 0, "expected to scan at least the Stage-2 skeleton files")
    }
}
