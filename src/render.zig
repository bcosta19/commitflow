//! Frame renderer: contribution heatmap that is revealed day by day, with a weekly-volume bar chart
//! growing underneath it. Every frame is exactly `line_count` lines so the caller can redraw in place.

const std = @import("std");
const Writer = std.Io.Writer;
const calendar = @import("calendar.zig");
const date = @import("date.zig");

pub const bar_rows = 6;
pub const label_cols = 4;
pub const line_count = 22;

const Rgb = struct { r: u8, g: u8, b: u8 };

const palette = [5]Rgb{
    .{ .r = 45, .g = 51, .b = 59 }, // no commits
    .{ .r = 14, .g = 68, .b = 41 },
    .{ .r = 0, .g = 109, .b = 50 },
    .{ .r = 38, .g = 166, .b = 65 },
    .{ .r = 57, .g = 211, .b = 83 },
};
const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
const dim_text = "\x1b[38;2;139;148;158m";
const reset = "\x1b[0m";

/// Days over which a freshly revealed cell fades from white to its level colour.
const flash_days = 6;

const plain_glyphs = [5][]const u8{ "·", "░", "▒", "▓", "█" };
const bar_glyphs = [9][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

pub const Renderer = struct {
    cal: *const calendar.Calendar,
    stats: calendar.Calendar.Stats,
    thresholds: [3]u32,
    max_week: u32,
    /// 1 or 2 terminal columns per week.
    cell_w: u8,
    color: bool,
    /// e.g. "github.com/bcosta19 + gitlab.com/bruno".
    title: []const u8,

    pub fn init(cal: *const calendar.Calendar, cell_w: u8, color: bool, title: []const u8) Renderer {
        return .{
            .cal = cal,
            .stats = cal.stats(),
            .thresholds = cal.thresholds(),
            .max_week = cal.maxWeekTotal(),
            .cell_w = cell_w,
            .color = color,
            .title = title,
        };
    }

    pub fn minColumns(cell_w: u8) usize {
        return label_cols + calendar.weeks * cell_w;
    }

    /// Writes `line_count` lines. `visible` = number of days revealed so far (clamped to the window).
    pub fn frame(self: *const Renderer, w: *Writer, visible_in: usize) Writer.Error!void {
        const total_days = self.cal.lastIndex() + 1;
        const visible = @min(visible_in, total_days);
        const done = visible >= total_days;

        // 0-1: header
        try line(w);
        try w.print("  {s}commitflow{s}  {s}{s}{s}", .{ bold(self), self.resetSeq(), self.dim(), self.title, self.resetSeq() });
        try endLine(w);
        try line(w);
        try w.print("  {s}{f} → {f}{s}", .{
            self.dim(),
            date.Date.fromEpochDay(self.cal.start),
            date.Date.fromEpochDay(self.cal.end),
            self.resetSeq(),
        });
        try endLine(w);
        try line(w);
        try endLine(w);

        // 3: month labels
        try line(w);
        try self.monthLabels(w);
        try endLine(w);

        // 4-10: heatmap
        for (0..7) |d| {
            try line(w);
            try self.heatRow(w, d, visible);
            try endLine(w);
        }

        try line(w);
        try endLine(w);

        // 12-17: weekly bars
        for (0..bar_rows) |r| {
            try line(w);
            try self.barRow(w, r, visible);
            try endLine(w);
        }

        try line(w);
        try endLine(w);

        // 19: running counter
        try line(w);
        try self.status(w, visible, done);
        try endLine(w);

        // 20: summary (only once the animation finishes)
        try line(w);
        if (done) try self.summary(w);
        try endLine(w);

        // 21: legend
        try line(w);
        try self.legend(w);
        try endLine(w);
    }

    fn bold(self: *const Renderer) []const u8 {
        return if (self.color) "\x1b[1m" else "";
    }
    fn dim(self: *const Renderer) []const u8 {
        return if (self.color) dim_text else "";
    }
    fn resetSeq(self: *const Renderer) []const u8 {
        return if (self.color) reset else "";
    }

    fn setColor(self: *const Renderer, w: *Writer, c: Rgb, last: *?Rgb) Writer.Error!void {
        if (!self.color) return;
        if (last.*) |l| if (l.r == c.r and l.g == c.g and l.b == c.b) return;
        try w.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
        last.* = c;
    }

    fn pad(self: *const Renderer, w: *Writer) Writer.Error!void {
        try w.splatByteAll(' ', self.cell_w - 1);
    }

    fn monthLabels(self: *const Renderer, w: *Writer) Writer.Error!void {
        try w.splatByteAll(' ', label_cols);
        try w.writeAll(self.dim());
        var col: usize = 0; // terminal columns written after the label gutter
        var prev_month: u4 = 0;
        for (0..calendar.weeks) |wk| {
            const d = date.Date.fromEpochDay(self.cal.start + @as(i32, @intCast(wk * 7)));
            if (d.month != prev_month) {
                prev_month = d.month;
                const target = wk * self.cell_w;
                // Skip a label that would collide with the previous one or run past the grid.
                if (target >= col and target + 3 <= calendar.weeks * self.cell_w + 2) {
                    try w.splatByteAll(' ', target - col);
                    try w.writeAll(date.month_names[d.month - 1]);
                    col = target + 3;
                }
            }
        }
        try w.writeAll(self.resetSeq());
    }

    fn heatRow(self: *const Renderer, w: *Writer, d: usize, visible: usize) Writer.Error!void {
        const label = switch (d) {
            1 => "Mon ",
            3 => "Wed ",
            5 => "Fri ",
            else => "    ",
        };
        try w.writeAll(self.dim());
        try w.writeAll(label);
        try w.writeAll(self.resetSeq());

        const last = self.cal.lastIndex();
        var last_color: ?Rgb = null;
        for (0..calendar.weeks) |wk| {
            const i = wk * 7 + d;
            if (i > last) {
                try w.splatByteAll(' ', self.cell_w);
                continue;
            }
            const count = self.cal.counts[i];
            const lvl = if (i < visible) calendar.level(count, self.thresholds) else 0;
            if (self.color) {
                try self.setColor(w, self.cellColor(i, visible), &last_color);
                try w.writeAll("■");
            } else {
                try w.writeAll(plain_glyphs[lvl]);
            }
            try self.pad(w);
        }
        if (self.color) try w.writeAll(reset);
    }

    fn cellColor(self: *const Renderer, i: usize, visible: usize) Rgb {
        if (i >= visible) return palette[0];
        const count = self.cal.counts[i];
        const base = palette[calendar.level(count, self.thresholds)];
        const age = visible - 1 - i;
        if (age == 0) return white; // scan head
        if (count > 0 and age < flash_days) return mix(white, base, age, flash_days);
        return base;
    }

    fn barRow(self: *const Renderer, w: *Writer, r: usize, visible: usize) Writer.Error!void {
        // Scale label on the top row.
        if (r == 0 and self.max_week > 0) {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{self.max_week}) catch "";
            try w.writeAll(self.dim());
            try w.splatByteAll(' ', label_cols -| (s.len + 1));
            try w.writeAll(s);
            try w.writeAll(" ");
            try w.writeAll(self.resetSeq());
        } else {
            try w.splatByteAll(' ', label_cols);
        }

        const max: u64 = @max(self.max_week, 1);
        var last_color: ?Rgb = null;
        for (0..calendar.weeks) |wk| {
            const v = self.cal.weekTotal(wk, visible);
            var eighths: u64 = (@as(u64, v) * bar_rows * 8 + max / 2) / max;
            if (v > 0 and eighths == 0) eighths = 1;
            const below = (bar_rows - 1 - r) * 8;
            const units: usize = if (eighths <= below) 0 else @intCast(@min(8, eighths - below));
            if (units > 0) {
                const lvl: usize = 1 + @as(usize, @intFromBool(v * 4 > self.max_week)) +
                    @intFromBool(v * 2 > self.max_week) + @intFromBool(v * 4 > self.max_week * 3);
                try self.setColor(w, palette[@min(lvl, 4)], &last_color);
            }
            try w.writeAll(bar_glyphs[units]);
            try self.pad(w);
        }
        if (self.color) try w.writeAll(reset);
    }

    fn status(self: *const Renderer, w: *Writer, visible: usize, done: bool) Writer.Error!void {
        var running: u64 = 0;
        for (self.cal.counts[0..visible]) |c| running += c;
        const shown = if (visible == 0) 0 else visible - 1;
        try w.writeAll("  ");
        try w.writeAll(self.dim());
        try w.print("{f}", .{date.Date.fromEpochDay(self.cal.start + @as(i32, @intCast(shown)))});
        try w.writeAll(self.resetSeq());
        try w.writeAll("  ");
        try w.writeAll(self.bold());
        try writeCount(w, running);
        try w.writeAll(self.resetSeq());
        try w.print(" {s}", .{if (running == 1) "commit" else "commits"});
        if (done) try w.writeAll(" ✓");
    }

    fn summary(self: *const Renderer, w: *Writer) Writer.Error!void {
        const s = self.stats;
        const avg_x10: u64 = (s.total * 10 * 7) / @as(u64, self.cal.lastIndex() + 1);
        try w.writeAll("  ");
        try w.writeAll(self.dim());
        try w.print("{d} active days · longest streak {d}d · current {d}d · avg {d}.{d}/week", .{
            s.active_days, s.longest_streak, s.current_streak, avg_x10 / 10, avg_x10 % 10,
        });
        if (s.busiest_count > 0) {
            try w.print(" · busiest {f} (", .{date.Date.fromEpochDay(self.cal.start + @as(i32, @intCast(s.busiest_index)))});
            try writeCount(w, s.busiest_count);
            try w.writeAll(")");
        }
        try w.writeAll(self.resetSeq());
    }

    fn legend(self: *const Renderer, w: *Writer) Writer.Error!void {
        try w.writeAll("  ");
        try w.writeAll(self.dim());
        try w.writeAll("Less ");
        var last_color: ?Rgb = null;
        for (palette, 0..) |c, lvl| {
            if (self.color) {
                try self.setColor(w, c, &last_color);
                try w.writeAll("■ ");
            } else {
                try w.print("{s} ", .{plain_glyphs[lvl]});
            }
        }
        if (self.color) try w.writeAll(dim_text);
        try w.writeAll("More");
        try w.writeAll(self.resetSeq());
    }
};

/// Start of every output line: clear it, so shorter content never leaves stale characters.
fn line(w: *Writer) Writer.Error!void {
    try w.writeAll("\x1b[2K");
}

fn endLine(w: *Writer) Writer.Error!void {
    try w.writeAll("\n");
}

fn mix(a: Rgb, b: Rgb, num: usize, den: usize) Rgb {
    const n: u32 = @intCast(num);
    const d: u32 = @intCast(den);
    return .{
        .r = @intCast((@as(u32, a.r) * (d - n) + @as(u32, b.r) * n) / d),
        .g = @intCast((@as(u32, a.g) * (d - n) + @as(u32, b.g) * n) / d),
        .b = @intCast((@as(u32, a.b) * (d - n) + @as(u32, b.b) * n) / d),
    };
}

pub fn writeCount(w: *Writer, n: u64) Writer.Error!void {
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    for (digits, 0..) |ch, i| {
        if (i != 0 and (digits.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(ch);
    }
}

fn sampleCalendar() !calendar.Calendar {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var cal = calendar.Calendar.init(end);
    var i: i32 = 0;
    while (i < 300) : (i += 1) {
        if (@mod(i * 7, 5) != 0) cal.add(end - i, @intCast(1 + @mod(i * 13, 11)));
    }
    cal.add(end - 40, 1500);
    return cal;
}

fn countNewlines(s: []const u8) usize {
    return std.mem.count(u8, s, "\n");
}

test "every frame has exactly line_count lines (required for in-place redraw)" {
    const cal = try sampleCalendar();
    for ([_]bool{ true, false }) |color| {
        for ([_]u8{ 1, 2 }) |cell_w| {
            const r = Renderer.init(&cal, cell_w, color, "test");
            for ([_]usize{ 0, 1, 7, 100, 370, 371, 9999 }) |visible| {
                var aw: Writer.Allocating = .init(std.testing.allocator);
                defer aw.deinit();
                try r.frame(&aw.writer, visible);
                try std.testing.expectEqual(@as(usize, line_count), countNewlines(aw.written()));
            }
        }
    }
}

test "final frame reports totals; early frame hides the summary" {
    const cal = try sampleCalendar();
    const r = Renderer.init(&cal, 2, false, "test");

    var done: Writer.Allocating = .init(std.testing.allocator);
    defer done.deinit();
    try r.frame(&done.writer, 9999);
    var expect: Writer.Allocating = .init(std.testing.allocator);
    defer expect.deinit();
    try writeCount(&expect.writer, r.stats.total);
    try std.testing.expect(std.mem.indexOf(u8, done.written(), expect.written()) != null);
    try std.testing.expect(std.mem.indexOf(u8, done.written(), "longest streak") != null);

    var early: Writer.Allocating = .init(std.testing.allocator);
    defer early.deinit();
    try r.frame(&early.writer, 10);
    try std.testing.expect(std.mem.indexOf(u8, early.written(), "longest streak") == null);
}

test "color-free output has no escape sequences other than line clears" {
    const cal = try sampleCalendar();
    const r = Renderer.init(&cal, 1, false, "test");
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try r.frame(&aw.writer, 200);
    const stripped_count = std.mem.count(u8, aw.written(), "\x1b[2K");
    try std.testing.expectEqual(@as(usize, line_count), stripped_count);
    try std.testing.expectEqual(stripped_count, std.mem.count(u8, aw.written(), "\x1b"));
}

test "thousands separators" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeCount(&aw.writer, 1234567);
    try aw.writer.writeByte(' ');
    try writeCount(&aw.writer, 999);
    try aw.writer.writeByte(' ');
    try writeCount(&aw.writer, 1000);
    try std.testing.expectEqualStrings("1,234,567 999 1,000", aw.written());
}
