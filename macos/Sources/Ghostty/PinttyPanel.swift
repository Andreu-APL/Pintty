import QuartzCore
import AppKit

final class PinttyPanelLayer: CALayer {

    // MARK: - Constants

    static let cornerRadius: CGFloat = 8
    static let titleHeight: CGFloat = 26
    static let blurRadius: CGFloat  = PinttyColors.panelBlurRadius
    static let contentPad: CGFloat  = 8   // horizontal padding inside content area

    // MARK: - Identity

    let panelId: String

    // MARK: - Sublayers

    private let bgLayer             = CALayer()
    private let contentClipLayer    = CALayer()      // clips text/image to content area
    private let contentTextLayer    = CATextLayer()
    private let contentImageLayer   = CALayer()
    private let instrumentLayer     = PinttyGaugeLayer()  // radial gauge + sparkline (content_type "instrument")
    private let scrollIndicatorLayer = CALayer()     // thin right-side scroll position strip
    private let titleSeparatorLayer = CALayer()      // 0.5 px line between title and content
    private let borderLayer         = CAShapeLayer()
    private let resizeGripLayer     = CAShapeLayer() // diagonal lines in bottom-right corner
    private let titleLayer          = CATextLayer()

    // MARK: - Content state

    private var currentTitle:       String = ""
    private var currentContent:     String = ""
    private var currentContentType: String = "text"
    private var scrollOffsetPx:     CGFloat = 0
    private var contentHeight:      CGFloat = 0  // calculated wrapped height
    private var geoRenderGen:       Int = 0       // incremented to cancel stale geo renders
    private var lastGeoSize:        CGSize = .zero

    // MARK: - Computed helpers

    private var clipHeight: CGFloat { max(0, bounds.height - Self.titleHeight) }

    var lineHeight: CGFloat {
        let f = contentFont
        return ceil(f.ascender - f.descender + f.leading)
    }

    var maxScrollOffset: CGFloat { max(0, contentHeight - clipHeight) }

    private var contentFont: NSFont {
        currentContentType == "brief"
            ? NSFont.systemFont(ofSize: 13)
            : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    // MARK: - Init

    init(id: String, title: String) {
        self.panelId = id
        super.init()

        // Gaussian blur of terminal content behind this panel.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(Self.blurRadius, forKey: "inputRadius")
            backgroundFilters = [blur]
        }
        masksToBounds = true
        cornerRadius  = Self.cornerRadius

        // Dark semi-transparent fill.
        bgLayer.backgroundColor = PinttyColors.panelBg.cgColor
        addSublayer(bgLayer)

        // Content clip (masks text to the area below the title bar).
        contentClipLayer.masksToBounds = true
        addSublayer(contentClipLayer)

        // CATextLayer for scrollable text content.
        contentTextLayer.isWrapped        = true
        contentTextLayer.alignmentMode    = .left
        contentTextLayer.truncationMode   = .none
        contentTextLayer.foregroundColor  = PinttyColors.contentText.cgColor
        contentTextLayer.contentsScale    = NSScreen.main?.backingScaleFactor ?? 2.0
        contentClipLayer.addSublayer(contentTextLayer)

        // Image layer — shown in place of text when content_type == "image".
        contentImageLayer.contentsGravity = .resizeAspect
        contentImageLayer.masksToBounds   = true
        contentImageLayer.isHidden        = true
        contentImageLayer.contentsScale   = NSScreen.main?.backingScaleFactor ?? 2.0
        contentClipLayer.addSublayer(contentImageLayer)

        // Instrument gauge — shown in place of text when content_type == "instrument".
        instrumentLayer.isHidden = true
        contentClipLayer.addSublayer(instrumentLayer)

        // Scroll position strip (inside content clip, right edge).
        scrollIndicatorLayer.backgroundColor = PinttyColors.scrollIndicator.cgColor
        scrollIndicatorLayer.cornerRadius    = 1.5
        scrollIndicatorLayer.isHidden        = true
        contentClipLayer.addSublayer(scrollIndicatorLayer)

        // Hairline separator between title bar and content area.
        titleSeparatorLayer.backgroundColor = PinttyColors.panelBorderDim.cgColor
        addSublayer(titleSeparatorLayer)

        // 1 px neon stroke border (on top of content).
        borderLayer.fillColor   = nil
        borderLayer.strokeColor = PinttyColors.panelBorderDim.cgColor
        borderLayer.lineWidth   = 1.0
        addSublayer(borderLayer)

        // Resize grip — three diagonal tick marks in the bottom-right corner.
        resizeGripLayer.fillColor   = nil
        resizeGripLayer.strokeColor = PinttyColors.resizeGrip.cgColor
        resizeGripLayer.lineWidth   = 1.0
        resizeGripLayer.lineCap     = .round
        addSublayer(resizeGripLayer)

        // Title bar text (topmost).
        titleLayer.alignmentMode  = .center
        titleLayer.truncationMode = .end
        titleLayer.font           = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLayer.fontSize       = 13
        titleLayer.foregroundColor = PinttyColors.titleColor.cgColor
        titleLayer.contentsScale  = NSScreen.main?.backingScaleFactor ?? 2.0
        addSublayer(titleLayer)

        setTitle(title)
        opacity = 0  // animateSpawn() makes it visible
    }

    required init?(coder: NSCoder) { nil }

    override init(layer: Any) {
        self.panelId = (layer as? PinttyPanelLayer)?.panelId ?? ""
        super.init(layer: layer)
    }

    // MARK: - Layout

    override func layoutSublayers() {
        super.layoutSublayers()
        let b  = bounds
        let cs = contentsScale
        titleLayer.contentsScale        = cs
        contentTextLayer.contentsScale  = cs
        contentImageLayer.contentsScale = cs

        bgLayer.frame = b

        // Content area sits below the title bar.
        let clipW = b.width
        let clipH = b.height - Self.titleHeight
        contentClipLayer.frame = CGRect(x: 0, y: 0, width: clipW, height: clipH)

        // Image/geo layer always fills the clip area.
        contentImageLayer.frame = CGRect(x: 0, y: 0, width: clipW, height: clipH)

        // Instrument gauge fills the clip area and re-lays-out its arcs/sparkline.
        instrumentLayer.frame = CGRect(x: 0, y: 0, width: clipW, height: clipH)
        if currentContentType == "instrument" { instrumentLayer.relayout() }

        // Re-render geo map when the panel is resized.
        if currentContentType == "geo" {
            let newSize = CGSize(width: clipW, height: clipH)
            if newSize != lastGeoSize {
                lastGeoSize = newSize
                scheduleGeoRender()
            }
        }

        // Recalculate text height whenever the panel is resized.
        let textW = max(0, clipW - Self.contentPad * 2)
        if currentContentType == "text" || currentContentType == "brief" {
            if !currentContent.isEmpty && textW > 0 {
                contentHeight = measureTextHeight(text: currentContent, font: contentFont, width: textW)
            }
        }
        repositionContentTextLayer()

        // Hairline at the boundary between title and content.
        titleSeparatorLayer.frame = CGRect(
            x: 0, y: b.height - Self.titleHeight,
            width: b.width, height: 0.5
        )

        borderLayer.frame = b
        borderLayer.path  = CGPath(
            roundedRect: b.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth:  Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform:    nil
        )

        // Three diagonal tick marks in the bottom-right corner (resize grip).
        let gripPath = CGMutablePath()
        for offset: CGFloat in [5, 8, 11] {
            gripPath.move(to: CGPoint(x: b.maxX - offset, y: b.minY + 1))
            gripPath.addLine(to: CGPoint(x: b.maxX - 1, y: b.minY + offset))
        }
        resizeGripLayer.path = gripPath

        titleLayer.frame = CGRect(
            x: 0, y: b.height - Self.titleHeight,
            width: b.width, height: Self.titleHeight
        )
    }

    // MARK: - Public update API

    func setTitle(_ title: String) {
        guard title != currentTitle else { return }
        currentTitle       = title
        titleLayer.string  = title
    }

    func setContent(_ text: String, type: String) {
        let typeChanged = type != currentContentType
        currentContent     = text
        currentContentType = type

        if type == "instrument" {
            contentTextLayer.isHidden  = true
            contentImageLayer.isHidden = true
            instrumentLayer.isHidden   = false
            contentHeight  = 0
            scrollOffsetPx = 0
            instrumentLayer.apply(json: text)
            return
        }
        instrumentLayer.isHidden = true

        if type == "image" {
            contentTextLayer.isHidden  = true
            contentImageLayer.isHidden = false
            contentHeight  = 0
            scrollOffsetPx = 0
            contentImageLayer.contents = loadImageContent(text)
        } else if type == "geo" {
            contentTextLayer.isHidden  = true
            contentImageLayer.isHidden = false
            contentHeight  = 0
            scrollOffsetPx = 0
            contentImageLayer.contents = nil
            // If bounds are already valid, render now; otherwise layoutSublayers will trigger.
            let clipSize = contentClipLayer.bounds.size
            if clipSize.width > 0 {
                lastGeoSize = clipSize
                scheduleGeoRender()
            }
        } else {
            contentTextLayer.isHidden  = false
            contentImageLayer.isHidden = true

            let font = contentFont
            contentTextLayer.font     = font
            contentTextLayer.fontSize = font.pointSize
            contentTextLayer.string   = text

            let textW = max(0, contentClipLayer.bounds.width - Self.contentPad * 2)
            if textW > 0 {
                contentHeight = measureTextHeight(text: text, font: font, width: textW)
            }
            if typeChanged { scrollOffsetPx = 0 }
            scrollOffsetPx = min(scrollOffsetPx, maxScrollOffset)
            repositionContentTextLayer()
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        contentClipLayer.isHidden = collapsed
    }

    /// Apply an absolute pixel scroll offset (clamped to content bounds).
    func applyScrollOffset(_ px: CGFloat) {
        scrollOffsetPx = max(0, min(maxScrollOffset, px))
        repositionContentTextLayer()
    }

    // MARK: - Private helpers

    private func repositionContentTextLayer() {
        let clipH  = contentClipLayer.bounds.height
        let textH  = max(contentHeight, clipH)
        let textW  = max(0, contentClipLayer.bounds.width - Self.contentPad * 2)
        // y origin: when scroll=0 the top of the text sits at the top of the clip.
        // In CA (y-up), top = high y, so origin.y = clipH - textH.
        // Scrolling down (seeing later content) shifts the text upward: +scrollOffset.
        let originY = clipH - textH + scrollOffsetPx
        contentTextLayer.frame = CGRect(
            x: Self.contentPad,
            y: originY,
            width: textW,
            height: textH
        )
        updateScrollIndicator()
    }

    private func updateScrollIndicator() {
        guard maxScrollOffset > 0, contentHeight > 0 else {
            scrollIndicatorLayer.isHidden = true
            return
        }
        let clipW = contentClipLayer.bounds.width
        let clipH = contentClipLayer.bounds.height
        guard clipH > 0 else { return }

        let ratio  = min(1, clipH / contentHeight)
        let indH   = max(16, clipH * ratio)
        let frac   = scrollOffsetPx / maxScrollOffset
        // y-up: scroll=0 → indicator at top (clipH - indH); scroll=max → indicator at bottom (0).
        let indY   = (1 - frac) * (clipH - indH)
        let indW: CGFloat = 3

        scrollIndicatorLayer.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollIndicatorLayer.frame = CGRect(
            x: clipW - indW - 2,
            y: indY,
            width: indW,
            height: indH
        )
        CATransaction.commit()
    }

    private func scheduleGeoRender() {
        geoRenderGen &+= 1
        let gen  = geoRenderGen
        let json = currentContent
        let size = lastGeoSize
        PinttyGeoRenderer.render(eventsJSON: json, size: size) { [weak self] image in
            guard let self, self.geoRenderGen == gen else { return }
            self.contentImageLayer.contents = image
        }
    }

    /// Load image from content string. Supports two formats:
    ///   "data:<base64>"  — base64-encoded PNG or JPEG (from an overlay-API image action)
    ///   "path:<filepath>" — local filesystem path (legacy)
    private func loadImageContent(_ content: String) -> CGImage? {
        let data: Data?
        if content.hasPrefix("data:") {
            let b64 = String(content.dropFirst(5))
            data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        } else if content.hasPrefix("path:") {
            let path = String(content.dropFirst(5))
            data = path.isEmpty ? nil : (try? Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            data = nil
        }
        guard let d = data,
              let source = CGImageSourceCreateWithData(d as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    private func measureTextHeight(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let storage   = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineBreakMode = .byWordWrapping
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + Self.contentPad
    }

    // MARK: - Animations

    func animateSpawn() {
        let dur = 0.22
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue      = 0.88
        scale.toValue        = 1.0
        scale.duration       = dur
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(scale, forKey: "spawn.scale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = Float(0)
        fade.toValue        = Float(1)
        fade.duration       = dur
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(fade, forKey: "spawn.fade")

        opacity = 1.0
    }

    func animateDespawn(completion: @escaping () -> Void) {
        let dur = 0.18
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue            = Float(1)
        scale.toValue              = Float(0.88)
        scale.duration             = dur
        scale.fillMode             = .forwards
        scale.isRemovedOnCompletion = false
        scale.timingFunction       = CAMediaTimingFunction(name: .easeIn)
        add(scale, forKey: "despawn.scale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue            = opacity
        fade.toValue              = Float(0)
        fade.duration             = dur
        fade.fillMode             = .forwards
        fade.isRemovedOnCompletion = false
        fade.timingFunction       = CAMediaTimingFunction(name: .easeIn)
        add(fade, forKey: "despawn.fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { completion() }
    }

    func animateMove(to newFrame: CGRect) {
        let fromPos = (presentation() ?? self).position

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = newFrame
        CATransaction.commit()

        let newPos = position
        guard fromPos != newPos else { return }

        let spring           = CASpringAnimation(keyPath: "position")
        spring.damping       = 16
        spring.stiffness     = 220
        spring.mass          = 1.0
        spring.duration      = spring.settlingDuration
        spring.fromValue     = fromPos
        spring.toValue       = newPos
        add(spring, forKey: "move.position")
    }

    func animateFocus() {
        let kf = CAKeyframeAnimation(keyPath: "strokeColor")
        kf.values = [
            PinttyColors.panelBorderDim.cgColor,
            PinttyColors.panelBorderFocus.cgColor,
            PinttyColors.panelBorderDim.cgColor,
        ]
        kf.keyTimes        = [0, 0.12, 1.0]
        kf.duration        = 1.0
        kf.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
        ]
        borderLayer.add(kf, forKey: "focus.border")
    }
}

/// A live HUD instrument: a 270° radial gauge (value vs min/max) with a centered numeric
/// readout + unit + label, and a rolling sparkline of recent values along the bottom strip.
/// Fed JSON `{"value":N,"min":N,"max":N,"unit":"…","label":"…"}` via `apply(json:)`.
final class PinttyGaugeLayer: CALayer {
    private static let neon  = PinttyColors.accent.cgColor
    private static let track = PinttyColors.accentDim.cgColor

    private let trackArc   = CAShapeLayer()
    private let valueArc   = CAShapeLayer()
    private let valueText  = CATextLayer()
    private let unitText   = CATextLayer()
    private let labelText  = CATextLayer()
    private let sparkLayer = CAShapeLayer()

    private var value: CGFloat = 0
    private var minV:  CGFloat = 0
    private var maxV:  CGFloat = 100
    private var unit:  String  = ""
    private var label: String  = ""
    private var history: [CGFloat] = []

    override init() {
        super.init()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        trackArc.fillColor   = nil
        trackArc.strokeColor = Self.track
        trackArc.lineWidth   = 6
        trackArc.lineCap     = .round
        addSublayer(trackArc)

        valueArc.fillColor    = nil
        valueArc.strokeColor  = Self.neon
        valueArc.lineWidth    = 6
        valueArc.lineCap      = .round
        valueArc.strokeEnd    = 0
        valueArc.shadowColor  = Self.neon
        valueArc.shadowRadius = 5
        valueArc.shadowOpacity = 0.8
        valueArc.shadowOffset = .zero
        addSublayer(valueArc)

        valueText.alignmentMode   = .center
        valueText.foregroundColor = PinttyColors.titleColor.cgColor
        valueText.font            = NSFont.systemFont(ofSize: 26, weight: .semibold)
        valueText.fontSize        = 26
        valueText.contentsScale   = scale
        addSublayer(valueText)

        unitText.alignmentMode   = .center
        unitText.foregroundColor = PinttyColors.contentText.cgColor
        unitText.font            = NSFont.systemFont(ofSize: 11, weight: .regular)
        unitText.fontSize        = 11
        unitText.contentsScale   = scale
        addSublayer(unitText)

        labelText.alignmentMode   = .center
        labelText.foregroundColor = Self.neon
        labelText.font            = NSFont.systemFont(ofSize: 11, weight: .medium)
        labelText.fontSize        = 11
        labelText.contentsScale   = scale
        addSublayer(labelText)

        sparkLayer.fillColor   = nil
        sparkLayer.strokeColor = Self.neon
        sparkLayer.lineWidth   = 1.5
        sparkLayer.lineJoin    = .round
        sparkLayer.opacity     = 0.85
        addSublayer(sparkLayer)
    }

    required init?(coder: NSCoder) { nil }
    override init(layer: Any) { super.init(layer: layer) }

    func apply(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        func num(_ key: String, _ fallback: CGFloat) -> CGFloat {
            if let n = obj[key] as? NSNumber { return CGFloat(truncating: n) }
            return fallback
        }
        value = num("value", value)
        minV  = num("min", 0)
        maxV  = num("max", 100)
        unit  = (obj["unit"]  as? String) ?? unit
        label = (obj["label"] as? String) ?? label

        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        relayout()
    }

    func relayout() {
        let b = bounds
        guard b.width > 8, b.height > 8 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Bottom strip reserved for the sparkline; gauge fills the rest.
        let sparkH = min(28, b.height * 0.22)
        let gauge  = CGRect(x: 0, y: sparkH, width: b.width, height: b.height - sparkH)

        let cx = gauge.midX
        let cy = gauge.midY
        let radius = max(8, min(gauge.width, gauge.height) / 2 - 16)

        // 270° sweep with the opening at the bottom (225° → -45°, clockwise).
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                   startAngle: .pi * 1.25, endAngle: -.pi * 0.25, clockwise: true)
        trackArc.path = arc
        valueArc.path = arc

        let range = max(0.0001, maxV - minV)
        valueArc.strokeEnd = max(0, min(1, (value - minV) / range))

        valueText.string = formatValue(value)
        valueText.frame  = CGRect(x: cx - radius, y: cy - 4,  width: radius * 2, height: 30)
        unitText.string  = unit
        unitText.frame   = CGRect(x: cx - radius, y: cy - 20, width: radius * 2, height: 14)
        labelText.string = label
        labelText.frame  = CGRect(x: 0, y: gauge.maxY - 15, width: b.width, height: 14)

        rebuildSparkline(in: CGRect(x: 6, y: 4, width: b.width - 12, height: sparkH - 6))
    }

    private func formatValue(_ v: CGFloat) -> String {
        let rounded = (v * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }

    private func rebuildSparkline(in rect: CGRect) {
        guard rect.width > 2, rect.height > 2, history.count >= 2 else {
            sparkLayer.path = nil
            return
        }
        let lo = history.min() ?? 0
        let hi = history.max() ?? 1
        let span = max(0.0001, hi - lo)
        let stepX = rect.width / CGFloat(history.count - 1)
        let path = CGMutablePath()
        for (i, v) in history.enumerated() {
            let x = rect.minX + CGFloat(i) * stepX
            let y = rect.minY + (v - lo) / span * rect.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else      { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        sparkLayer.path = path
    }
}
