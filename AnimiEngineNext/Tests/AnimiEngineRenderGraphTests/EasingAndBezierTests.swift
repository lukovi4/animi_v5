import XCTest
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// Task-003 §3.7 D3-07, §7.2 — `TransitionEasing` and `CubicBezierSampler` fixed-point correctness.
/// `Double` is used only to compute the reference; the implementations contain no floating point.
final class EasingAndBezierTests: XCTestCase {

    private let u = UnitInterval.unitsPerUnit

    // MARK: - TransitionEasing

    func testProgressExactRational() throws {
        XCTAssertEqual(try TransitionEasing.progress(numerator: 0, denominator: 4).rawValue, 0)
        XCTAssertEqual(try TransitionEasing.progress(numerator: 1, denominator: 2).rawValue, 500_000)
        XCTAssertEqual(try TransitionEasing.progress(numerator: 1, denominator: 4).rawValue, 250_000)
        XCTAssertEqual(try TransitionEasing.progress(numerator: 3, denominator: 4).rawValue, 750_000)
    }

    func testProgressRejectsInvalid() {
        XCTAssertThrowsError(try TransitionEasing.progress(numerator: 1, denominator: 0))
        XCTAssertThrowsError(try TransitionEasing.progress(numerator: 5, denominator: 4))   // > 1
        XCTAssertThrowsError(try TransitionEasing.progress(numerator: -1, denominator: 4))
    }

    func testLinearIsIdentity() throws {
        for raw in [0, 123_456, 500_000, 999_999, 1_000_000] as [Int64] {
            let t = try UnitInterval(rawValue: raw)
            XCTAssertEqual(try TransitionEasing.eased(.linear, progress: t), t)
        }
    }

    func testEaseInOutSmoothstep() throws {
        // 3t² − 2t³ at a few points, against the analytic reference (tolerance a few ULP at 1e6).
        for raw in [0, 250_000, 500_000, 750_000, 1_000_000] as [Int64] {
            let t = try UnitInterval(rawValue: raw)
            let got = try TransitionEasing.eased(.easeInOut, progress: t).rawValue
            let f = Double(raw) / 1e6
            let expected = Int64((( 3*f*f - 2*f*f*f) * 1e6).rounded())
            XCTAssertEqual(got, expected, accuracy: 4, "easeInOut at \(raw)")
        }
        // Endpoints exact, midpoint == 0.5.
        XCTAssertEqual(try TransitionEasing.eased(.easeInOut, progress: .zero).rawValue, 0)
        XCTAssertEqual(try TransitionEasing.eased(.easeInOut, progress: .one).rawValue, 1_000_000)
        XCTAssertEqual(try TransitionEasing.eased(.easeInOut, progress: try UnitInterval(rawValue: 500_000)).rawValue, 500_000)
    }

    func testNoneEasingRejectedAsAnimated() {
        XCTAssertThrowsError(try TransitionEasing.eased(.none, progress: .zero)) { error in
            guard case RenderGraphError.unsupportedEasing? = error as? RenderGraphError else {
                return XCTFail("expected unsupportedEasing, got \(error)")
            }
        }
    }

    func testUnknownEasingRejected() {
        XCTAssertThrowsError(try TransitionEasing.kind(from: "bogus")) { error in
            guard case RenderGraphError.unsupportedEasing? = error as? RenderGraphError else {
                return XCTFail("expected unsupportedEasing, got \(error)")
            }
        }
        XCTAssertEqual(try TransitionEasing.kind(from: "linear"), .linear)
        XCTAssertEqual(try TransitionEasing.kind(from: "easeInOut"), .easeInOut)
    }

    // MARK: - CubicBezierSampler

    private func vec(_ x: Int64, _ y: Int64) -> RenderEasingVec2 {
        RenderEasingVec2(x: EasingScalar(rawValue: x), y: EasingScalar(rawValue: y))
    }

    /// Double reference for cubic-bezier y(x=s) via the same bisection, for tolerance checking.
    private func refBezier(s: Double, ox: Double, oy: Double, ix: Double, iy: Double) -> Double {
        func axis(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let omt = 1 - t
            return 3*omt*omt*t*p1 + 3*omt*t*t*p2 + t*t*t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 { let m = (lo+hi)/2; if axis(m, ox, ix) < s { lo = m } else { hi = m } }
        return axis((lo+hi)/2, oy, iy)
    }

    func testBezierIdentityWhenNoHandles() throws {
        for raw in [0, 333_333, 1_000_000] as [Int64] {
            let s = try UnitInterval(rawValue: raw)
            XCTAssertEqual(try CubicBezierSampler.ease(s: s, outTangent: nil, inTangent: nil), s)
        }
    }

    func testBezierMatchesReference() throws {
        // ease-in-out-ish handles (0.42,0) (0.58,1).
        let out = vec(420_000, 0), inn = vec(580_000, 1_000_000)
        for raw in [0, 100_000, 250_000, 500_000, 750_000, 900_000, 1_000_000] as [Int64] {
            let s = try UnitInterval(rawValue: raw)
            let got = try CubicBezierSampler.ease(s: s, outTangent: out, inTangent: inn).rawValue
            let expected = Int64((refBezier(s: Double(raw)/1e6, ox: 0.42, oy: 0, ix: 0.58, iy: 1) * 1e6).rounded())
            XCTAssertEqual(got, expected, accuracy: 200, "bezier at \(raw)")   // bisection tolerance
        }
    }

    func testBezierEndpointsExact() throws {
        let out = vec(250_000, 100_000), inn = vec(750_000, 900_000)
        XCTAssertEqual(try CubicBezierSampler.ease(s: .zero, outTangent: out, inTangent: inn).rawValue, 0, accuracy: 2)
        XCTAssertEqual(try CubicBezierSampler.ease(s: .one, outTangent: out, inTangent: inn).rawValue, 1_000_000, accuracy: 2)
    }

    func testBezierDeterministic() throws {
        let out = vec(420_000, 0), inn = vec(580_000, 1_000_000)
        let s = try UnitInterval(rawValue: 333_333)
        XCTAssertEqual(
            try CubicBezierSampler.ease(s: s, outTangent: out, inTangent: inn),
            try CubicBezierSampler.ease(s: s, outTangent: out, inTangent: inn))
    }
}
