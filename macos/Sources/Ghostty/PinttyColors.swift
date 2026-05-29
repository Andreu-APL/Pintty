import AppKit

// =============================================================================
//  PINTTY THEME — single source of truth for the overlay's look.
//
//  Everything visual (panel fill, borders, text, accent, terminal-window chrome,
//  remote cursor, wires, gauges) reads from the values below. Edit here and the
//  whole canvas re-themes — no other file needs touching.
//
//  NOTE: all colors MUST use displayP3Red: — Ghostty composites in Display P3.
//  Plain sRGB NSColor(red:green:blue:alpha:) initializers come out desaturated.
//
//  Current theme: FROSTED WHITE — translucent white glass over the blurred
//  terminal, cool steel accent, dark slate text.
// =============================================================================
/// Canvas-mode master switch. When enabled, the app opens AS the spatial canvas:
/// the base terminal surface is hidden (only the window's own frosted glass shows
/// through) and the overlay paints a faint glass film + auto-spawns a centered shell.
/// Read by both PinttyOverlayView (AppKit `canvasMode`) and TerminalView (SwiftUI).
enum PinttyCanvas {
    static var enabled: Bool { PinttyConfig.shared.canvas }
}

enum PinttyColors {

    // MARK: - Canvas

    /// The canvas is transparent liquid glass: the window's own translucency
    /// (background-opacity + background-blur in Ghostty config) shows the frosted
    /// desktop behind the floating windows. This is just a faint cool film layered
    /// on top of that glass — raise alpha for a more pronounced tint, or use .clear.
    static let canvasBackdrop = NSColor(displayP3Red: 0.60, green: 0.70, blue: 0.85, alpha: 0.06)

    // MARK: - Panels (floating content windows)

    /// Translucent white fill. The Gaussian blur behind it (see `panelBlurRadius`)
    /// turns this into frosted glass. Raise alpha for a more opaque/whiter pane.
    static let panelBg          = NSColor(displayP3Red: 0.93, green: 0.95, blue: 0.99, alpha: 0.45)
    /// Resting frosty rim.
    static let panelBorderDim   = NSColor(displayP3Red: 1.00, green: 1.00, blue: 1.00, alpha: 0.35)
    /// Brighter rim when the panel is focused.
    static let panelBorderFocus = NSColor(displayP3Red: 1.00, green: 1.00, blue: 1.00, alpha: 0.85)
    /// Title-bar text — dark so it reads on the light frost.
    static let titleColor       = NSColor(displayP3Red: 0.10, green: 0.12, blue: 0.16, alpha: 0.95)
    /// Body text — dark slate.
    static let contentText      = NSColor(displayP3Red: 0.14, green: 0.16, blue: 0.20, alpha: 0.92)
    static let scrollIndicator  = NSColor(displayP3Red: 0.20, green: 0.24, blue: 0.30, alpha: 0.40)
    static let resizeGrip       = NSColor(displayP3Red: 0.20, green: 0.24, blue: 0.30, alpha: 0.50)

    /// Frosted-glass blur strength behind panels. If the config already sets
    /// background-blur, this stacks a little extra. Higher = frostier/softer.
    static let panelBlurRadius: CGFloat = 8

    /// Opacity of the always-on glass backdrop (PinttyGlassBackdrop) in canvas mode.
    /// The backdrop is a vibrancy view that frosts the desktop behind it; lowering
    /// this lets the window's own raw transparency show the crisp wallpaper through.
    /// 1.0 = full frosted glass, 0.0 = no frost (wallpaper fully visible).
    /// Configurable via `glassOpacity` in ~/.config/pintty/config.json.
    static var canvasGlassOpacity: CGFloat { PinttyConfig.shared.glassOpacity }

    // MARK: - Accent (gauges, wires, remote cursor — the "live" highlights)

    /// Cool steel-ice accent. Deliberately NOT neon cyan — pastel/cold to match frost.
    /// Configurable via `accent` (hex string, e.g. "#6B8FBC") in the Pintty config.
    static var accent: NSColor { PinttyConfig.shared.accent }
    /// Faded accent for tracks / inactive lines.
    static var accentDim: NSColor { accent.withAlphaComponent(0.35) }

    // MARK: - Ambient status (per-panel rim glow)

    /// Rim color for a panel's ambient status. `active` reuses the theme accent so
    /// "working" reads as a breathing version of the normal highlight; alert/ok are
    /// vivid red/green for at-a-glance state. `idle` returns nil (no status ring).
    static func statusColor(_ code: Int) -> NSColor? {
        switch code {
        case 1:  return accent
        case 2:  return NSColor(displayP3Red: 1.000, green: 0.231, blue: 0.235, alpha: 1)
        case 3:  return NSColor(displayP3Red: 0.000, green: 0.851, blue: 0.451, alpha: 1)
        default: return nil
        }
    }

    // MARK: - Terminal windows (live PTY surfaces with chrome)

    static let terminalWindowBg     = NSColor(displayP3Red: 0.90, green: 0.93, blue: 0.98, alpha: 0.40)
    static let terminalWindowBorder = NSColor(displayP3Red: 1.00, green: 1.00, blue: 1.00, alpha: 0.40)
    static let terminalTitleBar     = NSColor(displayP3Red: 0.92, green: 0.94, blue: 0.99, alpha: 0.55)
    static let terminalTitleText    = NSColor(displayP3Red: 0.12, green: 0.14, blue: 0.18, alpha: 1.00)
    static let terminalCloseButton  = NSColor(displayP3Red: 0.93, green: 0.34, blue: 0.31, alpha: 1.00)

    // MARK: - Remote (agent) cursor

    static var cursorColor: NSColor { accent }
    static let cursorStroke = NSColor(displayP3Red: 1.00, green: 1.00, blue: 1.00, alpha: 0.90)

    // MARK: - Geo dots (map markers)

    /// Fallback color for a geo point that doesn't specify its own.
    static var geoDefault: NSColor { accent }

    /// Semantic colors for geo-event categories (kept vivid for at-a-glance distinction).
    static func geoColor(_ kind: String) -> NSColor {
        switch kind {
        case "seismic":   return NSColor(displayP3Red: 1.000, green: 0.902, blue: 0.000, alpha: 1)
        case "conflict":  return NSColor(displayP3Red: 1.000, green: 0.157, blue: 0.235, alpha: 1)
        case "aviation":  return NSColor(displayP3Red: 0.000, green: 0.824, blue: 1.000, alpha: 1)
        case "satellite": return NSColor(displayP3Red: 0.784, green: 0.000, blue: 1.000, alpha: 1)
        case "cable":     return NSColor(displayP3Red: 0.000, green: 0.510, blue: 1.000, alpha: 1)
        default:          return NSColor(displayP3Red: 0.000, green: 1.000, blue: 0.471, alpha: 1)
        }
    }
}

// =============================================================================
//  PINTTY CONFIG — user-editable settings, separate from Ghostty's own config.
//
//  Read once at first access from ~/.config/pintty/config.json. Every key is
//  optional; anything missing falls back to the shipped defaults below, so the
//  app runs identically with no config file present.
//
//  Example config.json:
//    {
//      "canvas": true,           // spatial canvas mode on/off
//      "glassOpacity": 0.18,     // 0.0 = wallpaper crisp … 1.0 = full frost
//      "accent": "#6B8FBC"       // highlight color (gauges, wires, cursor)
//    }
// =============================================================================
final class PinttyConfig {
    static let shared = PinttyConfig()

    let canvas: Bool
    let glassOpacity: CGFloat
    let accent: NSColor

    /// Resolved path of the config file (whether or not it exists).
    static let path = (("~/.config/pintty/config.json") as NSString).expandingTildeInPath

    private init() {
        let defCanvas = true
        let defGlass: CGFloat = 0.18
        let defAccent = NSColor(displayP3Red: 0.42, green: 0.56, blue: 0.74, alpha: 1.00)

        guard let data = FileManager.default.contents(atPath: PinttyConfig.path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            canvas = defCanvas; glassOpacity = defGlass; accent = defAccent
            return
        }
        canvas = (obj["canvas"] as? Bool) ?? defCanvas
        glassOpacity = (obj["glassOpacity"] as? NSNumber).map { CGFloat(truncating: $0) } ?? defGlass
        accent = (obj["accent"] as? String).flatMap(PinttyConfig.parseHex) ?? defAccent
    }

    /// "#RRGGBB" or "RRGGBB" → Display-P3 NSColor; nil on malformed input.
    private static func parseHex(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return NSColor(displayP3Red: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green:        CGFloat((v >>  8) & 0xFF) / 255.0,
                       blue:         CGFloat( v        & 0xFF) / 255.0,
                       alpha: 1.0)
    }
}
