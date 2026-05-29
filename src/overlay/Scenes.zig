const std = @import("std");
const OverlayState = @import("OverlayState.zig");

const log = std.log.scoped(.overlay_scenes);

// On-disk shape: one file per scene at ~/.pintty/scenes/<name>.json. A scene captures the full
// canvas arrangement (panels + wires + active layer) so it can be recalled verbatim later.

const SerPanel = struct {
    id: []const u8,
    x_pct: f32,
    y_pct: f32,
    w_pct: f32,
    h_pct: f32,
    title: []const u8,
    content_type: []const u8,
    visible: bool,
    layer: i32,
    content: ?[]const u8,
};

const SerWire = struct {
    id: []const u8,
    from: []const u8,
    to: []const u8,
    label: ?[]const u8,
    color: u32,
    active: bool,
};

const SerScene = struct {
    active_layer: i32,
    panels: []SerPanel,
    wires: []SerWire,
};

/// Scene names arrive over the socket, so reject anything that could escape the scenes dir.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn scenesDir(alloc: std.mem.Allocator) ?[]u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const dir = std.fmt.allocPrint(alloc, "{s}/.pintty/scenes", .{home}) catch return null;
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("makeDir scenes err={}", .{err});
            alloc.free(dir);
            return null;
        },
    };
    return dir;
}

fn scenePath(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const dir = scenesDir(alloc) orelse return null;
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ dir, name }) catch null;
}

/// Capture the current canvas into ~/.pintty/scenes/<name>.json. Caller holds state.mutex.
pub fn save(state: *OverlayState.OverlayState, name: []const u8) !void {
    if (!validName(name)) return error.InvalidSceneName;

    const alloc = state.allocator;
    var panels = try alloc.alloc(SerPanel, state.panels.items.len);
    defer alloc.free(panels);
    for (state.panels.items, 0..) |p, i| {
        panels[i] = .{
            .id = p.id,
            .x_pct = p.x_pct,
            .y_pct = p.y_pct,
            .w_pct = p.w_pct,
            .h_pct = p.h_pct,
            .title = p.title,
            .content_type = p.content_type,
            .visible = p.visible,
            .layer = p.layer,
            .content = p.content_json,
        };
    }
    var wires = try alloc.alloc(SerWire, state.wires.items.len);
    defer alloc.free(wires);
    for (state.wires.items, 0..) |w, i| {
        wires[i] = .{
            .id = w.id,
            .from = w.from_id,
            .to = w.to_id,
            .label = w.label,
            .color = w.color,
            .active = w.active,
        };
    }

    const scene = SerScene{
        .active_layer = state.active_layer,
        .panels = panels,
        .wires = wires,
    };

    const json = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(scene, .{})});
    defer alloc.free(json);

    const path = scenePath(alloc, name) orelse return error.NoScenesDir;
    defer alloc.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
    log.info("scene saved name={s} panels={d} wires={d}", .{ name, panels.len, wires.len });
}

fn clearPanels(state: *OverlayState.OverlayState) void {
    for (state.panels.items) |p| {
        state.allocator.free(p.id);
        state.allocator.free(p.title);
        state.allocator.free(p.content_type);
        if (p.content_json) |cj| state.allocator.free(cj);
    }
    state.panels.clearRetainingCapacity();
}

fn clearWires(state: *OverlayState.OverlayState) void {
    for (state.wires.items) |w| state.freeWire(w);
    state.wires.clearRetainingCapacity();
}

/// Replace the current canvas with the saved scene. Caller holds state.mutex.
pub fn load(state: *OverlayState.OverlayState, name: []const u8) !void {
    if (!validName(name)) return error.InvalidSceneName;

    const alloc = state.allocator;
    const path = scenePath(alloc, name) orelse return error.NoScenesDir;
    defer alloc.free(path);

    const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |err| {
        log.warn("scene load read err={} name={s}", .{ err, name });
        return err;
    };
    defer alloc.free(data);

    const parsed = try std.json.parseFromSlice(SerScene, alloc, data, .{});
    defer parsed.deinit();
    const scene = parsed.value;

    clearPanels(state);
    clearWires(state);

    for (scene.panels) |sp| {
        try state.panels.append(alloc, .{
            .id = try alloc.dupe(u8, sp.id),
            .title = try alloc.dupe(u8, sp.title),
            .content_type = try alloc.dupe(u8, sp.content_type),
            .x_pct = sp.x_pct,
            .y_pct = sp.y_pct,
            .w_pct = sp.w_pct,
            .h_pct = sp.h_pct,
            .visible = sp.visible,
            .layer = sp.layer,
            .content_json = if (sp.content) |c| try alloc.dupe(u8, c) else null,
        });
    }
    for (scene.wires) |sw| {
        try state.wires.append(alloc, .{
            .id = try alloc.dupe(u8, sw.id),
            .from_id = try alloc.dupe(u8, sw.from),
            .to_id = try alloc.dupe(u8, sw.to),
            .label = if (sw.label) |l| try alloc.dupe(u8, l) else null,
            .color = sw.color,
            .active = sw.active,
        });
    }
    state.active_layer = scene.active_layer;
    log.info("scene loaded name={s} panels={d} wires={d}", .{ name, scene.panels.len, scene.wires.len });
}

/// Emit a `{"event":"scene_list","scenes":[...]}` line to connected clients.
pub fn list(state: *OverlayState.OverlayState) void {
    const alloc = state.allocator;
    const dir_path = scenesDir(alloc) orelse return;
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"event\":\"scene_list\",\"scenes\":[") catch return;

    var it = dir.iterate();
    var first = true;
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        if (!first) buf.appendSlice(alloc, ",") catch return;
        first = false;
        // Names are validName-constrained (alnum/_/-), so no JSON escaping needed.
        buf.append(alloc, '"') catch return;
        buf.appendSlice(alloc, stem) catch return;
        buf.append(alloc, '"') catch return;
    }
    buf.appendSlice(alloc, "]}") catch return;
    state.emitEvent(buf.items);
}
