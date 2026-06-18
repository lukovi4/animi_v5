import Foundation
import AnimiEngineCore

/// A **test-only** structural reading of one real template (Task-002 plan, §9).
///
/// The current `scene.json` files describe reusable media-binding *slots*, not instantiated project
/// media. They must not be fabricated directly as resolved canonical scenes. This descriptor reads
/// the authoring structure and lets tests assert that authoring fields, variants, timing, and
/// binding keys are representable — then instantiate deterministically with explicit fake bindings.
public struct TemplateFixtureDescriptor: Equatable, Sendable {
    public let catalogID: String
    public let sceneID: String
    public let canvas: CanvasSize
    public let frameRate: FrameRate
    public let duration: TickDuration
    public let slots: [TemplateSlotDescriptor]

    public init(
        catalogID: String,
        sceneID: String,
        canvas: CanvasSize,
        frameRate: FrameRate,
        duration: TickDuration,
        slots: [TemplateSlotDescriptor]
    ) {
        self.catalogID = catalogID
        self.sceneID = sceneID
        self.canvas = canvas
        self.frameRate = frameRate
        self.duration = duration
        self.slots = slots
    }
}

/// One authoring media-binding slot read from a template block (Task-002 plan, §9).
public struct TemplateSlotDescriptor: Equatable, Sendable {
    public let blockID: String
    public let zIndex: Int
    public let bindingKey: String
    /// The authoring rect in canvas points (`x, y, width, height`).
    public let rect: AuthoringRect
    /// The authored variants (the `holdLastFrame` / `cut` policies live here).
    public let variants: [TemplateVariantDescriptor]
}

public struct AuthoringRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct TemplateVariantDescriptor: Equatable, Sendable {
    public let variantID: String
    public let animationRef: String
    public let defaultDurationFrames: Int
    public let ifAnimationShorter: String
    public let ifAnimationLonger: String
    public let loop: Bool
}

/// Reads a real template's `scene.json` into a ``TemplateFixtureDescriptor`` and instantiates it
/// deterministically with explicit fake bindings (Task-002 plan, §9).
///
/// This adapter lives only in test support; it does not implement D-104, `.tve` loading, or
/// current-product conversion.
public enum TemplateFixtureReader {

    public enum ReadError: Error, Equatable, Sendable {
        case fileNotReadable(path: String)
        case malformedJSON(path: String)
        case missingField(field: String)
        case wrongType(field: String)
        case unsupportedFrameRate(fps: Int)
        case unknownShorterPolicy(String)
        case unknownLongerPolicy(String)
        case nonPositiveDuration
        case contradictoryLoopPolicy(blockID: String, variantID: String)
        case missingVariantSelection(blockID: String)
        case unknownVariantSelection(blockID: String, variantID: String)
    }

    /// Reads the template at `<root>/SceneSources/<catalogID>/scene.json`.
    public static func read(catalogID: String, root: TemplateRepositoryRoot) throws -> TemplateFixtureDescriptor {
        let directory = root.templateDirectoryURL(forCatalogID: catalogID)
        let sceneJSON = directory.appendingPathComponent("scene.json")
        guard let data = try? Data(contentsOf: sceneJSON) else {
            throw ReadError.fileNotReadable(path: sceneJSON.path)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.malformedJSON(path: sceneJSON.path)
        }
        let sceneID = try StrictJSON.string(object, "sceneId")
        guard let canvasObject = object["canvas"] as? [String: Any] else {
            throw ReadError.missingField(field: "canvas")
        }
        let width = try StrictJSON.int(canvasObject, "width")
        let height = try StrictJSON.int(canvasObject, "height")
        let fps = try StrictJSON.int(canvasObject, "fps")
        let durationFrames = try StrictJSON.int(canvasObject, "durationFrames")
        guard let mediaBlocks = object["mediaBlocks"] as? [[String: Any]] else {
            throw ReadError.missingField(field: "mediaBlocks")
        }

        let frameRate = try frameRate(forFPS: Int(fps))
        let ticksPerFrame = try frameRate.exactTicksPerFrame
        let duration = try TickDuration(ticks: try CheckedInt64.multiply(ticksPerFrame, durationFrames, "template.duration"))
        let canvas = try CanvasSize(width: width, height: height)

        let slots = try mediaBlocks.map { try slot(from: $0) }

        return TemplateFixtureDescriptor(
            catalogID: catalogID,
            sceneID: sceneID,
            canvas: canvas,
            frameRate: frameRate,
            duration: duration,
            slots: slots
        )
    }

    private static func slot(from block: [String: Any]) throws -> TemplateSlotDescriptor {
        let blockID = try StrictJSON.string(block, "blockId")
        let zIndex = try StrictJSON.int(block, "zIndex")
        guard let input = block["input"] as? [String: Any] else { throw ReadError.missingField(field: "input") }
        let bindingKey = try StrictJSON.string(input, "bindingKey")
        guard let rectObject = block["rect"] as? [String: Any] else { throw ReadError.missingField(field: "rect") }
        let rect = AuthoringRect(
            x: try StrictJSON.double(rectObject, "x"),
            y: try StrictJSON.double(rectObject, "y"),
            width: try StrictJSON.double(rectObject, "width"),
            height: try StrictJSON.double(rectObject, "height")
        )
        guard let variantsRaw = block["variants"] as? [[String: Any]] else {
            throw ReadError.missingField(field: "variants")
        }
        let variants = try variantsRaw.map { variant in
            TemplateVariantDescriptor(
                variantID: try StrictJSON.string(variant, "variantId"),
                animationRef: try StrictJSON.string(variant, "animRef"),
                defaultDurationFrames: Int(try StrictJSON.int(variant, "defaultDurationFrames")),
                ifAnimationShorter: try StrictJSON.string(variant, "ifAnimationShorter"),
                ifAnimationLonger: try StrictJSON.string(variant, "ifAnimationLonger"),
                loop: try StrictJSON.bool(variant, "loop")
            )
        }
        return TemplateSlotDescriptor(
            blockID: blockID, zIndex: Int(zIndex), bindingKey: bindingKey, rect: rect, variants: variants
        )
    }

    private static func frameRate(forFPS fps: Int) throws -> FrameRate {
        switch fps {
        case 24: return FrameRate.fps24
        case 25: return FrameRate.fps25
        case 30: return FrameRate.fps30
        case 50: return FrameRate.fps50
        case 60: return FrameRate.fps60
        default: throw ReadError.unsupportedFrameRate(fps: fps)
        }
    }
}

/// Strict typed JSON accessors for `JSONSerialization` output that avoid Foundation bridging
/// ambiguities (corrective plan C-7, Revision 3).
///
/// `JSONSerialization` parses JSON numbers **and** JSON booleans to `NSNumber`, so `as? Bool` would
/// accept the number `1` and `as? Int` would accept `true`. These accessors disambiguate via
/// `CFBooleanGetTypeID()` and reject fractional-as-integer (`Int64(exactly:)`), with no `as?`
/// cross-bridge and no silent coercion.
enum StrictJSON {
    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] else { throw TemplateFixtureReader.ReadError.missingField(field: key) }
        guard let s = value as? String else { throw TemplateFixtureReader.ReadError.wrongType(field: key) }
        return s
    }

    static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] else { throw TemplateFixtureReader.ReadError.missingField(field: key) }
        // Accept ONLY a boolean NSNumber (CFBoolean), never a numeric NSNumber like 0/1.
        guard isBooleanNSNumber(value), let number = value as? NSNumber else {
            throw TemplateFixtureReader.ReadError.wrongType(field: key)
        }
        return number.boolValue
    }

    static func int(_ object: [String: Any], _ key: String) throws -> Int64 {
        guard let value = object[key] else { throw TemplateFixtureReader.ReadError.missingField(field: key) }
        // Reject booleans (which are NSNumber) and reject fractional numbers via Int64(exactly:).
        guard !isBooleanNSNumber(value), let number = value as? NSNumber,
              !isFloatingPointNSNumber(number), let exact = Int64(exactly: number) else {
            throw TemplateFixtureReader.ReadError.wrongType(field: key)
        }
        return exact
    }

    static func double(_ object: [String: Any], _ key: String) throws -> Double {
        guard let value = object[key] else { throw TemplateFixtureReader.ReadError.missingField(field: key) }
        guard !isBooleanNSNumber(value), let number = value as? NSNumber else {
            throw TemplateFixtureReader.ReadError.wrongType(field: key)
        }
        return number.doubleValue
    }

    /// True iff `value` is the boolean `NSNumber` (a `CFBoolean`), not a numeric `NSNumber`.
    private static func isBooleanNSNumber(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// True iff the `NSNumber` wraps a floating-point value (objCType `f`/`d`).
    private static func isFloatingPointNSNumber(_ number: NSNumber) -> Bool {
        let t = number.objCType.pointee
        return t == 0x66 /* 'f' */ || t == 0x64 /* 'd' */
    }
}
