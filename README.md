# Pintty

A spatial terminal workspace, built as a fork of [Ghostty](https://ghostty.org).

Pintty keeps everything that makes Ghostty fast and native, and adds a **canvas mode**:
an infinite, pannable/zoomable surface where terminal panes live as movable, resizable
frosted-glass windows instead of rigid tiles. Think of your terminals as objects on a
desk rather than cells in a grid.

## What Pintty adds over Ghostty

- **Canvas mode** — terminals become free-floating panels on an infinite canvas.
- **Pan & zoom** — `⌘-drag` to pan, `⌘+` / `⌘-` / `⌘0` to zoom, `⌃-drag` to move a panel.
- **Spawn & close** — `⌘T` spawns a new panel on the canvas; hover a panel to reveal its close chip (`⌘W` also closes the focused one).
- **Frosted-glass aesthetic** — translucent panels with a configurable accent and blur.
- **Keybind cheat-sheet** — `⌘/` toggles an on-canvas reference card.

## Keybinds

| Key | Action |
|-----|--------|
| `⌘T` | Spawn a new panel |
| `⌘W` | Close focused panel |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / reset |
| `⌘⇧P` | Toggle canvas mode |
| `⌘-drag` | Pan the canvas |
| `⌃-drag` | Move a panel |
| drag corner | Resize a panel |
| `⌘/` · `esc` | Toggle / dismiss the cheat-sheet |

## Configuration

Canvas behavior is read from `~/.config/pintty/config.json`:

```json
{
  "canvas": true,
  "glassOpacity": 0.18,
  "accent": "#6B8FBC"
}
```

All standard Ghostty configuration (`~/.config/ghostty/config`) continues to apply.

## Building (macOS)

Pintty builds with the same toolchain as Ghostty. With Zig 0.15 installed:

```sh
zig build
codesign --force --deep --sign - zig-out/Pintty.app
open zig-out/Pintty.app
```

Build prerequisites and project layout follow upstream
[Ghostty](https://github.com/ghostty-org/ghostty).

## License & attribution

Pintty is released under the [MIT License](LICENSE), the same license as Ghostty.
It is a derivative work of Ghostty by Mitchell Hashimoto and the Ghostty contributors —
all upstream copyright is retained. Pintty is not affiliated with or endorsed by the
Ghostty project.
