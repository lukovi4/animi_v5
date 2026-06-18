/// Task-003 plan D3-08 — the explicit colour and alpha contract for Task-003 output.
///
/// These are pinned descriptor enums, not behaviour: they name the exact output and intermediate
/// formats the renderer must honour. No `Float`/`Double` appears in canonical state; component values
/// live in `NormalizedColorComponent` fixed point and are converted to Metal `Float` only at the
/// executor upload boundary (§5.4).
///
/// The canonical compositing equation (premultiplied source-over in linear light, D3-08) is:
/// ```
/// out.rgb = src.rgb + dst.rgb * (1 - src.a)
/// out.a   = src.a   + dst.a   * (1 - src.a)
/// ```
/// Inputs are normalized to linear-light premultiplied values before compositing; the final linear
/// result is converted to sRGB BGRA8. This file declares the contract; the executor (§17 step 10+)
/// implements it.

/// The output pixel byte format. Task-003 output is exactly BGRA8 (D3-08).
public enum PixelByteFormat: String, Hashable, Sendable, CaseIterable {
    case bgra8
}

/// Colour primaries + transfer function. Task-003 output is sRGB (D3-08).
public enum ColorSpaceDescriptor: String, Hashable, Sendable, CaseIterable {
    case sRGB
}

/// Dynamic range. Task-003 output is SDR (D3-08).
public enum DynamicRange: String, Hashable, Sendable, CaseIterable {
    case sdr
}

/// Alpha storage convention. Task-003 stores premultiplied alpha (D3-08).
public enum AlphaStorage: String, Hashable, Sendable, CaseIterable {
    case premultiplied
}

/// A configurable intermediate compositing profile (D3-08). `rgba16FloatLinear` is the Task-003
/// correctness-reference profile; the optimal production intermediate remains benchmark decision
/// D-208 and is deliberately not chosen here.
public enum IntermediateProfile: String, Hashable, Sendable, CaseIterable {
    case bgra8SRGB
    case rgba16FloatLinear
}

/// The complete, immutable colour/alpha output contract. Its values are fixed by D3-08; the
/// initializer pins them and exists so the contract is a first-class, hashable model value that the
/// render configuration and rendered frame can carry and compare.
public struct RenderColorContract: Hashable, Sendable {
    public let outputFormat: PixelByteFormat
    public let colorSpace: ColorSpaceDescriptor
    public let dynamicRange: DynamicRange
    public let alphaStorage: AlphaStorage

    /// The canonical Task-003 output contract (BGRA8 / sRGB / SDR / premultiplied).
    public static let task003: RenderColorContract = RenderColorContract(
        outputFormat: .bgra8, colorSpace: .sRGB, dynamicRange: .sdr, alphaStorage: .premultiplied)

    public init(
        outputFormat: PixelByteFormat,
        colorSpace: ColorSpaceDescriptor,
        dynamicRange: DynamicRange,
        alphaStorage: AlphaStorage
    ) {
        self.outputFormat = outputFormat
        self.colorSpace = colorSpace
        self.dynamicRange = dynamicRange
        self.alphaStorage = alphaStorage
    }
}

/// An immutable premultiplied colour in normalized fixed-point components (canonical state). Used for
/// cleared-background and pre-resolved solid colours.
///
/// Premultiplication is **enforced** (item 3): in valid premultiplied storage each colour component is
/// already multiplied by alpha, so `red <= alpha`, `green <= alpha` and `blue <= alpha` must hold. A
/// colour violating this is not a representable premultiplied value and is rejected with a typed
/// ``RenderModelError/unsupportedValue(field:value:)``.
public struct PremultipliedColor: Hashable, Sendable {
    public let red: NormalizedColorComponent
    public let green: NormalizedColorComponent
    public let blue: NormalizedColorComponent
    public let alpha: NormalizedColorComponent

    /// Fully transparent black — the only colour where every component is zero (always valid).
    public static let transparentBlack = PremultipliedColor(
        uncheckedRed: .zero, green: .zero, blue: .zero, alpha: .zero)

    private init(
        uncheckedRed red: NormalizedColorComponent,
        green: NormalizedColorComponent,
        blue: NormalizedColorComponent,
        alpha: NormalizedColorComponent
    ) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init(
        red: NormalizedColorComponent,
        green: NormalizedColorComponent,
        blue: NormalizedColorComponent,
        alpha: NormalizedColorComponent
    ) throws {
        // Premultiplied invariant: no colour channel may exceed alpha.
        for (name, component) in [("red", red), ("green", green), ("blue", blue)] {
            guard component.rawValue <= alpha.rawValue else {
                throw RenderModelError.unsupportedValue(
                    field: "PremultipliedColor.\(name)",
                    value: "component \(component.rawValue) > alpha \(alpha.rawValue)")
            }
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}
