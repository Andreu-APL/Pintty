const std = @import("std");
const OverlayState = @import("OverlayState.zig");

const log = std.log.scoped(.overlay_ipc);

pub const IpcServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    state: *OverlayState.OverlayState,

    pub fn start(self: *IpcServer) !void {
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        const addr = try std.net.Address.initUnix(self.socket_path);
        const server = try addr.listen(.{ .reuse_address = true });
        const thread = try std.Thread.spawn(.{}, serve, .{ self.state, server });
        thread.detach();
        log.info("overlay IPC listening at {s}", .{self.socket_path});
    }

    fn serve(state: *OverlayState.OverlayState, server: std.net.Server) void {
        var s = server;
        defer s.deinit();
        while (true) {
            const conn = s.accept() catch |err| {
                log.warn("accept error err={}", .{err});
                continue;
            };
            const thread = std.Thread.spawn(.{}, handleConn, .{ state, conn }) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConn(state: *OverlayState.OverlayState, conn: std.net.Server.Connection) void {
        // Register as a broadcast target so user-driven canvas events reach this client,
        // then unregister + close on disconnect (both under the clients mutex so an in-flight
        // emit never writes to a closed fd).
        state.registerClient(conn.stream);
        defer {
            state.unregisterClient(conn.stream);
            conn.stream.close();
        }
        var buf: [65536]u8 = undefined;
        var end: usize = 0;

        while (true) {
            if (end == buf.len) {
                log.warn("overlay IPC: line too long, discarding buffer", .{});
                end = 0;
            }

            const n = conn.stream.read(buf[end..]) catch break;
            if (n == 0) break;
            end += n;

            var scan_start: usize = 0;
            while (scan_start < end) {
                const slice = buf[scan_start..end];
                const nl = std.mem.indexOfScalar(u8, slice, '\n') orelse break;
                const line = std.mem.trim(u8, slice[0..nl], " \r\t");
                if (std.mem.eql(u8, line, "{\"action\":\"ping\"}")) {
                    conn.stream.writeAll("{\"pong\":true}\n") catch {};
                } else if (line.len > 0) {
                    state.applyJson(line) catch |err| log.warn("applyJson err={}", .{err});
                }
                scan_start += nl + 1;
            }

            if (scan_start > 0) {
                const remaining = end - scan_start;
                std.mem.copyForwards(u8, buf[0..remaining], buf[scan_start..end]);
                end = remaining;
            }
        }
    }
};
