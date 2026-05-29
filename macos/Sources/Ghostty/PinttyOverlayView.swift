import AppKit
import CoreImage
import QuartzCore
import SwiftUI
import GhosttyKit

/// SwiftUI bridge that hosts the AppKit overlay above the terminal surface.
/// Pass-through: it only intercepts events when the cursor is over a panel,
/// so the terminal behaves normally when no panels are present.
struct PinttyOverlayRepresentable: NSViewRepresentable {
    let app: ghostty_app_t

    func makeNSView(context: Context) -> PinttyOverlayView {
        PinttyOverlayView(overlayState: pintty_app_overlay_state(app), app: app)
    }

    func updateNSView(_ nsView: PinttyOverlayView, context: Context) {}
}

/// Always-on liquid-glass backdrop for canvas mode. Ghostty's own window blur only samples
/// the desktop while the window is key, so an unfocused canvas turns black; this `.behindWindow`
/// effect view with `state = .active` keeps the frosted glass alive regardless of focus. It sits
/// at the very bottom of the terminal ZStack, below the (hidden) base terminal and the overlay.
struct PinttyGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active               // do NOT follow window active state — stay glass
        v.isEmphasized = false
        v.alphaValue = PinttyColors.canvasGlassOpacity
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
        nsView.alphaValue = PinttyColors.canvasGlassOpacity
    }
}

/// Floating panel overlay rendered as CALayers above the terminal surface.
final class PinttyOverlayView: NSView {

    // MARK: - State

    private let overlayState: pintty_overlay_state_t
    /// The ghostty app handle, used to spawn live terminal surfaces inside canvas windows.
    private let app: ghostty_app_t
    private var displayLink: CVDisplayLink?

    /// When true, the overlay is the whole app: the base terminal is hidden so the
    /// window's frosted glass shows through, the overlay paints a faint glass film,
    /// and it swallows clicks on the empty canvas so they don't fall through.
    private let canvasMode = PinttyCanvas.enabled

    /// Live terminal windows (content_type == "terminal") keyed by panel id.
    private var terminalWindows: [String: PinttyTerminalWindow] = [:]
    /// Panel ids the user closed locally; suppressed from respawn until they leave the snapshot.
    private var locallyClosed: Set<String> = []

    // MARK: - P2 layers / ambient depth

    /// The z-plane currently in focus. Panels off this layer recede (dim/blur/scale) and
    /// become pass-through ambient context.
    private var activeLayer: Int = 0
    /// Last active layer read from the backend; lets a socket `active_layer` command win
    /// over local hotkey changes only when it actually changes.
    private var lastBackendActiveLayer: Int = 0
    /// Each panel/window's layer index, keyed by id.
    private var panelLayerIndex: [String: Int] = [:]
    /// Live panel layers keyed by panel id.
    private var panelLayers: [String: PinttyPanelLayer] = [:]
    /// Panels currently running a despawn animation (excluded from sync until removed).
    private var despawning: Set<String> = []
    /// Last known focus state per panel to detect transitions.
    private var focusState: [String: Bool] = [:]
    /// Accumulated scroll offset (px) per panel id from both IPC and mouse wheel.
    private var panelScrollPx: [String: CGFloat] = [:]
    /// NSEvent local monitor for scroll wheel input.
    private var scrollMonitor: Any?
    /// NSEvent local monitor for Cmd+Shift+P toggle hotkey.
    private var keyMonitor: Any?
    /// NSEvent local monitor for modifier-hold window move/resize (flagsChanged + mouseMoved).
    private var cmdMoveMonitor: Any?

    /// While a modifier is held, the window/panel grabbed by the pointer and what we're doing
    /// to it: Cmd = move, Control = resize (from bottom-right, top-left anchored).
    private enum GrabMode { case move, resize }
    private struct CmdGrab { let id: String; let isTerminal: Bool; let mode: GrabMode; var lastMouse: CGPoint }
    private var cmdGrab: CmdGrab?

    // MARK: - P3 remote cursor / bidirectional channel

    /// Controller-driven pointer sprite, kept above all panels. Lazily created on first show.
    private var cursorLayer: PinttyCursorLayer?

    /// Keybind cheat-sheet overlay (Cmd+/). Lazily created on first toggle, kept above all.
    private var cheatSheet: PinttyCheatSheet?

    // MARK: - P4 wires / dataflow

    /// Dataflow wire layers keyed by wire id.
    private var wireLayers: [String: PinttyWireLayer] = [:]
    /// Holds all wire layers, pinned to the back so wires render behind every panel/window.
    private var wireContainer: CALayer?

    // MARK: - M7 drag / local-position state

    private enum DragKind { case move, resize }
    private struct DragState {
        let id: String
        let kind: DragKind
        let startMouse: CGPoint
        let startFrame: CGRect
    }
    private var dragging: DragState?

    /// Client-side frame overrides (set by drag/resize, cleared when IPC moves/resizes the panel).
    private var localFrames:   [String: CGRect] = [:]
    /// Pre-collapse frames, keyed by panel id.
    private var expandedFrames: [String: CGRect] = [:]
    /// Panels currently collapsed to title-bar only.
    private var collapsedPanels: Set<String> = []
    /// Last snapshot percentages per id — used to detect IPC-driven position changes.
    private var lastSnapPcts: [String: (Float, Float, Float, Float)] = [:]

    // MARK: - Init

    init(overlayState: pintty_overlay_state_t, app: ghostty_app_t) {
        self.overlayState = overlayState
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = canvasMode ? PinttyColors.canvasBackdrop.cgColor : .clear
        setupDisplayLink()
        setupScrollMonitor()
        setupKeyMonitor()
        setupCmdMoveMonitor()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
        if let m = scrollMonitor   { NSEvent.removeMonitor(m) }
        if let m = keyMonitor      { NSEvent.removeMonitor(m) }
        if let m = cmdMoveMonitor  { NSEvent.removeMonitor(m) }
    }

    // MARK: - Display link

    private func setupDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            guard let ctx else { return kCVReturnSuccess }
            Unmanaged<PinttyOverlayView>.fromOpaque(ctx).takeUnretainedValue().displayLinkTick()
            return kCVReturnSuccess
        }, selfPtr)

        CVDisplayLinkStart(dl)
        self.displayLink = dl
    }

    private func displayLinkTick() {
        guard pintty_overlay_consume_dirty(overlayState) else { return }
        DispatchQueue.main.async { [weak self] in self?.syncPanels() }
    }

    // MARK: - Panel sync

    private func syncPanels() {
        let maxPanels: Int = 64
        var snaps = [pintty_panel_snapshot_s](repeating: pintty_panel_snapshot_s(), count: maxPanels)
        let count = Int(pintty_overlay_snapshot(overlayState, &snaps, maxPanels))

        // Adopt a backend-driven active layer only when it actually changes, so local
        // hotkey changes aren't clobbered every tick.
        let backendActive = Int(pintty_overlay_active_layer(overlayState))
        if backendActive != lastBackendActiveLayer {
            lastBackendActiveLayer = backendActive
            activeLayer = backendActive
        }

        let bounds = self.bounds
        var seen = Set<String>()

        for i in 0..<count {
            let snap = snaps[i]
            let id    = cString(snap.id)
            let title = cString(snap.title)
            seen.insert(id)
            panelLayerIndex[id] = Int(snap.layer)

            let isFocused = snap.focused != 0
            let content     = cString(snap.content)
            let contentType = cString(snap.content_type)

            // Detect IPC-driven position change and clear any local override.
            let pct = (snap.x_pct, snap.y_pct, snap.w_pct, snap.h_pct)
            if let prev = lastSnapPcts[id],
               prev.0 != pct.0 || prev.1 != pct.1 || prev.2 != pct.2 || prev.3 != pct.3 {
                localFrames.removeValue(forKey: id)
                expandedFrames.removeValue(forKey: id)
                collapsedPanels.remove(id)
            }
            lastSnapPcts[id] = pct

            // Use client-side frame override if present, otherwise derive from snapshot.
            let rect = localFrames[id] ?? panelRect(snap: snap, in: bounds)

            // Terminal windows host a live SurfaceView; managed as NSView subviews, not CALayers.
            if contentType == "terminal" {
                if locallyClosed.contains(id) { continue }
                if let tw = terminalWindows[id] {
                    tw.isHidden = snap.visible == 0
                    tw.setTitle(title.isEmpty ? "terminal" : title)
                    if !tw.isDragging && tw.frame != rect {
                        tw.frame = rect
                        tw.layoutChrome()
                    }
                } else if !despawning.contains(id) {
                    let surface = Ghostty.SurfaceView(app, baseConfig: nil)
                    let tw = PinttyTerminalWindow(id: id, surface: surface)
                    tw.frame = rect
                    tw.setTitle(title.isEmpty ? "terminal" : title)
                    tw.isHidden = snap.visible == 0
                    tw.onFrameChanged = { [weak self] cid, f in
                        self?.localFrames[cid] = f
                        self?.updateWirePaths()
                    }
                    tw.onClose = { [weak self] cid in self?.closeTerminalWindow(cid) }
                    tw.onFocus = { [weak self] cid in self?.emit(["event": "focus", "id": cid]) }
                    tw.onCommit = { [weak self] cid, f, isResize in
                        guard let self else { return }
                        let p = self.pct(of: f)
                        if isResize {
                            self.emit(["event": "resize", "id": cid, "w_pct": p.w, "h_pct": p.h])
                        } else {
                            self.emit(["event": "move", "id": cid, "x_pct": p.x, "y_pct": p.y])
                        }
                    }
                    addSubview(tw)
                    terminalWindows[id] = tw
                    DispatchQueue.main.async { [weak self, weak surface] in
                        guard let surface else { return }
                        self?.window?.makeFirstResponder(surface)
                    }
                }
                continue
            }

            // Accumulate IPC scroll delta (lines → px via layer's lineHeight).
            if snap.scroll_delta != 0, let pl = panelLayers[id] {
                panelScrollPx[id] = (panelScrollPx[id] ?? 0) + CGFloat(snap.scroll_delta) * pl.lineHeight
            }

            if let pl = panelLayers[id] {
                pl.setTitle(title)
                pl.setContent(content, type: contentType)
                pl.isHidden = snap.visible == 0

                // Skip position update while the user is dragging this panel.
                if dragging?.id != id && pl.frame != rect {
                    pl.animateMove(to: rect)
                }

                let clampedScroll = max(0, min(pl.maxScrollOffset, panelScrollPx[id] ?? 0))
                panelScrollPx[id] = clampedScroll
                pl.applyScrollOffset(clampedScroll)

                let wasFocused = focusState[id] ?? false
                if isFocused && !wasFocused {
                    pl.animateFocus()
                    // Bring newly focused panel to front.
                    pl.removeFromSuperlayer()
                    layer?.addSublayer(pl)
                }

            } else if !despawning.contains(id) {
                let pl = PinttyPanelLayer(id: id, title: title)
                pl.frame    = rect
                pl.isHidden = snap.visible == 0
                pl.setContent(content, type: contentType)
                layer?.addSublayer(pl)
                panelLayers[id] = pl
                panelScrollPx[id] = 0
                pl.animateSpawn()
            }

            focusState[id] = isFocused
        }

        // Despawn panels no longer in the snapshot.
        let toRemove = panelLayers.keys.filter { !seen.contains($0) && !despawning.contains($0) }
        for id in toRemove {
            guard let pl = panelLayers[id] else { continue }
            despawning.insert(id)
            pl.animateDespawn { [weak self] in
                guard let self else { return }
                pl.removeFromSuperlayer()
                self.panelLayers.removeValue(forKey: id)
                self.focusState.removeValue(forKey: id)
                self.panelScrollPx.removeValue(forKey: id)
                self.localFrames.removeValue(forKey: id)
                self.expandedFrames.removeValue(forKey: id)
                self.lastSnapPcts.removeValue(forKey: id)
                self.collapsedPanels.remove(id)
                self.despawning.remove(id)
            }
        }

        // Despawn terminal windows no longer in the snapshot; release local-close suppression.
        for id in terminalWindows.keys.filter({ !seen.contains($0) }) {
            terminalWindows[id]?.removeFromSuperview()
            terminalWindows.removeValue(forKey: id)
            localFrames.removeValue(forKey: id)
            lastSnapPcts.removeValue(forKey: id)
        }
        locallyClosed.formIntersection(seen)
        for id in panelLayerIndex.keys where !seen.contains(id) {
            panelLayerIndex.removeValue(forKey: id)
        }

        syncWires()
        applyLayering()
        syncCursor()
    }

    // MARK: - P3 remote cursor

    /// Read the controller cursor state and update the pointer sprite. Kept topmost (re-added
    /// after applyLayering, which reorders panel sublayers).
    private func syncCursor() {
        var snap = pintty_cursor_snapshot_s()
        pintty_overlay_cursor(overlayState, &snap)

        guard snap.visible != 0 else {
            cursorLayer?.isHidden = true
            return
        }

        let cl: PinttyCursorLayer
        if let existing = cursorLayer {
            cl = existing
        } else {
            cl = PinttyCursorLayer()
            cursorLayer = cl
        }
        if cl.superlayer == nil { layer?.addSublayer(cl) }
        // Keep the cursor above everything else.
        cl.removeFromSuperlayer()
        layer?.addSublayer(cl)
        cl.isHidden = false

        cl.setLabel(cString(snap.label))
        // Protocol uses top-left origin; CA is bottom-left. The sprite's tip is its anchor.
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cl.position = CGPoint(
            x: b.width * CGFloat(snap.x_pct),
            y: b.height * (1.0 - CGFloat(snap.y_pct))
        )
        CATransaction.commit()

        if snap.click != 0 { cl.pulse() }
    }

    // MARK: - P4 wires / dataflow

    /// The current screen frame of a panel or terminal window, in overlay (CA, y-up) coords.
    private func frameForId(_ id: String) -> CGRect? {
        if let tw = terminalWindows[id] { return tw.frame }
        if let pl = panelLayers[id] { return pl.frame }
        return nil
    }

    /// Reconcile the backend wire set into `wireLayers`, restyle, and lay out paths.
    private func syncWires() {
        let maxWires = 64
        let wireCount = Int(pintty_overlay_wire_count(overlayState))
        guard wireCount > 0 || !wireLayers.isEmpty else { return }

        // Lazily create the back container; pin it behind all panels (index 0).
        let container: CALayer
        if let c = wireContainer {
            container = c
        } else {
            container = CALayer()
            container.zPosition = -1
            wireContainer = container
            layer?.insertSublayer(container, at: 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()

        var snaps = [pintty_wire_snapshot_s](repeating: pintty_wire_snapshot_s(), count: maxWires)
        let count = Int(pintty_overlay_wires(overlayState, &snaps, maxWires))
        var seen = Set<String>()

        for i in 0..<count {
            let snap = snaps[i]
            let id = cString(snap.id)
            seen.insert(id)

            let wl: PinttyWireLayer
            if let existing = wireLayers[id] {
                wl = existing
            } else {
                wl = PinttyWireLayer()
                wireLayers[id] = wl
                container.addSublayer(wl)
            }
            wl.fromId = cString(snap.from_id)
            wl.toId = cString(snap.to_id)
            wl.isHidden = snap.active == 0
            wl.configure(color: wireColor(snap.color), label: cString(snap.label))
            if snap.pulse > 0 { wl.pulse(intensity: CGFloat(snap.pulse)) }
        }

        // Remove wires the backend dropped.
        for id in wireLayers.keys where !seen.contains(id) {
            wireLayers[id]?.removeFromSuperlayer()
            wireLayers.removeValue(forKey: id)
        }

        updateWirePaths()
    }

    /// Recompute every wire's bezier from its endpoints' live frames. Cheap; safe to call on
    /// drag so wires track windows as they move.
    private func updateWirePaths() {
        guard !wireLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for wl in wireLayers.values {
            guard let a = frameForId(wl.fromId), let b = frameForId(wl.toId) else {
                wl.isHidden = true
                continue
            }
            let rightward = b.midX >= a.midX
            let start = CGPoint(x: rightward ? a.maxX : a.minX, y: a.midY)
            let end   = CGPoint(x: rightward ? b.minX : b.maxX, y: b.midY)
            wl.setPath(from: start, to: end)
        }
        CATransaction.commit()
    }

    /// Packed 0xRRGGBB → Display P3 CGColor; 0 = default neon.
    private func wireColor(_ packed: UInt32) -> CGColor {
        guard packed != 0 else { return PinttyWireLayer.neon }
        return NSColor(
            displayP3Red: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1.0
        ).cgColor
    }

    // MARK: - Layers / ambient depth (P2)

    /// Distinct layer indices currently present, ascending.
    private var presentLayers: [Int] {
        Array(Set(panelLayerIndex.values)).sorted()
    }

    private func isActive(_ id: String) -> Bool {
        (panelLayerIndex[id] ?? 0) == activeLayer
    }

    /// Ambient depth for a given layer: the active plane is crisp; others dim and blur with
    /// distance so the focused plane reads as "in front". (No transform scale — it fights the
    /// frame-based layout AppKit and the panels use.)
    private func depthStyle(forLayer l: Int) -> (opacity: Float, blur: CGFloat) {
        let dist = abs(l - activeLayer)
        if dist == 0 { return (1.0, 0) }
        let d = CGFloat(dist)
        let opacity = Float(max(0.30, 1.0 - 0.28 * d))
        let blur    = min(10.0, 3.5 * d)
        return (opacity, blur)
    }

    private func blurFilter(_ radius: CGFloat) -> CIFilter? {
        guard radius > 0,
              let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(radius, forKey: kCIInputRadiusKey)
        return f
    }

    /// Signature of the inputs to layering; reorder/restyle only when it changes so we don't
    /// thrash the view hierarchy on every display-link tick.
    private var lastLayeringSig = ""

    /// Apply z-order + ambient depth to every panel layer and terminal window.
    /// Z-order key: non-active planes sit behind the active plane; within a group, by layer
    /// then focus. Depth (dim/blur) is keyed off distance from the active layer.
    private func applyLayering() {
        let panelSig = panelLayers.keys
            .map { "\($0):\(panelLayerIndex[$0] ?? 0):\(focusState[$0] ?? false ? 1 : 0)" }
        let winSig = terminalWindows.keys.map { "\($0):\(panelLayerIndex[$0] ?? 0)" }
        let sig = "\(activeLayer)|" + (panelSig + winSig).sorted().joined(separator: ",")
        if sig == lastLayeringSig { return }
        lastLayeringSig = sig

        func sortKey(id: String, focused: Bool) -> (Int, Int, Int) {
            let l = panelLayerIndex[id] ?? 0
            return (l == activeLayer ? 1 : 0, l, focused ? 1 : 0)
        }

        // --- Content panels (CALayers) ---
        let panels = panelLayers.values.sorted {
            sortKey(id: $0.panelId, focused: focusState[$0.panelId] ?? false) <
            sortKey(id: $1.panelId, focused: focusState[$1.panelId] ?? false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pl in panels {
            let style = depthStyle(forLayer: panelLayerIndex[pl.panelId] ?? 0)
            pl.removeFromSuperlayer()
            layer?.addSublayer(pl)
            pl.opacity = style.opacity
            pl.filters = blurFilter(style.blur).map { [$0] }
        }
        CATransaction.commit()

        // --- Terminal windows (NSView subviews) ---
        let wins = terminalWindows.values.sorted {
            sortKey(id: $0.id, focused: false) < sortKey(id: $1.id, focused: false)
        }
        for tw in wins {
            let style = depthStyle(forLayer: panelLayerIndex[tw.id] ?? 0)
            addSubview(tw)  // moves to front in subview order
            // Dim only — a CIFilter blur on the Metal-backed surface layer crashes the
            // compositor. Opacity alone reads clearly as "receded" for terminals.
            tw.alphaValue = CGFloat(style.opacity)
        }
    }

    /// Shift the active layer by `delta`, clamped to the layers that actually exist.
    private func changeActiveLayer(by delta: Int) {
        let layers = presentLayers
        guard !layers.isEmpty else { return }
        let lo = layers.first!, hi = layers.last!
        activeLayer = max(lo, min(hi, activeLayer + delta))
        // Don't touch lastBackendActiveLayer: it must keep tracking the real backend value so a
        // local hotkey change isn't mistaken for a backend edge and reverted on the next sync.
        applyLayering()
        emit(["event": "active_layer", "layer": activeLayer])
    }

    /// User clicked a terminal window's close button: remove it locally and suppress respawn
    /// until the backend drops it from the snapshot (one-way bridge has no write-back yet).
    private func closeTerminalWindow(_ id: String) {
        terminalWindows[id]?.removeFromSuperview()
        terminalWindows.removeValue(forKey: id)
        localFrames.removeValue(forKey: id)
        locallyClosed.insert(id)
        // Remove from backend state too so it doesn't linger as a zombie panel.
        let len = id.utf8.count
        id.withCString { ptr in pintty_overlay_despawn(overlayState, ptr, len) }
        emit(["event": "close", "id": id])
    }

    // MARK: - Key monitor
    // Cmd+Shift+P → toggle all panels. Cmd+Shift+. / , → raise / lower the active layer.
    // Period/comma (not brackets) because the terminal already owns Cmd+Shift+]/[ for tab nav.

    private let kVK_ANSI_P: UInt16 = 35
    private let kVK_ANSI_Period: UInt16 = 47
    private let kVK_ANSI_Comma: UInt16 = 43
    private let kVK_ANSI_KeypadDecimal: UInt16 = 65
    private let kVK_JIS_KeypadComma: UInt16 = 95
    private let kVK_ANSI_Equal: UInt16 = 24
    private let kVK_ANSI_Minus: UInt16 = 27
    private let kVK_ANSI_0: UInt16 = 29
    private let kVK_ANSI_KeypadPlus: UInt16 = 69
    private let kVK_ANSI_KeypadMinus: UInt16 = 78
    private let kVK_ANSI_Keypad0: UInt16 = 82
    private let kVK_ANSI_W: UInt16 = 13
    private let kVK_ANSI_T: UInt16 = 17
    private let kVK_ANSI_Slash: UInt16 = 44
    private let kVK_Escape: UInt16 = 53

    /// Monotonic counter for generating unique ids for locally-spawned windows.
    private var spawnCounter: Int = 0

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only the four real chord modifiers; ignore incidental flags (capsLock, numericPad,
            // function) which the keypad/laptop keys can carry.
            let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])

            // Cmd+/ → toggle the keybind cheat-sheet. Esc dismisses it when shown.
            if mods == [.command], event.keyCode == self.kVK_ANSI_Slash {
                self.toggleCheatSheet()
                return nil
            }
            if event.keyCode == self.kVK_Escape, self.cheatSheet?.superview != nil {
                self.hideCheatSheet()
                return nil
            }

            // Cmd+T → spawn a new shell window centered under the pointer. Canvas mode hides
            // tabs, so the familiar "new tab" key is repurposed to add a window to the canvas.
            if mods == [.command], event.keyCode == self.kVK_ANSI_T {
                self.spawnTerminalUnderCursor()
                return nil
            }

            // Cmd+W → close only the shell window under the pointer, not the whole app.
            // Consumed so Ghostty's close-window/tab doesn't fire; passes through if the
            // pointer isn't over a canvas window.
            if mods == [.command], event.keyCode == self.kVK_ANSI_W {
                if let tw = self.shellWindowUnderPointer() {
                    self.closeTerminalWindow(tw.id)
                    return nil
                }
                return event
            }

            // Cmd +/-/0 → resize the interior text (font size) of a shell window, like a
            // normal terminal. Accept Cmd and Cmd+Shift (so both Cmd+= and Cmd++ zoom in).
            if mods == [.command] || mods == [.command, .shift] {
                switch event.keyCode {
                case self.kVK_ANSI_Equal, self.kVK_ANSI_KeypadPlus:
                    if self.changeShellFontSize(.increase(1)) { return nil }
                case self.kVK_ANSI_Minus, self.kVK_ANSI_KeypadMinus:
                    if self.changeShellFontSize(.decrease(1)) { return nil }
                case self.kVK_ANSI_0, self.kVK_ANSI_Keypad0:
                    if mods == [.command], self.changeShellFontSize(.reset) { return nil }
                default:
                    break
                }
            }

            guard mods == [.command, .shift] else { return event }
            switch event.keyCode {
            case self.kVK_ANSI_P:
                self.toggleAllPanels()
                return nil
            case self.kVK_ANSI_Period, self.kVK_ANSI_KeypadDecimal:
                self.changeActiveLayer(by: 1)
                return nil
            case self.kVK_ANSI_Comma, self.kVK_JIS_KeypadComma:
                self.changeActiveLayer(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    /// Apply a font-size change to a shell (terminal) window's live surface. Targets the
    /// window under the pointer if it's a terminal, else the first-responder terminal, else
    /// the front-most terminal window. Returns false (caller passes the key through) if there
    /// is no shell window to act on — so this only ever affects shells, never panels.
    private func changeShellFontSize(_ change: Ghostty.App.FontSizeModification) -> Bool {
        guard let tw = targetShellWindow(), let surface = tw.surface.surface else { return false }
        let action: String
        switch change {
        case .increase(let n): action = "increase_font_size:\(n)"
        case .decrease(let n): action = "decrease_font_size:\(n)"
        case .reset:           action = "reset_font_size"
        }
        return ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
    }

    /// Spawn a new live shell window centered on the pointer, clamped within the canvas.
    /// Registers it in the backend so the next snapshot creates the SurfaceView (a purely
    /// local window would be culled by syncPanels reconciliation).
    private func spawnTerminalUnderCursor() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let w = b.width * 0.40
        let h = b.height * 0.46
        let mouse = convert(window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: b.midX, y: b.midY), from: nil)
        var origin = CGPoint(x: mouse.x - w / 2, y: mouse.y - h / 2)
        origin.x = max(0, min(b.width  - w, origin.x))
        origin.y = max(0, min(b.height - h, origin.y))
        let p = pct(of: CGRect(x: origin.x, y: origin.y, width: w, height: h))
        spawnCounter += 1
        let id = "win-\(spawnCounter)"
        let len = id.utf8.count
        id.withCString { ptr in
            pintty_overlay_spawn_terminal(overlayState, ptr, len, p.x, p.y, p.w, p.h)
        }
    }

    /// The shell window directly under the pointer, or nil. Used by Cmd+W so a close only
    /// ever targets the window you're pointing at.
    private func shellWindowUnderPointer() -> PinttyTerminalWindow? {
        let mouse = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        for tw in subviews.reversed().compactMap({ $0 as? PinttyTerminalWindow })
        where !tw.isHidden && isActive(tw.id) {
            if tw.frame.contains(mouse) { return tw }
        }
        return nil
    }

    /// Pick which shell window a font-size keybind acts on: pointer → first responder → front.
    private func targetShellWindow() -> PinttyTerminalWindow? {
        let mouse = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        for tw in terminalWindows.values where !tw.isHidden && isActive(tw.id) {
            if tw.frame.contains(mouse) { return tw }
        }
        if let fr = window?.firstResponder as? NSView {
            for tw in terminalWindows.values where tw.surface === fr || fr.isDescendant(of: tw) {
                return tw
            }
        }
        // Front-most = last terminal window in subview order.
        return subviews.reversed().compactMap { $0 as? PinttyTerminalWindow }
            .first { !$0.isHidden && isActive($0.id) }
    }

    private func toggleAllPanels() {
        guard let sublayers = layer?.sublayers else { return }
        let panels = sublayers.compactMap { $0 as? PinttyPanelLayer }
        let anyVisible = panels.contains { !$0.isHidden }
        for pl in panels { pl.isHidden = anyVisible }
    }

    // MARK: - Cheat sheet

    private func toggleCheatSheet() {
        if cheatSheet?.superview != nil { hideCheatSheet() } else { showCheatSheet() }
    }

    private func showCheatSheet() {
        let sheet = cheatSheet ?? PinttyCheatSheet()
        cheatSheet = sheet
        if sheet.superview == nil { addSubview(sheet) }
        sheet.frame.origin = CGPoint(
            x: (bounds.width  - sheet.frame.width)  / 2,
            y: (bounds.height - sheet.frame.height) / 2)
        sheet.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            sheet.animator().alphaValue = 1
        }
    }

    private func hideCheatSheet() {
        guard let sheet = cheatSheet, sheet.superview != nil else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            sheet.animator().alphaValue = 0
        }, completionHandler: { [weak sheet] in sheet?.removeFromSuperview() })
    }

    // MARK: - Modifier-hold window move / resize

    /// Hold Cmd (move) or Control (resize) — no click — and the window/panel under the
    /// pointer follows the mouse; release the modifier to drop it. `flagsChanged` begins/ends
    /// the grab, `mouseMoved` carries it.
    private func setupCmdMoveMonitor() {
        cmdMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { [weak self] event in
            guard let self else { return event }
            return self.handleCmdMove(event)
        }
    }

    private func handleCmdMove(_ event: NSEvent) -> NSEvent? {
        guard window != nil else { return event }
        // Exactly one of Cmd (move) / Control (resize) must be the active chord modifier.
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let mode: GrabMode? = mods == [.command] ? .move : (mods == [.control] ? .resize : nil)
        let mouse = convert(event.locationInWindow, from: nil)

        guard let mode else {
            if cmdGrab != nil { endCmdGrab() }
            return event
        }

        // Modifier held. Grab whatever sits under the pointer (or re-grab if the mode changed).
        if cmdGrab == nil || cmdGrab?.mode != mode {
            startCmdGrab(at: mouse, mode: mode)
            // Establish the anchor without jumping the window on the first sample.
            return cmdGrab != nil ? nil : event
        }

        guard var grab = cmdGrab else { return event }
        let dx = mouse.x - grab.lastMouse.x
        let dy = mouse.y - grab.lastMouse.y
        if dx == 0 && dy == 0 { return nil }

        if grab.isTerminal {
            guard let tw = terminalWindows[grab.id] else { endCmdGrab(); return event }
            tw.frame = adjustedFrame(tw.frame, dx: dx, dy: dy, mode: mode,
                                     minSize: PinttyTerminalWindow.minSize)
            tw.layoutChrome()
            localFrames[grab.id] = tw.frame
        } else {
            guard let pl = panelLayers[grab.id] else { endCmdGrab(); return event }
            let f = adjustedFrame(pl.frame, dx: dx, dy: dy, mode: mode,
                                  minSize: CGSize(width: 120, height: 60))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pl.frame = f
            CATransaction.commit()
            localFrames[grab.id] = f
        }
        updateWirePaths()
        grab.lastMouse = mouse
        cmdGrab = grab
        return nil
    }

    /// Apply one mouse-delta sample. Move = translate; resize = grow from the bottom-right
    /// with the top-left corner anchored (matches the corner-handle resize).
    private func adjustedFrame(_ frame: CGRect, dx: CGFloat, dy: CGFloat,
                               mode: GrabMode, minSize: CGSize) -> CGRect {
        var f = frame
        switch mode {
        case .move:
            f.origin.x += dx
            f.origin.y += dy
        case .resize:
            f.size.width = max(minSize.width, f.size.width + dx)
            let newH = max(minSize.height, f.size.height - dy)
            f.origin.y = f.maxY - newH   // keep the top edge anchored
            f.size.height = newH
        }
        return f
    }

    /// Grab the top-most window/panel under `mouse` (terminal windows win over panels) and
    /// raise it. Leaves `cmdGrab` nil if the pointer isn't over anything grabbable.
    private func startCmdGrab(at mouse: CGPoint, mode: GrabMode) {
        let cursor: NSCursor = mode == .resize ? .crosshair : .closedHand
        for tw in terminalWindows.values where !tw.isHidden && isActive(tw.id) {
            if tw.frame.contains(mouse) {
                addSubview(tw)  // bring to front within the overlay
                emit(["event": "focus", "id": tw.id])
                cursor.set()
                cmdGrab = CmdGrab(id: tw.id, isTerminal: true, mode: mode, lastMouse: mouse)
                return
            }
        }
        if let (id, pl) = topPanel(at: mouse) {
            pl.removeFromSuperlayer()
            layer?.addSublayer(pl)
            emit(["event": "focus", "id": id])
            cursor.set()
            cmdGrab = CmdGrab(id: id, isTerminal: false, mode: mode, lastMouse: mouse)
        }
    }

    /// Drop the carried window and report its committed geometry over the channel.
    private func endCmdGrab() {
        guard let grab = cmdGrab else { cmdGrab = nil; NSCursor.arrow.set(); return }
        cmdGrab = nil
        NSCursor.arrow.set()
        let frame: CGRect? = grab.isTerminal ? terminalWindows[grab.id]?.frame
                                             : panelLayers[grab.id]?.frame
        guard let f = frame else { return }
        let p = pct(of: f)
        switch grab.mode {
        case .move:   emit(["event": "move",   "id": grab.id, "x_pct": p.x, "y_pct": p.y])
        case .resize: emit(["event": "resize", "id": grab.id, "w_pct": p.w, "h_pct": p.h])
        }
    }

    // MARK: - Scroll monitor

    private func setupScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollEvent(event)
        }
    }

    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard self.window != nil else { return event }
        // Convert mouse location to this view's coordinate space.
        let windowPt = event.locationInWindow
        let viewPt   = convert(windowPt, from: nil)
        // Convert from NSView (y-up from bottom-left) to CALayer coords (same here since no transform).
        let layerPt  = CGPoint(x: viewPt.x, y: viewPt.y)

        // Find which panel the cursor is over (top-most first — last in dict iteration order isn't reliable,
        // so walk snapshot order by checking layers in reverse sublayer order).
        guard let rootLayer = layer else { return event }
        for sublayer in rootLayer.sublayers?.reversed() ?? [] {
            guard let pl = sublayer as? PinttyPanelLayer,
                  !pl.isHidden,
                  isActive(pl.panelId),
                  pl.frame.contains(layerPt) else { continue }
            let id = pl.panelId
            let deltaY = event.scrollingDeltaY
            // Positive deltaY = scroll up (content moves up = scrollOffset increases toward bottom of text).
            // Negate because scrolling up should show content further down.
            let deltaPx = -deltaY * 1.5
            let current = panelScrollPx[id] ?? 0
            let clamped = max(0, min(pl.maxScrollOffset, current + deltaPx))
            panelScrollPx[id] = clamped
            pl.applyScrollOffset(clamped)
            return nil  // consume the event
        }
        return event
    }

    // MARK: - Helpers

    private func panelRect(snap: pintty_panel_snapshot_s, in bounds: CGRect) -> CGRect {
        // Protocol uses top-left origin; CA uses bottom-left.
        CGRect(
            x: bounds.width  * CGFloat(snap.x_pct),
            y: bounds.height * (1.0 - CGFloat(snap.y_pct) - CGFloat(snap.h_pct)),
            width:  bounds.width  * CGFloat(snap.w_pct),
            height: bounds.height * CGFloat(snap.h_pct)
        )
    }

    // MARK: - Outbound events (bidirectional channel)

    /// Serialize a user-driven canvas event to JSON and push it to connected controllers.
    private func emit(_ event: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        let len = json.utf8.count
        json.withCString { ptr in
            pintty_overlay_emit_event(overlayState, ptr, len)
        }
    }

    /// Inverse of `panelRect`: CA-frame (bottom-left) → protocol percentages (top-left origin).
    private func pct(of frame: CGRect) -> (x: Float, y: Float, w: Float, h: Float) {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return (0, 0, 0, 0) }
        let w = Float(frame.width / b.width)
        let h = Float(frame.height / b.height)
        let x = Float(frame.minX / b.width)
        let y = Float(1.0 - (frame.minY / b.height)) - h
        return (x, y, w, h)
    }

    /// Read a null-terminated C char array field from a snapshot struct.
    private func cString<T>(_ field: T) -> String {
        var copy = field
        return withUnsafePointer(to: &copy) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
    }

    // MARK: - NSView

    override func layout() {
        super.layout()
        // Keep the cheat-sheet centered as the window resizes.
        if let sheet = cheatSheet, sheet.superview != nil {
            sheet.frame.origin = CGPoint(
                x: (bounds.width  - sheet.frame.width)  / 2,
                y: (bounds.height - sheet.frame.height) / 2)
        }
        // Defer out of the layout pass: syncPanels mutates the view hierarchy (addSubview /
        // addSublayer), which re-enters constraint layout and throws if done inline.
        DispatchQueue.main.async { [weak self] in self?.syncPanels() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Route events into terminal windows when hit; intercept over panels; otherwise pass through.
    /// Only the active layer is interactive — non-active planes are ambient and pass through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Terminal windows are real subviews — descend so the surface stays interactive.
        for tw in terminalWindows.values where !tw.isHidden && isActive(tw.id) {
            if tw.frame.contains(point) {
                return tw.hitTest(point) ?? tw
            }
        }
        guard let sublayers = layer?.sublayers else { return nil }
        for sublayer in sublayers.reversed() {
            if let pl = sublayer as? PinttyPanelLayer,
               !pl.isHidden, isActive(pl.panelId), pl.frame.contains(point) {
                return self
            }
        }
        // In canvas mode the overlay owns the whole surface, so capture empty-canvas
        // clicks instead of letting them fall through to the hidden base terminal.
        return canvasMode ? self : nil
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let (id, pl) = topPanel(at: pt) else { return }
        emit(["event": "focus", "id": id])

        if event.clickCount == 2 && isTitleBar(pt, panel: pl) {
            toggleCollapse(id: id, panel: pl)
            return
        }
        if isResizeHandle(pt, panel: pl) {
            dragging = DragState(id: id, kind: .resize, startMouse: pt, startFrame: pl.frame)
        } else if isTitleBar(pt, panel: pl) {
            dragging = DragState(id: id, kind: .move, startMouse: pt, startFrame: pl.frame)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = dragging, let pl = panelLayers[drag.id] else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - drag.startMouse.x
        let dy = pt.y - drag.startMouse.y

        var f = drag.startFrame
        switch drag.kind {
        case .move:
            NSCursor.closedHand.set()
            f.origin.x += dx
            f.origin.y += dy
        case .resize:
            // Resize from bottom-right: right edge and bottom edge move.
            f.size.width  = max(120, f.size.width  + dx)
            // In CA (y-up), dragging down = dy < 0; we want the panel to grow downward.
            f.origin.y    = f.origin.y + dy
            f.size.height = max(60, f.size.height - dy)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pl.frame = f
        CATransaction.commit()
        localFrames[drag.id] = f
        updateWirePaths()
    }

    override func mouseUp(with event: NSEvent) {
        // Report the committed geometry once, on drag end (not every dragged frame).
        if let drag = dragging, let pl = panelLayers[drag.id] {
            let p = pct(of: pl.frame)
            switch drag.kind {
            case .move:   emit(["event": "move",   "id": drag.id, "x_pct": p.x, "y_pct": p.y])
            case .resize: emit(["event": "resize", "id": drag.id, "w_pct": p.w, "h_pct": p.h])
            }
        }
        dragging = nil
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Right-click brings the panel to front (highest z-order).
    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let (_, pl) = topPanel(at: pt) else { return }
        pl.removeFromSuperlayer()
        layer?.addSublayer(pl)
    }

    // MARK: - Helpers

    private func updateCursor(at pt: CGPoint) {
        guard let (_, pl) = topPanel(at: pt) else { NSCursor.arrow.set(); return }
        if isTitleBar(pt, panel: pl) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func topPanel(at point: CGPoint) -> (String, PinttyPanelLayer)? {
        guard let sublayers = layer?.sublayers else { return nil }
        for sublayer in sublayers.reversed() {
            guard let pl = sublayer as? PinttyPanelLayer,
                  !pl.isHidden,
                  isActive(pl.panelId),
                  pl.frame.contains(point) else { continue }
            return (pl.panelId, pl)
        }
        return nil
    }

    private func isTitleBar(_ point: CGPoint, panel: PinttyPanelLayer) -> Bool {
        CGRect(
            x: panel.frame.minX,
            y: panel.frame.maxY - PinttyPanelLayer.titleHeight,
            width: panel.frame.width,
            height: PinttyPanelLayer.titleHeight
        ).contains(point)
    }

    private func isResizeHandle(_ point: CGPoint, panel: PinttyPanelLayer) -> Bool {
        let size: CGFloat = 16
        return CGRect(
            x: panel.frame.maxX - size,
            y: panel.frame.minY,
            width: size, height: size
        ).contains(point)
    }

    private func toggleCollapse(id: String, panel: PinttyPanelLayer) {
        if collapsedPanels.contains(id) {
            // Expand: restore saved frame.
            collapsedPanels.remove(id)
            let restored = expandedFrames.removeValue(forKey: id) ?? panel.frame
            localFrames[id] = restored
            panel.animateMove(to: restored)
            panel.setCollapsed(false)
        } else {
            // Collapse: shrink to title bar height only.
            collapsedPanels.insert(id)
            expandedFrames[id] = panel.frame
            let collapsed = CGRect(
                x: panel.frame.minX,
                y: panel.frame.maxY - PinttyPanelLayer.titleHeight,
                width: panel.frame.width,
                height: PinttyPanelLayer.titleHeight
            )
            localFrames[id] = collapsed
            panel.animateMove(to: collapsed)
            panel.setCollapsed(true)
        }
    }
}

/// A floating canvas window hosting a live terminal surface, with draggable title-bar
/// chrome, a close button, and a bottom-right resize handle. Self-contained: it manages
/// its own move/resize and reports frame changes back via `onFrameChanged`.
/// Small round close affordance that fades in only while the pointer is over a window.
/// Headerless windows have no persistent chrome, so this is the only mouse close target.
/// Pure visual: it never intercepts events — the parent window hit-tests the chip region
/// itself (more robust than dispatching mouseDown to a nested subview through the overlay's
/// custom hitTest), so this returns nil from hitTest.
private final class PinttyCloseChip: NSView {
    private let glyph = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PinttyColors.terminalCloseButton.cgColor
        layer?.cornerRadius = frameRect.width / 2
        glyph.string = "\u{00D7}"          // ×
        glyph.fontSize = 13
        glyph.foregroundColor = NSColor.white.cgColor
        glyph.alignmentMode = .center
        glyph.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(glyph)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        let gh: CGFloat = 15
        glyph.frame = CGRect(x: 0, y: (bounds.height - gh) / 2 - 1, width: bounds.width, height: gh)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PinttyTerminalWindow: NSView {
    static let resizeHandle: CGFloat = 16
    static let minSize = CGSize(width: 220, height: 120)
    static let chipSize: CGFloat = 18
    static let chipInset: CGFloat = 7

    let id: String
    let surface: Ghostty.SurfaceView
    private let closeChip = PinttyCloseChip(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    private var hoverTracking: NSTrackingArea?

    var onFrameChanged: ((String, CGRect) -> Void)?
    var onClose: ((String) -> Void)?
    /// User started interacting with this window (raise/focus).
    var onFocus: ((String) -> Void)?
    /// Drag/resize finished; reports the final frame and whether it was a resize.
    var onCommit: ((String, CGRect, Bool) -> Void)?

    /// True while the user is actively moving/resizing, so sync won't fight the drag.
    private(set) var isDragging = false

    private enum DragKind { case move, resize }
    private var dragKind: DragKind?
    private var dragStart: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero

    init(id: String, surface: Ghostty.SurfaceView) {
        self.id = id
        self.surface = surface
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = PinttyColors.terminalWindowBg.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = PinttyColors.terminalWindowBorder.cgColor
        layer?.masksToBounds = true

        addSubview(surface)
        // Close chip sits above the surface so it stays visible on hover. It is purely
        // visual (hitTest returns nil); the close action is handled in this window's
        // mouseDown so the click lands reliably through the overlay's hit-testing.
        addSubview(closeChip)
    }

    required init?(coder: NSCoder) { nil }

    func setTitle(_ t: String) {}

    override func layout() {
        super.layout()
        layoutChrome()
    }

    /// Headerless: the live terminal surface fills the whole window (inset by the 1px rim).
    func layoutChrome() {
        let h = bounds.height
        let w = bounds.width
        surface.frame = CGRect(x: 1, y: 1, width: max(0, w - 2), height: max(0, h - 2))
        closeChip.frame = CGRect(
            x: w - Self.chipSize - Self.chipInset,
            y: h - Self.chipSize - Self.chipInset,
            width: Self.chipSize, height: Self.chipSize)
    }

    // MARK: - Hover (reveal close chip)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t)
        hoverTracking = t
    }

    override func mouseEntered(with event: NSEvent) { setChipVisible(true) }
    override func mouseExited(with event: NSEvent)  { setChipVisible(false) }

    private func setChipVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            closeChip.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)

        // Close chip (only while hovered/visible) — route to self so mouseDown handles it.
        if closeChip.alphaValue > 0.01 && closeChip.frame.contains(local) { return self }
        // Bottom-right resize handle.
        if local.x >= bounds.width - Self.resizeHandle && local.y <= Self.resizeHandle { return self }
        // Moving is handled by the overlay's Cmd-hold monitor (no header to grab); the
        // surface always gets normal clicks here.
        return surface.hitTest(local) ?? surface
    }

    // MARK: - Drag / resize

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Close chip click (only when revealed on hover).
        if closeChip.alphaValue > 0.01 && closeChip.frame.contains(local) {
            onClose?(id)
            return
        }
        if local.x >= bounds.width - Self.resizeHandle && local.y <= Self.resizeHandle {
            dragKind = .resize
        } else {
            dragKind = nil
            return
        }
        isDragging = true
        dragStart = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        dragStartFrame = frame
        // Bring to front within the overlay.
        if let sv = superview { sv.addSubview(self) }
        onFocus?(id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let kind = dragKind else { return }
        let p = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        let dx = p.x - dragStart.x
        let dy = p.y - dragStart.y

        var f = dragStartFrame
        switch kind {
        case .move:
            f.origin.x += dx
            f.origin.y += dy
        case .resize:
            // Resize from bottom-right; keep top-left anchored.
            f.size.width = max(Self.minSize.width, dragStartFrame.width + dx)
            let newH = max(Self.minSize.height, dragStartFrame.height - dy)
            f.origin.y = dragStartFrame.maxY - newH
            f.size.height = newH
        }
        frame = f
        layoutChrome()
        onFrameChanged?(id, f)
    }

    override func mouseUp(with event: NSEvent) {
        if let kind = dragKind {
            onCommit?(id, frame, kind == .resize)
        }
        dragKind = nil
        isDragging = false
    }
}

/// Controller-driven pointer rendered above the canvas: a glowing arrow with an optional
/// label and a click ripple. Its anchor is the arrow tip, so `position` is the target point.
final class PinttyCursorLayer: CALayer {
    private static let height: CGFloat = 22
    private static let neon = PinttyColors.cursorColor.cgColor

    private let pointer = CAShapeLayer()
    private let labelLayer = CATextLayer()

    override init() {
        super.init()
        anchorPoint = CGPoint(x: 0, y: 1)   // top-left corner = arrow tip
        bounds = CGRect(x: 0, y: 0, width: Self.height, height: Self.height)

        // Arrow tip at the layer's top-left, pointing up-left (y-up coords).
        let path = CGMutablePath()
        let h = Self.height
        path.move(to: CGPoint(x: 0, y: h))       // tip
        path.addLine(to: CGPoint(x: 0, y: h - 16))
        path.addLine(to: CGPoint(x: 5, y: h - 12))
        path.addLine(to: CGPoint(x: 12, y: h - 13))
        path.closeSubpath()
        pointer.path = path
        pointer.fillColor = Self.neon
        pointer.strokeColor = PinttyColors.cursorStroke.cgColor
        pointer.lineWidth = 0.75
        pointer.shadowColor = Self.neon
        pointer.shadowRadius = 6
        pointer.shadowOpacity = 0.9
        pointer.shadowOffset = .zero
        addSublayer(pointer)

        labelLayer.fontSize = 11
        labelLayer.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        labelLayer.foregroundColor = Self.neon
        labelLayer.alignmentMode = .left
        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        labelLayer.shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        labelLayer.shadowRadius = 2
        labelLayer.shadowOpacity = 0.8
        labelLayer.shadowOffset = .zero
        addSublayer(labelLayer)
    }

    required init?(coder: NSCoder) { nil }
    override init(layer: Any) { super.init(layer: layer) }

    func setLabel(_ text: String) {
        labelLayer.isHidden = text.isEmpty
        labelLayer.string = text
        let labelW: CGFloat = text.isEmpty ? 0 : ceil(
            (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        ) + 8
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep the tip anchored (anchorPoint 0,1) as width grows for the label.
        bounds = CGRect(x: 0, y: 0, width: Self.height + labelW, height: Self.height)
        labelLayer.frame = CGRect(x: 16, y: Self.height - 17, width: labelW, height: 14)
        CATransaction.commit()
    }

    /// One-shot ripple at the tip to signal a controller "click".
    func pulse() {
        let ring = CAShapeLayer()
        let r: CGFloat = 16
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: Self.height - r, width: 2 * r, height: 2 * r), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Self.neon
        ring.lineWidth = 2
        addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.2
        scale.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }
    }
}

/// A directed dataflow wire drawn behind panels: a dim glow base line with a marching-ants
/// flow overlay, an optional centered label, and a one-shot "packet" that travels source→dest
/// on pulse. Endpoints (`fromId`/`toId`) are re-resolved to live frames by the overlay view.
final class PinttyWireLayer: CAShapeLayer {
    static let neon = PinttyColors.accent.cgColor

    var fromId: String = ""
    var toId: String = ""

    private let flow = CAShapeLayer()        // dashed marching-ants overlay
    private let labelLayer = CATextLayer()
    private var labelText = ""
    private var currentPath: CGPath?

    override init() {
        super.init()
        masksToBounds = false
        fillColor = nil
        lineWidth = 2
        lineCap = .round
        strokeColor = Self.neon
        shadowColor = Self.neon
        shadowRadius = 5
        shadowOpacity = 0.8
        shadowOffset = .zero
        opacity = 0.5                        // dim base; the flow overlay reads as the "live" line

        flow.fillColor = nil
        flow.lineWidth = 2
        flow.lineCap = .round
        flow.strokeColor = Self.neon
        flow.lineDashPattern = [4, 10]
        addSublayer(flow)

        labelLayer.fontSize = 10
        labelLayer.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        labelLayer.foregroundColor = Self.neon
        labelLayer.alignmentMode = .center
        labelLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        labelLayer.shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        labelLayer.shadowRadius = 2
        labelLayer.shadowOpacity = 0.9
        labelLayer.shadowOffset = .zero
        addSublayer(labelLayer)

        let dash = CABasicAnimation(keyPath: "lineDashPhase")
        dash.fromValue = 14                  // pattern total (4 + 10): one full cycle
        dash.toValue = 0
        dash.duration = 0.7
        dash.repeatCount = .infinity
        flow.add(dash, forKey: "flow")
    }

    required init?(coder: NSCoder) { nil }
    override init(layer: Any) { super.init(layer: layer) }

    func configure(color: CGColor, label: String) {
        strokeColor = color
        shadowColor = color
        flow.strokeColor = color
        labelLayer.foregroundColor = color
        labelText = label
        labelLayer.isHidden = label.isEmpty
        labelLayer.string = label
    }

    /// Build a horizontal-tangent cubic bezier (node-editor style) between the two anchors.
    func setPath(from start: CGPoint, to end: CGPoint) {
        let dir: CGFloat = end.x >= start.x ? 1 : -1
        let cOff = max(40, abs(end.x - start.x) * 0.5)
        let p = CGMutablePath()
        p.move(to: start)
        p.addCurve(
            to: end,
            control1: CGPoint(x: start.x + dir * cOff, y: start.y),
            control2: CGPoint(x: end.x - dir * cOff, y: end.y)
        )
        path = p
        flow.path = p
        currentPath = p

        if !labelText.isEmpty {
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let w = ceil(
                (labelText as NSString).size(
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
                ).width
            ) + 8
            labelLayer.frame = CGRect(x: mid.x - w / 2, y: mid.y + 4, width: w, height: 13)
        }
    }

    /// Send a glowing packet travelling source→dest along the wire.
    func pulse(intensity: CGFloat) {
        guard let p = currentPath else { return }
        let dot = CAShapeLayer()
        let r: CGFloat = 4
        dot.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        dot.fillColor = strokeColor
        dot.shadowColor = strokeColor
        dot.shadowRadius = 6
        dot.shadowOpacity = 1.0
        dot.shadowOffset = .zero
        addSublayer(dot)

        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = p
        move.calculationMode = .paced
        move.duration = 0.8
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(move, forKey: "packet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { dot.removeFromSuperlayer() }
    }
}

// MARK: - Cheat sheet

/// A centered, frosted info card listing every canvas keybind. Toggled with Cmd+/
/// (dismissed with Esc). Purely informational — it has no interactive controls.
final class PinttyCheatSheet: NSView {
    private static let rows: [(String, String)] = [
        ("⌘T",        "New shell under cursor"),
        ("⌘W",        "Close shell under cursor"),
        ("⌘ + / − / 0", "Zoom shell text / reset"),
        ("⌘⇧P",       "Show / hide all panels"),
        ("⌘⇧. / ⌘⇧,",  "Cycle z-layer fwd / back"),
        ("⌘-drag",    "Move window under pointer"),
        ("⌃-drag",    "Resize window under pointer"),
        ("drag corner", "Resize from bottom-right"),
        ("⌘/  ·  esc", "Toggle this sheet / close"),
    ]

    private static let cardWidth:  CGFloat = 392
    private static let pad:        CGFloat = 22
    private static let titleH:     CGFloat = 24
    private static let rowH:       CGFloat = 28
    private static let gap:        CGFloat = 12
    private static let keyColW:    CGFloat = 124

    override var isFlipped: Bool { true }

    init() {
        let h = Self.pad * 2 + Self.titleH + Self.gap + CGFloat(Self.rows.count) * Self.rowH
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: h))
        wantsLayer = true
        layer?.backgroundColor = PinttyColors.panelBg.cgColor
        layer?.borderColor = PinttyColors.panelBorderFocus.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 14
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        let title = label("Canvas Keybinds", size: 15, weight: .semibold,
                          color: PinttyColors.titleColor)
        title.frame = NSRect(x: Self.pad, y: Self.pad,
                             width: Self.cardWidth - Self.pad * 2, height: Self.titleH)
        addSubview(title)

        var y = Self.pad + Self.titleH + Self.gap
        for (key, desc) in Self.rows {
            let chip = label(key, size: 12, weight: .medium, color: PinttyColors.accent,
                            mono: true)
            chip.frame = NSRect(x: Self.pad, y: y + 4, width: Self.keyColW, height: Self.rowH - 8)
            addSubview(chip)

            let d = label(desc, size: 12.5, weight: .regular, color: PinttyColors.contentText)
            d.frame = NSRect(x: Self.pad + Self.keyColW + 8, y: y + 4,
                             width: Self.cardWidth - Self.pad * 2 - Self.keyColW - 8,
                             height: Self.rowH - 8)
            addSubview(d)
            y += Self.rowH
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor, mono: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.backgroundColor = .clear
        f.isBordered = false
        f.drawsBackground = false
        return f
    }

    // Informational only — let clicks fall through to the canvas behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
