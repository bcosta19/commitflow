//! Calendar-date helpers on top of epoch days (days since 1970-01-01, UTC).

const std = @import("std");
const epoch = std.time.epoch;

pub const Date = struct {
    year: u16,
    month: u4, // 1..12
    day: u5, // 1..31

    pub fn fromEpochDay(day: i32) Date {
        const ed: epoch.EpochDay = .{ .day = @intCast(day) };
        const yd = ed.calculateYearDay();
        const md = yd.calculateMonthDay();
        return .{ .year = yd.year, .month = md.month.numeric(), .day = md.day_index + 1 };
    }

    pub fn toEpochDay(self: Date) i32 {
        // Howard Hinnant's days_from_civil.
        const y: i32 = @as(i32, self.year) - @intFromBool(self.month <= 2);
        const era = @divFloor(y, 400);
        const yoe: i32 = y - era * 400;
        const m: i32 = self.month;
        const mp: i32 = @mod(m + 9, 12);
        const doy: i32 = @divFloor(153 * mp + 2, 5) + @as(i32, self.day) - 1;
        const doe: i32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    /// Parses the leading `YYYY-MM-DD` of `s` (extra trailing text, e.g. a time, is ignored).
    pub fn parse(s: []const u8) error{InvalidDate}!Date {
        if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.InvalidDate;
        const year = std.fmt.parseInt(u16, s[0..4], 10) catch return error.InvalidDate;
        const month = std.fmt.parseInt(u4, s[5..7], 10) catch return error.InvalidDate;
        const day = std.fmt.parseInt(u5, s[8..10], 10) catch return error.InvalidDate;
        if (month < 1 or month > 12 or day < 1) return error.InvalidDate;
        if (day > epoch.getDaysInMonth(year, @enumFromInt(month))) return error.InvalidDate;
        return .{ .year = year, .month = month, .day = day };
    }

    pub fn format(self: Date, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }
};

/// Day of week for an epoch day, 0 = Sunday.
pub fn weekday(epoch_day: i32) u3 {
    // 1970-01-01 was a Thursday.
    return @intCast(@mod(epoch_day + 4, 7));
}

pub const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

test "epoch day round trip" {
    const cases = [_][]const u8{ "1970-01-01", "2000-02-29", "2024-12-31", "2026-11-07", "2100-03-01" };
    for (cases) |c| {
        const d = try Date.parse(c);
        const back = Date.fromEpochDay(d.toEpochDay());
        try std.testing.expectEqual(d, back);
    }
    try std.testing.expectEqual(@as(i32, 0), (try Date.parse("1970-01-01")).toEpochDay());
    try std.testing.expectEqual(@as(i32, 19723), (try Date.parse("2024-01-01")).toEpochDay());
}

test "weekday" {
    try std.testing.expectEqual(@as(u3, 4), weekday(0)); // Thursday
    try std.testing.expectEqual(@as(u3, 6), weekday((try Date.parse("2026-11-07")).toEpochDay())); // Saturday
    try std.testing.expectEqual(@as(u3, 0), weekday((try Date.parse("2026-11-01")).toEpochDay())); // Sunday
}

test "parse rejects bad input" {
    try std.testing.expectError(error.InvalidDate, Date.parse("2026-13-01"));
    try std.testing.expectError(error.InvalidDate, Date.parse("2026-02-30"));
    try std.testing.expectError(error.InvalidDate, Date.parse("26-02-01"));
    try std.testing.expectError(error.InvalidDate, Date.parse("2026/02/01"));
    const d = try Date.parse("2026-01-16T18:05:38.864Z");
    try std.testing.expectEqual(@as(u5, 16), d.day);
}
