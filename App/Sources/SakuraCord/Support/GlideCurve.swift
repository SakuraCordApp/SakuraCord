import AppKit
import SakuraCordModels

/// A cubic Bézier curve the transcript can glide on, readable at any moment
/// so a glide that is interrupted continues from where its rows are drawn.
struct GlideCurve {
    let x1: Float
    let y1: Float
    let x2: Float
    let y2: Float
    let duration: CFTimeInterval

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
    }

    /// The curve's progress after `fraction` of the duration.
    func progress(at fraction: Double) -> Double {
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return 1 }
        func bezier(_ parameter: Double, _ first: Float, _ second: Float) -> Double {
            let inverse = 1 - parameter
            return 3 * inverse * inverse * parameter * Double(first)
                + 3 * inverse * parameter * parameter * Double(second)
                + parameter * parameter * parameter
        }
        var lower = 0.0
        var upper = 1.0
        for _ in 0 ..< 24 {
            let middle = (lower + upper) / 2
            if bezier(middle, x1, x2) < fraction {
                lower = middle
            } else {
                upper = middle
            }
        }
        return bezier((lower + upper) / 2, y1, y2)
    }
}
