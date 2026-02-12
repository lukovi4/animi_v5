import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// Regression tests for correct z-order (layer stacking order).
///
/// AE/Lottie stacking convention: layers earlier in the array are visually on top.
/// The renderer must iterate layers in reverse order to produce correct z-order
/// (bottom layers drawn first, top layers drawn last).
///
/// Golden fixture: `polaroid_full/data.json` — frame layer (image_0) must be
/// rendered after media layer (image_2) to appear on top.
final class LayerOrderTests: XCTestCase {
    private var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - Golden Fixture: polaroid_full z-order

    /// Verifies that in polaroid_full, the frame (image_0) is rendered AFTER media (image_2).
    ///
    /// In the Lottie JSON, comp_0 layers are ordered:
    /// - [0] polaroid.png (image_0) — frame, should be ON TOP
    /// - [3] media (image_2) — user media placeholder, should be BELOW frame
    ///
    /// Correct render order: drawImage(image_2) BEFORE drawImage(image_0)
    /// This ensures the frame overlays the media.
    func testPolaroidFull_frameRenderedAfterMedia_correctZOrder() throws {
        // Load golden fixture
        guard let url = Bundle.module.url(
            forResource: "data",
            withExtension: "json",
            subdirectory: "Resources/polaroid_full"
        ) else {
            XCTFail("Could not find data.json in Resources/polaroid_full")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        // Build asset index from Lottie assets
        var assetById: [String: String] = [:]
        for asset in lottie.assets {
            if let relativePath = asset.relativePath {
                assetById[asset.id] = relativePath
            }
        }
        let assetIndex = AssetIndex(byId: assetById)

        // Compile
        var registry = PathRegistry()
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "polaroid_full.json",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &registry
        )

        // Generate render commands
        let commands = ir.renderCommands(frameIndex: 0)

        // Find indices of drawImage commands for frame (image_0) and media (image_2)
        var idxFrame: Int?
        var idxMedia: Int?

        for (index, cmd) in commands.enumerated() {
            if case .drawImage(let assetId, _) = cmd {
                // Asset IDs are namespaced: "polaroid_full.json|image_0"
                if assetId.hasSuffix("image_0") {
                    idxFrame = index
                } else if assetId.hasSuffix("image_2") {
                    idxMedia = index
                }
            }
        }

        // Verify both layers are present
        guard let frameIndex = idxFrame else {
            XCTFail("drawImage for frame (image_0) not found in render commands")
            return
        }
        guard let mediaIndex = idxMedia else {
            XCTFail("drawImage for media (image_2) not found in render commands")
            return
        }

        // Assert: media must be rendered BEFORE frame (lower z-order)
        XCTAssertLessThan(
            mediaIndex, frameIndex,
            "Media (image_2) must be rendered before frame (image_0) for correct z-order. " +
            "Got: media at \(mediaIndex), frame at \(frameIndex)"
        )
    }

    // MARK: - Basic z-order: 3 layers in root comp

    /// Verifies basic z-order with 3 layers in root composition.
    /// Layer order in JSON: [A, B, C] → render order should be [C, B, A]
    func testBasicZOrder_threeLayers_renderedBottomToTop() throws {
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":100,"h":100,"nm":"T","ddd":0,
          "assets":[
            {"id":"img_a","w":100,"h":100,"u":"","p":"a.png","e":0},
            {"id":"img_b","w":100,"h":100,"u":"","p":"b.png","e":0},
            {"id":"img_c","w":100,"h":100,"u":"","p":"c.png","e":0}
          ],
          "layers":[
            {"ddd":0,"ind":1,"ty":2,"nm":"A","refId":"img_a","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},"a":{"a":0,"k":[50,50,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":2,"nm":"media","refId":"img_b","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},"a":{"a":0,"k":[50,50,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":3,"ty":2,"nm":"C","refId":"img_c","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},"a":{"a":0,"k":[50,50,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0}
          ],"markers":[]
        }
        """

        let data = json.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        var registry = PathRegistry()
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: AssetIndex(byId: [:]),
            pathRegistry: &registry
        )

        let commands = ir.renderCommands(frameIndex: 0)

        // Extract drawImage order
        var drawOrder: [String] = []
        for cmd in commands {
            if case .drawImage(let assetId, _) = cmd {
                // Extract just the image name part
                if assetId.contains("img_a") {
                    drawOrder.append("A")
                } else if assetId.contains("img_b") {
                    drawOrder.append("B")
                } else if assetId.contains("img_c") {
                    drawOrder.append("C")
                }
            }
        }

        // Expected: C first (bottom), then B, then A (top)
        XCTAssertEqual(
            drawOrder, ["C", "B", "A"],
            "Layers should be rendered bottom-to-top (C, B, A). Got: \(drawOrder)"
        )
    }
}
