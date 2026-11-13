import AppKit
import Combine
import SwiftUI

/// The analyzer's output, drawn behind the response curve — on its own layer.
///
/// This is the only part of the plot that changes at frame rate, and it used to
/// be a SwiftUI `Canvas`. Every tick then invalidated a view, re-recorded a
/// display list, and rasterized a plot-sized area on the CPU: measured on an
/// M-series Mac for a 1000×380 plot with 128 points, 2.37 / 2.78 / 3.97% of a
/// core at 15 / 20 / 30 Hz. Here the same points become two `CGPath`s and two
/// layer properties and the drawing is left to Core Animation: 0.40 / 0.52 /
/// 0.85% over the same range.
///
/// Deliberately *not* an `@ObservedObject`. The analyzer publishes at frame
/// rate, and being observed is what used to make SwiftUI re-run the plot on
/// every tick. The subscription lives in the view and updates the layers
/// directly, so SwiftUI has nothing to invalidate and the grid, the curve, and
/// the handles are not redrawn behind the user's back.
struct SpectrumBackdrop: NSViewRepresentable {
    let spectrum: SpectrumAnalyzer
    let axis: ResponseAxis
    let plotHeight: CGFloat

    func makeNSView(context: Context) -> SpectrumBackdropView {
        let view = SpectrumBackdropView()
        view.startObserving(spectrum)
        return view
    }

    func updateNSView(_ view: SpectrumBackdropView, context: Context) {
        view.configure(axis: axis, plotHeight: plotHeight)
    }

    static func dismantleNSView(_ view: SpectrumBackdropView, coordinator: ()) {
        view.stopObserving()
    }
}

/// The layer-backed host for `SpectrumBackdrop`.
///
/// A plain `NSView` rather than a SwiftUI shape, because the paths are rebuilt
/// on the analyzer's timer, outside SwiftUI's update cycle entirely. The two
/// layers are the fill and the line, kept apart so the fill can close along the
/// plot's floor without the line stroking that edge as well.
final class SpectrumBackdropView: NSView {
    private let fillLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private var cancellable: AnyCancellable?
    private weak var spectrum: SpectrumAnalyzer?
    private var axis: ResponseAxis?
    private var plotHeight: CGFloat = 0
    private var points: [SpectrumAnalyzer.Point] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        // No implicit animation on any of the properties the timer writes: a
        // `CAShapeLayer.path` animates by default, which at this rate would
        // both cost more and make the spectrum lag behind the audio.
        for shape in [fillLayer, lineLayer] {
            shape.frame = bounds
            shape.actions = [
                "path": NSNull(), "frame": NSNull(),
                "fillColor": NSNull(), "strokeColor": NSNull(),
            ]
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        fillLayer.strokeColor = nil
        lineLayer.fillColor = nil
        lineLayer.lineWidth = 1
        applyColors()
        // Decoration, not a control: the plot carries the accessibility label.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Nothing here is grabbable: the plot's gestures live on the SwiftUI view
    /// around it, and swallowing a click would make the curve undraggable.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Also where an appearance change arrives.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        lineLayer.frame = bounds
        CATransaction.commit()
        redraw()
    }

    // MARK: - Observing

    func startObserving(_ analyzer: SpectrumAnalyzer) {
        guard spectrum !== analyzer else { return }
        stopObserving()
        spectrum = analyzer
        points = analyzer.points
        // The publisher fires on the main actor, from the analyzer's timer.
        cancellable = analyzer.$points.sink { [weak self] points in
            MainActor.assumeIsolated {
                self?.points = points
                self?.redraw()
            }
        }
        redraw()
    }

    func stopObserving() {
        cancellable?.cancel()
        cancellable = nil
        spectrum = nil
    }

    // MARK: - Drawing

    func configure(axis: ResponseAxis, plotHeight: CGFloat) {
        guard self.axis != axis || self.plotHeight != plotHeight else { return }
        self.axis = axis
        self.plotHeight = plotHeight
        redraw()
    }

    private func redraw() {
        guard let axis, bounds.width > 1, bounds.height > 1,
            let paths = SpectrumBackdropGeometry.paths(
                points: points, axis: axis, plotHeight: plotHeight, height: bounds.height)
        else {
            clearPaths()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.path = paths.fill
        lineLayer.path = paths.line
        fillLayer.isHidden = false
        lineLayer.isHidden = false
        CATransaction.commit()
    }

    private func clearPaths() {
        guard fillLayer.path != nil || lineLayer.path != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.path = nil
        lineLayer.path = nil
        fillLayer.isHidden = true
        lineLayer.isHidden = true
        CATransaction.commit()
    }

    private func applyColors() {
        // Resolve the dynamic label colour against this view's appearance, the
        // way the menu bar's own layer views do: `NSColor.cgColor` on its own
        // would take the app-wide appearance rather than the window's.
        var fill: CGColor = NSColor.clear.cgColor
        var stroke: CGColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            fill = label.withAlphaComponent(0.05).cgColor
            stroke = label.withAlphaComponent(0.13).cgColor
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.fillColor = fill
        lineLayer.strokeColor = stroke
        CATransaction.commit()
    }
}
