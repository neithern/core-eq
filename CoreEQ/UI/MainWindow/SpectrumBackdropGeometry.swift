import CoreGraphics
import Foundation

/// Where the analyzer's points sit on the response plot, and the two paths they
/// are drawn with.
///
/// Pulled out of the view so it can be tested: the test target compiles the
/// model and the geometry but not the views, and a backdrop drawn at the wrong
/// height would still look like a spectrum — the only way to notice would be to
/// compare it against the curve by eye.
///
/// The axis and the floor are the same ones the curve is drawn against, which is
/// what keeps the spectrum underneath the frequency it belongs to.
enum SpectrumBackdropGeometry {
    /// Below this a level is indistinguishable from silence on screen. Without
    /// the floor, silence would stroke a flat line along the bottom of the plot
    /// that reads as a stray rule under the frequency labels.
    static let silenceThreshold: Float = 0.02

    /// Where each point sits, in the host view's coordinates, or nil when there
    /// is nothing to draw.
    ///
    /// AppKit's origin is the bottom-left and y grows upwards, so the plot's
    /// floor is `height - plotHeight` and a level of 1 reaches the top edge.
    static func vertices(
        points: [SpectrumAnalyzer.Point], axis: ResponseAxis, plotHeight: CGFloat,
        height: CGFloat
    ) -> [CGPoint]? {
        guard points.count > 1, plotHeight > 0, height > 0,
            points.contains(where: { $0.level > silenceThreshold })
        else { return nil }

        let floor = height - plotHeight
        return points.map { point in
            let level = CGFloat(min(max(point.level, 0), 1))
            return CGPoint(x: axis.x(point.frequency), y: floor + plotHeight * level)
        }
    }

    /// The two paths the backdrop is drawn with: the line itself, and the area
    /// under it closed along the plot's floor.
    static func paths(
        points: [SpectrumAnalyzer.Point], axis: ResponseAxis, plotHeight: CGFloat,
        height: CGFloat
    ) -> (fill: CGPath, line: CGPath)? {
        guard
            let positions = vertices(
                points: points, axis: axis, plotHeight: plotHeight, height: height),
            let first = positions.first, let last = positions.last
        else { return nil }

        let line = CGMutablePath()
        line.addLines(between: positions)

        let fill = CGMutablePath()
        fill.addPath(line)
        let floor = height - plotHeight
        fill.addLine(to: CGPoint(x: last.x, y: floor))
        fill.addLine(to: CGPoint(x: first.x, y: floor))
        fill.closeSubpath()

        return (fill, line)
    }
}
