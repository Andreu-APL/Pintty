const std = @import("std");
const Protocol = @import("Protocol.zig");

pub const Panel = struct {
    id: []const u8,
    x_pct: f32,
    y_pct: f32,
    w_pct: f32,
    h_pct: f32,
    title: []const u8,
    content_type: []const u8,
    visible: bool = true,
    focused: bool = false,
    content_json: ?[]const u8 = null,
    // Net scroll delta (in lines) accumulated since last snapshot; reset on read.
    scroll_delta: f32 = 0.0,
    // Z-plane this panel lives on. Distance from the active layer drives ambient depth.
    layer: i32 = 0,
};

// A directed dataflow link drawn between two panels/windows. Endpoints track the
// live frames of from_id → to_id; `pulse` is a one-shot packet animation trigger,
// consumed when the snapshot is read.
pub const Wire = struct {
    id: []const u8,
    from_id: []const u8,
    to_id: []const u8,
    label: ?[]const u8 = null,
    color: u32 = 0, // 0 = default neon; else packed 0xRRGGBB
    pulse: f32 = 0.0, // one-shot pulse intensity; reset on snapshot read
    active: bool = true,
};

pub const OverlayState = struct {
    allocator: std.mem.Allocator,
    panels: std.ArrayList(Panel),
    wires: std.ArrayList(Wire) = .empty,
    mutex: std.Thread.Mutex = .{},
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // The z-plane currently in focus; non-active layers recede (dim/blur/scale).
    active_layer: i32 = 0,

    // Remote cursor: a controller-driven pointer rendered above all panels.
    cursor_x_pct: f32 = 0.5,
    cursor_y_pct: f32 = 0.5,
    cursor_visible: bool = false,
    cursor_label: ?[]const u8 = null,
    // One-shot click pulse; set by a `cursor` command, consumed on the next snapshot.
    cursor_click: bool = false,

    // Outbound event broadcast: the write-streams of every connected client. User-driven
    // canvas changes (close/move/resize/focus/layer) are pushed here so the controller stays
    // in sync. Guarded by its own mutex, independent of the snapshot mutex.
    clients: std.ArrayList(std.net.Stream) = .empty,
    clients_mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator) OverlayState {
        var state: OverlayState = .{
            .allocator = alloc,
            .panels = .empty,
        };
        state.seedDefaultTerminal();
        return state;
    }

    /// Canvas-terminal default: spawn one centered shell window on launch so the
    /// canvas isn't blank. Id "main" is suppressed from respawn once closed locally.
    fn seedDefaultTerminal(self: *OverlayState) void {
        const id = self.allocator.dupe(u8, "main") catch return;
        const title = self.allocator.dupe(u8, "shell") catch {
            self.allocator.free(id);
            return;
        };
        const ct = self.allocator.dupe(u8, "terminal") catch {
            self.allocator.free(id);
            self.allocator.free(title);
            return;
        };
        self.panels.append(self.allocator, .{
            .id = id,
            .title = title,
            .content_type = ct,
            .x_pct = 0.28,
            .y_pct = 0.20,
            .w_pct = 0.44,
            .h_pct = 0.58,
            .focused = true,
        }) catch {
            self.allocator.free(id);
            self.allocator.free(title);
            self.allocator.free(ct);
        };
    }

    /// Append a live terminal window at the given position. Used by the app's own UI
    /// (e.g. a new-window keybind) to add a shell to the canvas; the next snapshot picks
    /// it up and spawns the SurfaceView. Id must be unique (caller-generated).
    pub fn spawnTerminal(self: *OverlayState, id: []const u8, x_pct: f32, y_pct: f32, w_pct: f32, h_pct: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id_dup = self.allocator.dupe(u8, id) catch return;
        const title = self.allocator.dupe(u8, "shell") catch {
            self.allocator.free(id_dup);
            return;
        };
        const ct = self.allocator.dupe(u8, "terminal") catch {
            self.allocator.free(id_dup);
            self.allocator.free(title);
            return;
        };
        self.panels.append(self.allocator, .{
            .id = id_dup,
            .title = title,
            .content_type = ct,
            .x_pct = x_pct,
            .y_pct = y_pct,
            .w_pct = w_pct,
            .h_pct = h_pct,
            .focused = true,
        }) catch {
            self.allocator.free(id_dup);
            self.allocator.free(title);
            self.allocator.free(ct);
            return;
        };
        self.dirty.store(true, .release);
    }

    /// Remove a panel/window by id (frees its strings). Used by the app's own UI when the
    /// user closes a window, so it leaves the backend state instead of lingering as a zombie.
    pub fn despawnById(self: *OverlayState, id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.panels.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, id)) {
                const panel = self.panels.swapRemove(i);
                self.allocator.free(panel.id);
                self.allocator.free(panel.title);
                self.allocator.free(panel.content_type);
                if (panel.content_json) |cj| self.allocator.free(cj);
                self.dirty.store(true, .release);
                return;
            }
        }
    }

    pub fn deinit(self: *OverlayState) void {
        self.panels.deinit(self.allocator);
        for (self.wires.items) |w| self.freeWire(w);
        self.wires.deinit(self.allocator);
        if (self.cursor_label) |l| self.allocator.free(l);
        self.clients.deinit(self.allocator);
    }

    pub fn freeWire(self: *OverlayState, w: Wire) void {
        self.allocator.free(w.id);
        self.allocator.free(w.from_id);
        self.allocator.free(w.to_id);
        if (w.label) |l| self.allocator.free(l);
    }

    pub fn registerClient(self: *OverlayState, stream: std.net.Stream) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        self.clients.append(self.allocator, stream) catch {};
    }

    pub fn unregisterClient(self: *OverlayState, stream: std.net.Stream) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items, 0..) |c, i| {
            if (c.handle == stream.handle) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
    }

    pub fn emitEvent(self: *OverlayState, json: []const u8) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items) |c| {
            c.writeAll(json) catch {};
            c.writeAll("\n") catch {};
        }
    }

    pub fn applyJson(self: *OverlayState, json_str: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try Protocol.dispatch(self, json_str);
        self.dirty.store(true, .release);
    }

    pub fn consumeDirty(self: *OverlayState) bool {
        return self.dirty.swap(false, .acq_rel);
    }
};

pub const PanelSnapshot = extern struct {
    x_pct: f32,
    y_pct: f32,
    w_pct: f32,
    h_pct: f32,
    visible: u8,        // 1 = visible, 0 = hidden
    focused: u8,        // 1 = focused (on top), 0 = unfocused
    title: [128]u8,
    title_len: usize,
    id: [64]u8,
    id_len: usize,
    scroll_delta: f32,  // net lines scrolled since last snapshot; consumed on read
    content_type: [32]u8,
    content_type_len: usize,
    content: [2048]u8,
    content_len: usize,
    layer: i32,
};

export fn pintty_overlay_consume_dirty(state: *OverlayState) bool {
    return state.consumeDirty();
}

export fn pintty_overlay_panel_count(state: *OverlayState) usize {
    return state.panels.items.len;
}

export fn pintty_overlay_snapshot(
    state: *OverlayState,
    buf: [*]PanelSnapshot,
    buf_count: usize,
) usize {
    state.mutex.lock();
    defer state.mutex.unlock();
    const count = @min(state.panels.items.len, buf_count);
    for (state.panels.items[0..count], 0..) |*p, i| {
        buf[i].x_pct = p.x_pct;
        buf[i].y_pct = p.y_pct;
        buf[i].w_pct = p.w_pct;
        buf[i].h_pct = p.h_pct;
        buf[i].visible = if (p.visible) 1 else 0;
        buf[i].focused = if (p.focused) 1 else 0;
        const title_len = @min(p.title.len, 127);
        @memcpy(buf[i].title[0..title_len], p.title[0..title_len]);
        buf[i].title[title_len] = 0;
        buf[i].title_len = title_len;
        const id_len = @min(p.id.len, 63);
        @memcpy(buf[i].id[0..id_len], p.id[0..id_len]);
        buf[i].id[id_len] = 0;
        buf[i].id_len = id_len;
        // scroll_delta is consumed: hand it off and reset.
        buf[i].scroll_delta = p.scroll_delta;
        p.scroll_delta = 0;
        const ct_len = @min(p.content_type.len, 31);
        @memcpy(buf[i].content_type[0..ct_len], p.content_type[0..ct_len]);
        buf[i].content_type[ct_len] = 0;
        buf[i].content_type_len = ct_len;
        const content = if (p.content_json) |c| c else "";
        const c_len = @min(content.len, 2047);
        @memcpy(buf[i].content[0..c_len], content[0..c_len]);
        buf[i].content[c_len] = 0;
        buf[i].content_len = c_len;
        buf[i].layer = p.layer;
    }
    return count;
}

export fn pintty_overlay_active_layer(state: *OverlayState) i32 {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.active_layer;
}

pub const CursorSnapshot = extern struct {
    x_pct: f32,
    y_pct: f32,
    visible: u8, // 1 = shown, 0 = hidden
    click: u8,   // one-shot click pulse; consumed on read
    label: [64]u8,
    label_len: usize,
};

export fn pintty_overlay_cursor(state: *OverlayState, out: *CursorSnapshot) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    out.x_pct = state.cursor_x_pct;
    out.y_pct = state.cursor_y_pct;
    out.visible = if (state.cursor_visible) 1 else 0;
    out.click = if (state.cursor_click) 1 else 0;
    state.cursor_click = false;
    const label = state.cursor_label orelse "";
    const n = @min(label.len, 63);
    @memcpy(out.label[0..n], label[0..n]);
    out.label[n] = 0;
    out.label_len = n;
}

export fn pintty_overlay_emit_event(state: *OverlayState, ptr: [*]const u8, len: usize) void {
    state.emitEvent(ptr[0..len]);
}

export fn pintty_overlay_spawn_terminal(
    state: *OverlayState,
    id_ptr: [*]const u8,
    id_len: usize,
    x_pct: f32,
    y_pct: f32,
    w_pct: f32,
    h_pct: f32,
) void {
    state.spawnTerminal(id_ptr[0..id_len], x_pct, y_pct, w_pct, h_pct);
}

export fn pintty_overlay_despawn(state: *OverlayState, id_ptr: [*]const u8, id_len: usize) void {
    state.despawnById(id_ptr[0..id_len]);
}

pub const WireSnapshot = extern struct {
    id: [64]u8,
    id_len: usize,
    from_id: [64]u8,
    from_len: usize,
    to_id: [64]u8,
    to_len: usize,
    label: [64]u8,
    label_len: usize,
    color: u32,        // 0 = default neon; else packed 0xRRGGBB
    pulse: f32,        // one-shot pulse intensity; consumed on read
    active: u8,        // 1 = drawn, 0 = hidden
};

export fn pintty_overlay_wire_count(state: *OverlayState) usize {
    return state.wires.items.len;
}

export fn pintty_overlay_wires(
    state: *OverlayState,
    buf: [*]WireSnapshot,
    buf_count: usize,
) usize {
    state.mutex.lock();
    defer state.mutex.unlock();
    const count = @min(state.wires.items.len, buf_count);
    for (state.wires.items[0..count], 0..) |*w, i| {
        const id_len = @min(w.id.len, 63);
        @memcpy(buf[i].id[0..id_len], w.id[0..id_len]);
        buf[i].id[id_len] = 0;
        buf[i].id_len = id_len;
        const from_len = @min(w.from_id.len, 63);
        @memcpy(buf[i].from_id[0..from_len], w.from_id[0..from_len]);
        buf[i].from_id[from_len] = 0;
        buf[i].from_len = from_len;
        const to_len = @min(w.to_id.len, 63);
        @memcpy(buf[i].to_id[0..to_len], w.to_id[0..to_len]);
        buf[i].to_id[to_len] = 0;
        buf[i].to_len = to_len;
        const label = w.label orelse "";
        const l_len = @min(label.len, 63);
        @memcpy(buf[i].label[0..l_len], label[0..l_len]);
        buf[i].label[l_len] = 0;
        buf[i].label_len = l_len;
        buf[i].color = w.color;
        // pulse is consumed: hand it off and reset.
        buf[i].pulse = w.pulse;
        w.pulse = 0;
        buf[i].active = if (w.active) 1 else 0;
    }
    return count;
}
