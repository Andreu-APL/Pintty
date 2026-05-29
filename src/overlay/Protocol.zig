const std = @import("std");
const OverlayState = @import("OverlayState.zig");
const Scenes = @import("Scenes.zig");

const log = std.log.scoped(.overlay_protocol);

pub fn dispatch(state: *OverlayState.OverlayState, json_str: []const u8) !void {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        state.allocator,
        json_str,
        .{},
    );
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const action = switch (obj.get("action") orelse return) {
        .string => |s| s,
        else => return,
    };

    log.debug("overlay action={s}", .{action});

    if (std.mem.eql(u8, action, "spawn")) {
        try doSpawn(state, obj);
    } else if (std.mem.eql(u8, action, "despawn")) {
        try doDespawn(state, obj);
    } else if (std.mem.eql(u8, action, "move")) {
        doMove(state, obj);
    } else if (std.mem.eql(u8, action, "resize")) {
        doResize(state, obj);
    } else if (std.mem.eql(u8, action, "focus")) {
        doFocus(state, obj);
    } else if (std.mem.eql(u8, action, "show")) {
        doSetVisible(state, obj, true);
    } else if (std.mem.eql(u8, action, "hide")) {
        doSetVisible(state, obj, false);
    } else if (std.mem.eql(u8, action, "text")) {
        try doText(state, obj);
    } else if (std.mem.eql(u8, action, "scroll")) {
        doScroll(state, obj);
    } else if (std.mem.eql(u8, action, "layout")) {
        doLayout(state, obj);
    } else if (std.mem.eql(u8, action, "image")) {
        try doImage(state, obj);
    } else if (std.mem.eql(u8, action, "geo_events")) {
        try doGeoEvents(state, obj);
    } else if (std.mem.eql(u8, action, "set_layer")) {
        doSetLayer(state, obj);
    } else if (std.mem.eql(u8, action, "active_layer")) {
        doActiveLayer(state, obj);
    } else if (std.mem.eql(u8, action, "cursor")) {
        try doCursor(state, obj);
    } else if (std.mem.eql(u8, action, "wire")) {
        try doWire(state, obj);
    } else if (std.mem.eql(u8, action, "unwire")) {
        doUnwire(state, obj);
    } else if (std.mem.eql(u8, action, "pulse")) {
        doPulse(state, obj);
    } else if (std.mem.eql(u8, action, "scene_save")) {
        if (getString(obj, "name")) |n| Scenes.save(state, n) catch |e| log.warn("scene_save err={}", .{e});
    } else if (std.mem.eql(u8, action, "scene_load")) {
        if (getString(obj, "name")) |n| Scenes.load(state, n) catch |e| log.warn("scene_load err={}", .{e});
    } else if (std.mem.eql(u8, action, "scene_list")) {
        Scenes.list(state);
    }
}

// --- helpers ---

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    return switch (obj.get(key) orelse return null) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i32 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (obj.get(key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn findIndex(state: *OverlayState.OverlayState, id: []const u8) ?usize {
    for (state.panels.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.id, id)) return i;
    }
    return null;
}

fn findWireIndex(state: *OverlayState.OverlayState, id: []const u8) ?usize {
    for (state.wires.items, 0..) |w, i| {
        if (std.mem.eql(u8, w.id, id)) return i;
    }
    return null;
}

// --- action handlers ---

fn doSpawn(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) !void {
    const id = getString(obj, "id") orelse return;
    const content_type = getString(obj, "content_type") orelse "text";
    const title = getString(obj, "title") orelse "";
    const x_pct = getFloat(obj, "x_pct") orelse 0.0;
    const y_pct = getFloat(obj, "y_pct") orelse 0.0;
    const w_pct = getFloat(obj, "w_pct") orelse 0.3;
    const h_pct = getFloat(obj, "h_pct") orelse 0.3;

    if (findIndex(state, id)) |idx| {
        // Upsert: update existing panel in place, free old strings.
        // Preserve the current layer unless the command explicitly sets one.
        const old = state.panels.items[idx];
        const layer = getInt(obj, "layer") orelse old.layer;
        state.allocator.free(old.id);
        state.allocator.free(old.title);
        state.allocator.free(old.content_type);
        if (old.content_json) |cj| state.allocator.free(cj);

        state.panels.items[idx] = .{
            .id = try state.allocator.dupe(u8, id),
            .title = try state.allocator.dupe(u8, title),
            .content_type = try state.allocator.dupe(u8, content_type),
            .x_pct = x_pct,
            .y_pct = y_pct,
            .w_pct = w_pct,
            .h_pct = h_pct,
            .layer = layer,
        };
    } else {
        try state.panels.append(state.allocator, .{
            .id = try state.allocator.dupe(u8, id),
            .title = try state.allocator.dupe(u8, title),
            .content_type = try state.allocator.dupe(u8, content_type),
            .x_pct = x_pct,
            .y_pct = y_pct,
            .w_pct = w_pct,
            .h_pct = h_pct,
            .layer = getInt(obj, "layer") orelse 0,
        });
    }
    log.info("spawn id={s} x={d:.2} y={d:.2} w={d:.2} h={d:.2}", .{ id, x_pct, y_pct, w_pct, h_pct });
}

fn doDespawn(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) !void {
    const id = getString(obj, "id") orelse return;
    const idx = findIndex(state, id) orelse return;
    const panel = state.panels.swapRemove(idx);
    state.allocator.free(panel.id);
    state.allocator.free(panel.title);
    state.allocator.free(panel.content_type);
    if (panel.content_json) |cj| state.allocator.free(cj);
    log.info("despawn id={s}", .{id});
}

fn doMove(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const id = getString(obj, "id") orelse return;
    const idx = findIndex(state, id) orelse return;
    if (getFloat(obj, "x_pct")) |v| state.panels.items[idx].x_pct = v;
    if (getFloat(obj, "y_pct")) |v| state.panels.items[idx].y_pct = v;
}

fn doResize(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const id = getString(obj, "id") orelse return;
    const idx = findIndex(state, id) orelse return;
    if (getFloat(obj, "w_pct")) |v| state.panels.items[idx].w_pct = v;
    if (getFloat(obj, "h_pct")) |v| state.panels.items[idx].h_pct = v;
}

fn doFocus(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const id = getString(obj, "id") orelse return;
    const idx = findIndex(state, id) orelse return;
    // Clear focused on all panels then set it on the target.
    for (state.panels.items) |*p| p.focused = false;
    var panel = state.panels.swapRemove(idx);
    panel.focused = true;
    state.panels.appendAssumeCapacity(panel);
}

fn doSetLayer(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const id = getString(obj, "id") orelse return;
    const layer = getInt(obj, "layer") orelse return;
    const idx = findIndex(state, id) orelse return;
    state.panels.items[idx].layer = layer;
    log.info("set_layer id={s} layer={d}", .{ id, layer });
}

fn doActiveLayer(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const layer = getInt(obj, "layer") orelse return;
    state.active_layer = layer;
    log.info("active_layer={d}", .{layer});
}

fn doCursor(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) !void {
    if (getFloat(obj, "x_pct")) |v| state.cursor_x_pct = v;
    if (getFloat(obj, "y_pct")) |v| state.cursor_y_pct = v;
    if (getBool(obj, "visible")) |b| state.cursor_visible = b;
    if (getBool(obj, "click")) |b| {
        if (b) state.cursor_click = true;
    }
    if (getString(obj, "label")) |s| {
        if (state.cursor_label) |old| state.allocator.free(old);
        state.cursor_label = try state.allocator.dupe(u8, s);
    }
    log.debug("cursor x={d:.2} y={d:.2} vis={}", .{ state.cursor_x_pct, state.cursor_y_pct, state.cursor_visible });
}

fn doWire(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) !void {
    const id = getString(obj, "id") orelse return;
    const from_id = getString(obj, "from") orelse return;
    const to_id = getString(obj, "to") orelse return;
    const color: u32 = if (getInt(obj, "color")) |c| @bitCast(c) else 0;

    if (findWireIndex(state, id)) |idx| {
        // Upsert: free old strings, preserve nothing (full replace).
        state.freeWire(state.wires.items[idx]);
        state.wires.items[idx] = .{
            .id = try state.allocator.dupe(u8, id),
            .from_id = try state.allocator.dupe(u8, from_id),
            .to_id = try state.allocator.dupe(u8, to_id),
            .label = if (getString(obj, "label")) |l| try state.allocator.dupe(u8, l) else null,
            .color = color,
            .active = getBool(obj, "active") orelse true,
        };
    } else {
        try state.wires.append(state.allocator, .{
            .id = try state.allocator.dupe(u8, id),
            .from_id = try state.allocator.dupe(u8, from_id),
            .to_id = try state.allocator.dupe(u8, to_id),
            .label = if (getString(obj, "label")) |l| try state.allocator.dupe(u8, l) else null,
            .color = color,
            .active = getBool(obj, "active") orelse true,
        });
    }
    log.info("wire id={s} from={s} to={s}", .{ id, from_id, to_id });
}

fn doUnwire(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const id = getString(obj, "id") orelse return;
    const idx = findWireIndex(state, id) orelse return;
    state.freeWire(state.wires.swapRemove(idx));
    log.info("unwire id={s}", .{id});
}

fn doPulse(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const id = getString(obj, "id") orelse return;
    const idx = findWireIndex(state, id) orelse return;
    state.wires.items[idx].pulse = getFloat(obj, "intensity") orelse 1.0;
    log.debug("pulse id={s}", .{id});
}

fn doSetVisible(state: *OverlayState.OverlayState, obj: std.json.ObjectMap, visible: bool) void {
    const id = getString(obj, "id") orelse return;
    const idx = findIndex(state, id) orelse return;
    state.panels.items[idx].visible = visible;
}

fn doText(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) !void {
    const id = getString(obj, "id") orelse return;
    const content = getString(obj, "content") orelse return;
    const idx = findIndex(state, id) orelse return;
    if (state.panels.items[idx].content_json) |old| state.allocator.free(old);
    state.panels.items[idx].content_json = try state.allocator.dupe(u8, content);
    log.debug("text id={s} len={d}", .{ id, content.len });
}

fn doScroll(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const id = getString(obj, "id") orelse return;
    const delta = getFloat(obj, "delta") orelse return;
    const idx = findIndex(state, id) orelse return;
    state.panels.items[idx].scroll_delta += delta;
    log.debug("scroll id={s} delta={d:.1}", .{ id, delta });
}

fn doGeoEvents(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) !void {
    const id = getString(obj, "id") orelse return;
    const events = getString(obj, "events") orelse return;
    const idx = findIndex(state, id) orelse return;
    if (state.panels.items[idx].content_json) |old| state.allocator.free(old);
    state.panels.items[idx].content_json = try state.allocator.dupe(u8, events);
    state.allocator.free(state.panels.items[idx].content_type);
    state.panels.items[idx].content_type = try state.allocator.dupe(u8, "geo");
    log.debug("geo_events id={s} events_len={d}", .{ id, events.len });
}

fn doImage(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) !void {
    const id = getString(obj, "id") orelse return;
    const idx = findIndex(state, id) orelse return;

    // Accept base64 "data" field (primary, sent over the overlay API) or legacy "path" field.
    // Store with a prefix so Swift knows which format to decode.
    const payload: []u8 = if (getString(obj, "data")) |d| blk: {
        var buf = try state.allocator.alloc(u8, 5 + d.len);
        @memcpy(buf[0..5], "data:");
        @memcpy(buf[5..], d);
        break :blk buf;
    } else if (getString(obj, "path")) |p| blk: {
        var buf = try state.allocator.alloc(u8, 5 + p.len);
        @memcpy(buf[0..5], "path:");
        @memcpy(buf[5..], p);
        break :blk buf;
    } else return;

    if (state.panels.items[idx].content_json) |old| state.allocator.free(old);
    state.panels.items[idx].content_json = payload;
    state.allocator.free(state.panels.items[idx].content_type);
    state.panels.items[idx].content_type = try state.allocator.dupe(u8, "image");
    log.debug("image id={s} format={s}", .{ id, payload[0..5] });
}

fn doLayout(state: *OverlayState.OverlayState, obj: std.json.ObjectMap) void {
    const layout = getString(obj, "layout") orelse return;

    if (std.mem.eql(u8, layout, "default")) {
        setPanelGeom(state, "chat", 0.00, 0.00, 0.55, 0.92, true);
        showNonChatPanels(state, true);
    } else if (std.mem.eql(u8, layout, "viz_focus")) {
        setPanelGeom(state, "chat", 0.00, 0.00, 0.28, 0.92, true);
        showNonChatPanels(state, true);
    } else if (std.mem.eql(u8, layout, "chat_focus")) {
        setPanelGeom(state, "chat", 0.10, 0.02, 0.80, 0.92, true);
        showNonChatPanels(state, false);
    } else if (std.mem.eql(u8, layout, "zen")) {
        setPanelGeom(state, "chat", 0.15, 0.02, 0.70, 0.92, true);
        showNonChatPanels(state, false);
    } else if (std.mem.eql(u8, layout, "split")) {
        setPanelGeom(state, "chat", 0.00, 0.00, 0.55, 0.92, true);
        setPanelGeom(state, "_map",  0.57, 0.02, 0.41, 0.92, true);
    }
    log.info("layout preset={s}", .{layout});
}

fn setPanelGeom(state: *OverlayState.OverlayState,
    id: []const u8, x: f32, y: f32, w: f32, h: f32, visible: bool) void
{
    const idx = findIndex(state, id) orelse return;
    state.panels.items[idx].x_pct   = x;
    state.panels.items[idx].y_pct   = y;
    state.panels.items[idx].w_pct   = w;
    state.panels.items[idx].h_pct   = h;
    state.panels.items[idx].visible = visible;
}

fn showNonChatPanels(state: *OverlayState.OverlayState, show: bool) void {
    for (state.panels.items) |*p| {
        if (!std.mem.eql(u8, p.id, "chat")) p.visible = show;
    }
}
