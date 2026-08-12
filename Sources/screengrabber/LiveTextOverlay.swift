import AppKit
import VisionKit

/// Preview-style text selection directly on the image, backed by VisionKit's
/// Live Text overlay (`ImageAnalysisOverlayView` — the same view Preview and
/// Quick Look use, so hover cursors, selection highlights and the Copy / Look Up
/// context menu all come from the system).
///
/// This view exists to sit *between* that overlay and `CanvasView` and decide,
/// per click, which of the two should get the event. `ImageAnalysisOverlayView`
/// is `final`, so it can't be subclassed to do that itself.
final class LiveTextOverlay: NSView, ImageAnalysisOverlayViewDelegate {

    /// Live Text needs Apple silicon on macOS. On Intel this stays off and the
    /// OCR panel remains the way to get text out.
    static var isSupported: Bool { ImageAnalyzer.isSupported }

    enum Activation {
        /// Invisible and non-interactive; every event goes to the canvas.
        case off
        /// Preview-like: the overlay claims a click only when it lands on
        /// recognized text with no annotation on top of it. Anything else falls
        /// through, so the drawing and selection tools behave exactly as before.
        case automatic
        /// The explicit toggle: the overlay claims everything inside the image.
        case forced
    }

    var activation: Activation = .off {
        didSet {
            guard activation != oldValue else { return }
            overlay.preferredInteractionTypes = activation == .off ? [] : .textSelection
            isHidden = activation == .off
            if activation == .off { overlay.resetSelection() }
        }
    }

    /// Asked whether an annotation covers a point (in this view's coordinates),
    /// so a shape drawn over text still wins the click in `.automatic`.
    var hasAnnotation: ((CGPoint) -> Bool)?

    /// Called when the overlay declines a key event we want to act on (Esc).
    var onEscape: (() -> Void)?

    private let overlay = ImageAnalysisOverlayView()
    private let analyzer = ImageAnalyzer()

    /// The canvas edit-generation the current analysis was made from, and the one
    /// most recently requested. Analysis is expensive, so it only re-runs when the
    /// image it was made from has actually changed.
    private var analyzedGeneration = -1
    private var pendingGeneration = -1
    private var pendingWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlay.delegate = self
        overlay.preferredInteractionTypes = []
        // We have a toolbar toggle; the floating Live Text badge would be a second,
        // competing affordance sitting on top of the user's screenshot.
        overlay.isSupplementaryInterfaceHidden = true
        overlay.autoresizingMask = [.width, .height]
        overlay.frame = bounds
        addSubview(overlay)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    // MARK: - Analysis

    /// Analyzes the image `makeImage` produces, unless the current analysis
    /// already reflects `generation`.
    ///
    /// Debounced, and the image is built inside the debounce: every stroke bumps
    /// the generation, and flattening a full-resolution composite per stroke — for
    /// a result that's stale before it lands — is exactly the cost worth skipping.
    func analyze(generation: Int, makeImage: @escaping () -> CGImage?) {
        guard Self.isSupported, needsAnalysis(for: generation) else { return }

        pendingGeneration = generation
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let image = makeImage() else { return }
            self.runAnalysis(image, generation: generation)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func needsAnalysis(for generation: Int) -> Bool {
        generation != analyzedGeneration && generation != pendingGeneration
    }

    /// Drops the current analysis. Used when the mode turns off so a stale result
    /// can't make text selectable after it was blurred out.
    func invalidate() {
        pendingWork?.cancel()
        pendingWork = nil
        pendingGeneration = -1
        analyzedGeneration = -1
        overlay.analysis = nil
    }

    private func runAnalysis(_ image: CGImage, generation: Int) {
        // ImageAnalyzer is async-only, unlike the rest of this codebase's
        // completion-handler style, so the Task is contained here.
        let configuration = ImageAnalyzer.Configuration([.text])
        let analyzer = self.analyzer
        Task { @MainActor [weak self] in
            do {
                let analysis = try await analyzer.analyze(image, orientation: .up,
                                                          configuration: configuration)
                guard let self = self, generation == self.pendingGeneration else { return }
                self.overlay.analysis = analysis
                self.analyzedGeneration = generation
            } catch {
                NSLog("ScreenGrabber: Live Text analysis failed: \(error)")
                guard let self = self, generation == self.pendingGeneration else { return }
                self.pendingGeneration = -1
            }
        }
    }

    /// True when the user has text selected on the image, so ⌘C can copy that
    /// instead of the image itself.
    var hasTextSelection: Bool {
        activation != .off && overlay.hasActiveTextSelection
    }

    /// The selected text, on the versions of macOS that expose it. Reading a
    /// selection programmatically is macOS 14+; on 13 the overlay's own
    /// right-click ▸ Copy still works, it just can't be driven from our code.
    var selectedText: String? {
        guard hasTextSelection else { return nil }
        if #available(macOS 14.0, *) {
            let text = overlay.selectedText
            return text.isEmpty ? nil : text
        }
        return nil
    }

    func clearSelection() { overlay.resetSelection() }

    /// Whether recognized text sits under a point in this view's coordinates.
    /// Exposed so the behavior can be asserted without driving the mouse.
    func hasText(atViewPoint p: CGPoint) -> Bool {
        overlay.analysis != nil && overlay.analysisHasText(at: flipped(p))
    }

    // MARK: - Event routing

    /// The whole point of this view. `point` arrives in the superview's
    /// coordinates, per `NSView.hitTest`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        switch activation {
        case .off:
            return nil
        case .forced:
            return super.hitTest(point)
        case .automatic:
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            // No analysis yet, not over text, or an annotation is on top: let the
            // canvas have it, so nothing about the existing tools changes.
            guard overlay.analysis != nil,
                  overlay.analysisHasText(at: flipped(local)) else { return nil }
            if hasAnnotation?(local) == true { return nil }
            return super.hitTest(point)
        }
    }

    /// Keeps the overlay's idea of where the image sits in sync after a resize.
    func updateContentsRect() { overlay.setContentsRectNeedsUpdate() }

    /// `analysisHasText(at:)` measures y from the **top**, even though the overlay
    /// reports `isFlipped == false` — so neither passing the point straight
    /// through nor `convert(_:from:)` gives the right answer, and a hit-test would
    /// land on the vertical mirror of wherever the user actually clicked.
    /// Verified empirically by scanning a test image with text only in its top third.
    private func flipped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: bounds.height - p.y)
    }

    // MARK: - ImageAnalysisOverlayViewDelegate

    /// The overlay's frame is set to exactly the image rect, so the image fills
    /// its bounds and the contents rect is the full unit square.
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Let Esc through so the canvas can leave text-select mode; the overlay would
    /// otherwise swallow it while it holds first responder.
    func overlayView(_ overlayView: ImageAnalysisOverlayView,
                     shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        if event.keyCode == 53 {   // Esc
            onEscape?()
            return false
        }
        return true
    }
}
