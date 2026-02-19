import XCTest
@testable import TVECore

final class BackgroundPresetTests: XCTestCase {

    // MARK: - BackgroundMask Polygon Tests

    func testPolygonMaskDecode() throws {
        let json = """
        {
          "type": "polygon",
          "vertices": [
            {"x": 0, "y": 0},
            {"x": 100, "y": 0},
            {"x": 100, "y": 100},
            {"x": 0, "y": 100}
          ],
          "closed": true
        }
        """

        let mask = try JSONDecoder().decode(BackgroundMask.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(mask.type, .polygon)
        XCTAssertEqual(mask.vertices.count, 4)
        XCTAssertEqual(mask.vertices[0], Vec2D(x: 0, y: 0))
        XCTAssertEqual(mask.vertices[1], Vec2D(x: 100, y: 0))
        XCTAssertEqual(mask.vertices[2], Vec2D(x: 100, y: 100))
        XCTAssertEqual(mask.vertices[3], Vec2D(x: 0, y: 100))
        XCTAssertTrue(mask.closed)
        XCTAssertNil(mask.inTangents)
        XCTAssertNil(mask.outTangents)
    }

    func testPolygonMaskToBezierPath() throws {
        let mask = BackgroundMask(
            type: .polygon,
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100),
                Vec2D(x: 0, y: 100)
            ],
            closed: true
        )

        let path = try mask.toBezierPath()

        XCTAssertEqual(path.vertices.count, 4)
        XCTAssertEqual(path.inTangents.count, 4)
        XCTAssertEqual(path.outTangents.count, 4)
        XCTAssertTrue(path.closed)

        // All tangents should be zero for polygon
        for tangent in path.inTangents {
            XCTAssertEqual(tangent, .zero)
        }
        for tangent in path.outTangents {
            XCTAssertEqual(tangent, .zero)
        }
    }

    // MARK: - BackgroundMask Bezier Tests

    func testBezierMaskDecode() throws {
        let json = """
        {
          "type": "bezier",
          "vertices": [
            {"x": 0, "y": 0},
            {"x": 100, "y": 0},
            {"x": 100, "y": 100}
          ],
          "inTangents": [
            {"x": 0, "y": 0},
            {"x": -20, "y": 0},
            {"x": 0, "y": -20}
          ],
          "outTangents": [
            {"x": 20, "y": 0},
            {"x": 0, "y": 20},
            {"x": 0, "y": 0}
          ],
          "closed": true
        }
        """

        let mask = try JSONDecoder().decode(BackgroundMask.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(mask.type, .bezier)
        XCTAssertEqual(mask.vertices.count, 3)
        XCTAssertEqual(mask.inTangents?.count, 3)
        XCTAssertEqual(mask.outTangents?.count, 3)
        XCTAssertTrue(mask.closed)

        XCTAssertEqual(mask.inTangents?[1], Vec2D(x: -20, y: 0))
        XCTAssertEqual(mask.outTangents?[0], Vec2D(x: 20, y: 0))
    }

    func testBezierMaskToBezierPath() throws {
        let mask = BackgroundMask(
            type: .bezier,
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100)
            ],
            inTangents: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: -20, y: 0),
                Vec2D(x: 0, y: -20)
            ],
            outTangents: [
                Vec2D(x: 20, y: 0),
                Vec2D(x: 0, y: 20),
                Vec2D(x: 0, y: 0)
            ],
            closed: true
        )

        let path = try mask.toBezierPath()

        XCTAssertEqual(path.vertices.count, 3)
        XCTAssertEqual(path.inTangents.count, 3)
        XCTAssertEqual(path.outTangents.count, 3)
        XCTAssertTrue(path.closed)
        XCTAssertEqual(path.inTangents[1], Vec2D(x: -20, y: 0))
        XCTAssertEqual(path.outTangents[0], Vec2D(x: 20, y: 0))
    }

    // MARK: - Validation Error Tests

    func testPolygonMaskTooFewVertices() {
        let mask = BackgroundMask(
            type: .polygon,
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0)
            ],
            closed: true
        )

        XCTAssertThrowsError(try mask.toBezierPath()) { error in
            guard case BackgroundPresetError.invalidMask(let reason) = error else {
                XCTFail("Expected invalidMask error")
                return
            }
            XCTAssertTrue(reason.contains("vertices.count must be >= 3"))
        }
    }

    func testBezierMaskMissingTangents() {
        let mask = BackgroundMask(
            type: .bezier,
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100)
            ],
            inTangents: nil,  // Missing
            outTangents: nil, // Missing
            closed: true
        )

        XCTAssertThrowsError(try mask.toBezierPath()) { error in
            guard case BackgroundPresetError.invalidMask(let reason) = error else {
                XCTFail("Expected invalidMask error")
                return
            }
            XCTAssertTrue(reason.contains("requires inTangents and outTangents"))
        }
    }

    func testBezierMaskTangentsCountMismatch() {
        let mask = BackgroundMask(
            type: .bezier,
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100)
            ],
            inTangents: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 0, y: 0)
                // Only 2, should be 3
            ],
            outTangents: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 0, y: 0),
                Vec2D(x: 0, y: 0)
            ],
            closed: true
        )

        XCTAssertThrowsError(try mask.toBezierPath()) { error in
            guard case BackgroundPresetError.invalidMask(let reason) = error else {
                XCTFail("Expected invalidMask error")
                return
            }
            XCTAssertTrue(reason.contains("inTangents count mismatch"))
        }
    }

    // MARK: - BackgroundPreset Full Decode Tests

    func testPresetFullDecode() throws {
        let json = """
        {
          "presetId": "test_split",
          "title": "Test Split",
          "canvasSize": [1080, 1920],
          "regions": [
            {
              "regionId": "top",
              "displayName": "Top",
              "mask": {
                "type": "polygon",
                "vertices": [
                  {"x": 0, "y": 0},
                  {"x": 1080, "y": 0},
                  {"x": 1080, "y": 960},
                  {"x": 0, "y": 960}
                ],
                "closed": true
              },
              "uvMapping": "bbox"
            },
            {
              "regionId": "bottom",
              "displayName": "Bottom",
              "mask": {
                "type": "polygon",
                "vertices": [
                  {"x": 0, "y": 960},
                  {"x": 1080, "y": 960},
                  {"x": 1080, "y": 1920},
                  {"x": 0, "y": 1920}
                ],
                "closed": true
              },
              "uvMapping": "bbox"
            }
          ]
        }
        """

        let preset = try JSONDecoder().decode(BackgroundPreset.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(preset.presetId, "test_split")
        XCTAssertEqual(preset.title, "Test Split")
        XCTAssertEqual(preset.canvasSize, [1080, 1920])
        XCTAssertEqual(preset.regions.count, 2)

        XCTAssertEqual(preset.regions[0].regionId, "top")
        XCTAssertEqual(preset.regions[0].displayName, "Top")
        XCTAssertEqual(preset.regions[0].uvMapping, "bbox")
        XCTAssertEqual(preset.regions[0].mask.type, .polygon)

        XCTAssertEqual(preset.regions[1].regionId, "bottom")
        XCTAssertEqual(preset.regions[1].displayName, "Bottom")
    }

    // MARK: - Background Model Backward Compatibility Tests

    func testBackgroundLegacySolidDecode() throws {
        let json = """
        {
          "type": "solid",
          "color": "#FF0000"
        }
        """

        let background = try JSONDecoder().decode(Background.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(background.type, "solid")
        XCTAssertEqual(background.color, "#FF0000")
        XCTAssertNil(background.presetId)
        XCTAssertNil(background.defaults)

        // Backward compatibility: solid maps to solid_fullscreen
        XCTAssertEqual(background.effectivePresetId, "solid_fullscreen")
        XCTAssertEqual(background.effectiveColor, "#FF0000")
    }

    func testBackgroundPresetDecode() throws {
        let json = """
        {
          "type": "preset",
          "presetId": "wave_split",
          "defaults": {
            "top": {
              "sourceType": "solid",
              "solidColor": "#FFFFFF"
            },
            "bottom": {
              "sourceType": "gradient",
              "gradientLinear": {
                "stops": [
                  {"position": 0, "color": "#000000"},
                  {"position": 1, "color": "#FFFFFF"}
                ],
                "p0": {"x": 0, "y": 0},
                "p1": {"x": 0, "y": 1920}
              }
            }
          }
        }
        """

        let background = try JSONDecoder().decode(Background.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(background.type, "preset")
        XCTAssertEqual(background.presetId, "wave_split")
        XCTAssertEqual(background.effectivePresetId, "wave_split")
        XCTAssertNil(background.color)

        XCTAssertNotNil(background.defaults)
        XCTAssertEqual(background.defaults?["top"]?.sourceType, "solid")
        XCTAssertEqual(background.defaults?["top"]?.solidColor, "#FFFFFF")
        XCTAssertEqual(background.defaults?["bottom"]?.sourceType, "gradient")
        XCTAssertEqual(background.defaults?["bottom"]?.gradientLinear?.stops.count, 2)
    }

    // MARK: - Gradient Stop Tests

    func testGradientStopsDecode() throws {
        let json = """
        {
          "stops": [
            {"position": 0.0, "color": "#FF0000"},
            {"position": 1.0, "color": "#0000FF"}
          ],
          "p0": {"x": 0, "y": 0},
          "p1": {"x": 1080, "y": 0}
        }
        """

        let gradient = try JSONDecoder().decode(GradientLinearDefault.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(gradient.stops.count, 2)
        XCTAssertEqual(gradient.stops[0].position, 0.0)
        XCTAssertEqual(gradient.stops[0].color, "#FF0000")
        XCTAssertEqual(gradient.stops[1].position, 1.0)
        XCTAssertEqual(gradient.stops[1].color, "#0000FF")
        XCTAssertEqual(gradient.p0, Vec2D(x: 0, y: 0))
        XCTAssertEqual(gradient.p1, Vec2D(x: 1080, y: 0))
    }

    // MARK: - Overscan Coordinates Tests

    func testMaskWithOverscanCoordinates() throws {
        let json = """
        {
          "type": "polygon",
          "vertices": [
            {"x": -20, "y": -20},
            {"x": 1100, "y": -20},
            {"x": 1100, "y": 1940},
            {"x": -20, "y": 1940}
          ],
          "closed": true
        }
        """

        let mask = try JSONDecoder().decode(BackgroundMask.self, from: json.data(using: .utf8)!)
        let path = try mask.toBezierPath()

        // Overscan coordinates should be preserved
        XCTAssertEqual(path.vertices[0], Vec2D(x: -20, y: -20))
        XCTAssertEqual(path.vertices[1], Vec2D(x: 1100, y: -20))
        XCTAssertEqual(path.vertices[2], Vec2D(x: 1100, y: 1940))
        XCTAssertEqual(path.vertices[3], Vec2D(x: -20, y: 1940))
    }

    // MARK: - PR2: BackgroundRegionState Tests

    func testSolidConfigCreation() {
        let color = ClearColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
        let config = SolidConfig(color: color)
        let source = RegionSource.solid(config)
        let state = BackgroundRegionState(regionId: "test", source: source)

        XCTAssertEqual(state.regionId, "test")
        if case .solid(let c) = state.source {
            XCTAssertEqual(c.color.red, 1.0)
            XCTAssertEqual(c.color.green, 0.5)
            XCTAssertEqual(c.color.blue, 0.0)
            XCTAssertEqual(c.color.alpha, 1.0)
        } else {
            XCTFail("Expected solid source")
        }
    }

    func testGradientConfigValidation() throws {
        // Valid gradient with exactly 2 stops
        let validConfig = GradientConfig(
            stops: [
                BackgroundGradientStop(t: 0.0, color: ClearColor(red: 1, green: 0, blue: 0, alpha: 1)),
                BackgroundGradientStop(t: 1.0, color: ClearColor(red: 0, green: 0, blue: 1, alpha: 1))
            ],
            p0: Vec2D(x: 0, y: 0),
            p1: Vec2D(x: 0, y: 1920)
        )

        XCTAssertNoThrow(try validConfig.validate())
    }

    func testGradientConfigValidationFailsTooFewStops() {
        let invalidConfig = GradientConfig(
            stops: [
                BackgroundGradientStop(t: 0.0, color: ClearColor(red: 1, green: 0, blue: 0, alpha: 1))
            ],
            p0: Vec2D(x: 0, y: 0),
            p1: Vec2D(x: 0, y: 1920)
        )

        XCTAssertThrowsError(try invalidConfig.validate()) { error in
            guard case BackgroundRendererError.invalidGradientStops(let expected, let actual) = error else {
                XCTFail("Expected invalidGradientStops error")
                return
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(actual, 1)
        }
    }

    func testGradientConfigValidationFailsTooManyStops() {
        let invalidConfig = GradientConfig(
            stops: [
                BackgroundGradientStop(t: 0.0, color: ClearColor(red: 1, green: 0, blue: 0, alpha: 1)),
                BackgroundGradientStop(t: 0.5, color: ClearColor(red: 0, green: 1, blue: 0, alpha: 1)),
                BackgroundGradientStop(t: 1.0, color: ClearColor(red: 0, green: 0, blue: 1, alpha: 1))
            ],
            p0: Vec2D(x: 0, y: 0),
            p1: Vec2D(x: 0, y: 1920)
        )

        XCTAssertThrowsError(try invalidConfig.validate()) { error in
            guard case BackgroundRendererError.invalidGradientStops(let expected, let actual) = error else {
                XCTFail("Expected invalidGradientStops error")
                return
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(actual, 3)
        }
    }

    func testImageConfigCreation() {
        let transform = ImageTransform(
            pan: Vec2D(x: 0.1, y: 0.2),
            zoom: 1.5,
            rotationRadians: 0.0,
            flipX: false,
            flipY: true,
            fitMode: .fill
        )
        let config = ImageConfig(slotKey: "bg/test/region", transform: transform)
        let source = RegionSource.image(config)
        let state = BackgroundRegionState(regionId: "region", source: source)

        if case .image(let c) = state.source {
            XCTAssertEqual(c.slotKey, "bg/test/region")
            XCTAssertEqual(c.transform.pan.x, 0.1)
            XCTAssertEqual(c.transform.pan.y, 0.2)
            XCTAssertEqual(c.transform.zoom, 1.5)
            XCTAssertFalse(c.transform.flipX)
            XCTAssertTrue(c.transform.flipY)
            XCTAssertEqual(c.transform.fitMode, .fill)
        } else {
            XCTFail("Expected image source")
        }
    }

    func testImageTransformIdentity() {
        let identity = ImageTransform.identity

        XCTAssertEqual(identity.pan, .zero)
        XCTAssertEqual(identity.zoom, 1.0)
        XCTAssertEqual(identity.rotationRadians, 0.0)
        XCTAssertFalse(identity.flipX)
        XCTAssertFalse(identity.flipY)
        XCTAssertEqual(identity.fitMode, .fill)
    }

    func testEffectiveBackgroundState() {
        let preset = BackgroundPreset(
            presetId: "test",
            title: "Test",
            canvasSize: [1080, 1920],
            regions: []
        )

        let solidState = BackgroundRegionState(
            regionId: "region1",
            source: .solid(SolidConfig(color: ClearColor(red: 1, green: 0, blue: 0, alpha: 1)))
        )

        let effectiveState = EffectiveBackgroundState(
            preset: preset,
            regionStates: ["region1": solidState]
        )

        XCTAssertEqual(effectiveState.preset.presetId, "test")
        XCTAssertNotNil(effectiveState.state(for: "region1"))
        XCTAssertNil(effectiveState.state(for: "nonexistent"))
    }

    func testBackgroundFitModeEncode() throws {
        let fill = BackgroundFitMode.fill
        let fit = BackgroundFitMode.fit

        let encoder = JSONEncoder()
        let fillData = try encoder.encode(fill)
        let fitData = try encoder.encode(fit)

        XCTAssertEqual(String(data: fillData, encoding: .utf8), "\"fill\"")
        XCTAssertEqual(String(data: fitData, encoding: .utf8), "\"fit\"")
    }

    func testBackgroundFitModeDecode() throws {
        let decoder = JSONDecoder()
        let fill = try decoder.decode(BackgroundFitMode.self, from: "\"fill\"".data(using: .utf8)!)
        let fit = try decoder.decode(BackgroundFitMode.self, from: "\"fit\"".data(using: .utf8)!)

        XCTAssertEqual(fill, .fill)
        XCTAssertEqual(fit, .fit)
    }
}
