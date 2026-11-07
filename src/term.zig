//! Terminal size and cursor safety (Linux).

const std = @import("std");
const linux = std.os.linux;

pub const Size = struct { cols: usize, rows: usize };

pub fn size() ?Size {
    var ws: std.posix.winsize = undefined;
    if (linux.ioctl(1, std.posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}

pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h\x1b[0m";

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    _ = linux.write(1, show_cursor.ptr, show_cursor.len);
    _ = linux.write(1, "\n", 1);
    linux.exit_group(130);
}

/// Restores the cursor if the animation is interrupted by Ctrl-C or SIGTERM.
pub fn installCursorRestore() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}
