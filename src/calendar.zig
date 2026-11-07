//! Per-day commit counts over a Sunday-aligned window of `weeks` weeks.

const std = @import("std");
const date = @import("date.zig");

pub const weeks = 53;
pub const days = weeks * 7;

pub const Calendar = struct {
    /// Epoch day of the first cell (always a Sunday).
    start: i32,
    /// Epoch day of the last real day (the window may continue into the future up to Saturday).
    end: i32,
    counts: [days]u32 = @splat(0),

    /// Window that ends on `end` and spans 53 weeks, so the first column is the Sunday of the week
    /// that began 52 weeks before the week of `end`.
    pub fn init(end: i32) Calendar {
        const week_start = end - date.weekday(end);
        return .{ .start = week_start - (weeks - 1) * 7, .end = end };
    }

    /// Index of `epoch_day` inside the window, or null if outside `[start, end]`.
    pub fn indexOf(self: *const Calendar, epoch_day: i32) ?usize {
        if (epoch_day < self.start or epoch_day > self.end) return null;
        return @intCast(epoch_day - self.start);
    }

    pub fn add(self: *Calendar, epoch_day: i32, n: u32) void {
        if (self.indexOf(epoch_day)) |i| self.counts[i] += n;
    }

    /// Index of the last real day.
    pub fn lastIndex(self: *const Calendar) usize {
        return @intCast(self.end - self.start);
    }

    pub const Stats = struct {
        total: u64 = 0,
        active_days: u32 = 0,
        longest_streak: u32 = 0,
        /// Streak ending today, or yesterday if today has no commits yet.
        current_streak: u32 = 0,
        busiest_index: usize = 0,
        busiest_count: u32 = 0,
    };

    pub fn stats(self: *const Calendar) Stats {
        var s: Stats = .{};
        var run: u32 = 0;
        const last = self.lastIndex();
        for (self.counts[0 .. last + 1], 0..) |c, i| {
            s.total += c;
            if (c > s.busiest_count) {
                s.busiest_count = c;
                s.busiest_index = i;
            }
            if (c > 0) {
                s.active_days += 1;
                run += 1;
                s.longest_streak = @max(s.longest_streak, run);
            } else {
                // A quiet "today" does not break the streak yet.
                if (i != last) run = 0;
            }
        }
        s.current_streak = run;
        return s;
    }

    /// Weekly totals for column `w`, counting only days with index < `visible`.
    pub fn weekTotal(self: *const Calendar, w: usize, visible: usize) u32 {
        var t: u32 = 0;
        for (0..7) |d| {
            const i = w * 7 + d;
            if (i < visible) t += self.counts[i];
        }
        return t;
    }

    /// Adds `other`'s counts day by day. Both windows must cover the same days.
    pub fn merge(self: *Calendar, other: *const Calendar) void {
        std.debug.assert(self.start == other.start);
        for (&self.counts, other.counts) |*a, b| a.* += b;
    }

    pub fn maxWeekTotal(self: *const Calendar) u32 {
        var m: u32 = 0;
        for (0..weeks) |w| m = @max(m, self.weekTotal(w, days));
        return m;
    }

    /// Upper bounds of intensity levels 1..3; level 4 is anything above `t[2]`.
    /// Quartiles of the non-zero days, so one huge day does not flatten everything else.
    pub fn thresholds(self: *const Calendar) [3]u32 {
        var buf: [days]u32 = undefined;
        var n: usize = 0;
        for (self.counts[0 .. self.lastIndex() + 1]) |c| {
            if (c == 0) continue;
            buf[n] = c;
            n += 1;
        }
        if (n == 0) return .{ 1, 2, 3 };
        std.mem.sort(u32, buf[0..n], {}, std.sort.asc(u32));
        return .{ buf[n / 4], buf[n / 2], buf[n * 3 / 4] };
    }
};

/// Intensity level 0..4 for a day count.
pub fn level(count: u32, t: [3]u32) u3 {
    if (count == 0) return 0;
    return 1 + @as(u3, @intFromBool(count > t[0])) + @intFromBool(count > t[1]) + @intFromBool(count > t[2]);
}

test "window is Sunday aligned and 53 weeks wide" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay(); // Saturday
    const cal = Calendar.init(end);
    try std.testing.expectEqual(@as(u3, 0), date.weekday(cal.start));
    try std.testing.expectEqual(@as(usize, days - 1), cal.lastIndex());
    try std.testing.expectEqual(@as(?usize, 0), cal.indexOf(cal.start));
    try std.testing.expectEqual(@as(?usize, null), cal.indexOf(cal.start - 1));
    try std.testing.expectEqual(@as(?usize, null), cal.indexOf(end + 1));
}

test "mid-week end leaves future cells" {
    const end = (try date.Date.parse("2026-11-04")).toEpochDay(); // Wednesday
    const cal = Calendar.init(end);
    try std.testing.expectEqual(@as(usize, days - 4), cal.lastIndex());
}

test "stats: streaks, totals and busiest day" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var cal = Calendar.init(end);
    // 3-day streak a while ago, then a 2-day streak ending yesterday; today empty.
    cal.add(end - 20, 1);
    cal.add(end - 19, 4);
    cal.add(end - 18, 1);
    cal.add(end - 2, 2);
    cal.add(end - 1, 9);
    cal.add(end + 5, 100); // outside window: ignored
    const s = cal.stats();
    try std.testing.expectEqual(@as(u64, 17), s.total);
    try std.testing.expectEqual(@as(u32, 5), s.active_days);
    try std.testing.expectEqual(@as(u32, 3), s.longest_streak);
    try std.testing.expectEqual(@as(u32, 2), s.current_streak);
    try std.testing.expectEqual(@as(u32, 9), s.busiest_count);
    try std.testing.expectEqual(@as(usize, cal.lastIndex() - 1), s.busiest_index);
}

test "merge adds day by day" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var a = Calendar.init(end);
    var b = Calendar.init(end);
    a.add(end, 2);
    b.add(end, 3);
    b.add(end - 5, 1);
    a.merge(&b);
    try std.testing.expectEqual(@as(u32, 5), a.counts[a.indexOf(end).?]);
    try std.testing.expectEqual(@as(u32, 1), a.counts[a.indexOf(end - 5).?]);
    try std.testing.expectEqual(@as(u32, 3), b.counts[b.indexOf(end).?]); // source untouched
}

test "stats: gap before today resets the streak" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var cal = Calendar.init(end);
    cal.add(end - 3, 1);
    try std.testing.expectEqual(@as(u32, 0), cal.stats().current_streak);
    cal.add(end, 1);
    try std.testing.expectEqual(@as(u32, 1), cal.stats().current_streak);
}

test "levels use quartiles of active days" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var cal = Calendar.init(end);
    for (1..9) |i| cal.add(end - @as(i32, @intCast(i)), @intCast(i)); // counts 1..8
    cal.add(end - 20, 1000);
    const t = cal.thresholds();
    try std.testing.expectEqual(@as(u3, 0), level(0, t));
    try std.testing.expectEqual(@as(u3, 1), level(1, t));
    try std.testing.expectEqual(@as(u3, 4), level(1000, t));
    // The outlier must not push ordinary days to level 1.
    try std.testing.expect(level(7, t) >= 3);
}
