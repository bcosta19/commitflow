//! Binary cache of one GitLab source's per-day counts, so an unchanged account costs a single
//! one-line API probe instead of a full scan of every project.
//!
//! Layout, little endian (36-byte header + `n` counts):
//!
//!     "CFLW" | version u8 | 3 pad | user_id u64 | last_event_id u64
//!            | full_scan_day i32 | start_day i32 | n u32 | counts[n] u32
//!
//! Days are stored by epoch day, not by grid position, because the window slides every day.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const calendar = @import("calendar.zig");

const magic = "CFLW";
const version: u8 = 1;
const header_len = 36;
const max_days = 4096;

/// A cache older than this is rescanned even if no new push shows up, since rebases, force-pushes
/// and deleted branches rewrite history without producing a push event we can see.
pub const ttl_days = 7;

pub const Entry = struct {
    user_id: u64,
    /// Newest push event id seen by the scan that produced this entry.
    last_event_id: u64,
    /// UTC epoch day of that scan.
    full_scan_day: i32,
    /// Epoch day of `counts[0]`.
    start_day: i32,
    counts: []const u32,

    pub fn fromCalendar(user_id: u64, last_event_id: u64, scan_day: i32, cal: *const calendar.Calendar) Entry {
        return .{
            .user_id = user_id,
            .last_event_id = last_event_id,
            .full_scan_day = scan_day,
            .start_day = cal.start,
            .counts = &cal.counts,
        };
    }

    /// True if the entry has data for every day of `cal` and is not past its TTL.
    pub fn usableFor(self: Entry, cal: *const calendar.Calendar, today: i32) bool {
        return self.start_day <= cal.start and today - self.full_scan_day <= ttl_days and today >= self.full_scan_day;
    }

    /// Adds the cached days that fall inside `cal`; returns the total added.
    pub fn applyTo(self: Entry, cal: *calendar.Calendar) u64 {
        var total: u64 = 0;
        for (self.counts, 0..) |n, i| {
            const day = self.start_day + @as(i32, @intCast(i));
            if (cal.indexOf(day) != null) {
                cal.add(day, n);
                total += n;
            }
        }
        return total;
    }
};

pub fn encode(arena: Allocator, e: Entry) Allocator.Error![]u8 {
    const buf = try arena.alloc(u8, header_len + e.counts.len * 4);
    @memcpy(buf[0..4], magic);
    buf[4] = version;
    @memset(buf[5..8], 0);
    std.mem.writeInt(u64, buf[8..16], e.user_id, .little);
    std.mem.writeInt(u64, buf[16..24], e.last_event_id, .little);
    std.mem.writeInt(i32, buf[24..28], e.full_scan_day, .little);
    std.mem.writeInt(i32, buf[28..32], e.start_day, .little);
    std.mem.writeInt(u32, buf[32..36], @intCast(e.counts.len), .little);
    for (e.counts, 0..) |c, i| std.mem.writeInt(u32, buf[header_len + i * 4 ..][0..4], c, .little);
    return buf;
}

/// Returns null for anything that is not a well-formed version-1 cache (a miss, never an error).
pub fn decode(arena: Allocator, bytes: []const u8) Allocator.Error!?Entry {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], magic) or bytes[4] != version) return null;
    const n = std.mem.readInt(u32, bytes[32..36], .little);
    if (n > max_days or bytes.len != header_len + @as(usize, n) * 4) return null;
    const counts = try arena.alloc(u32, n);
    for (counts, 0..) |*c, i| c.* = std.mem.readInt(u32, bytes[header_len + i * 4 ..][0..4], .little);
    return .{
        .user_id = std.mem.readInt(u64, bytes[8..16], .little),
        .last_event_id = std.mem.readInt(u64, bytes[16..24], .little),
        .full_scan_day = std.mem.readInt(i32, bytes[24..28], .little),
        .start_day = std.mem.readInt(i32, bytes[28..32], .little),
        .counts = counts,
    };
}

/// UTC epoch day now. Only used for TTL bookkeeping, so the timezone does not matter.
pub fn utcToday(io: Io) i32 {
    const now = Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s * std.time.s_per_day));
}

/// `<dir>/<label with anything but [A-Za-z0-9.@_-] replaced by '_'>.bin`
pub fn pathFor(arena: Allocator, dir: []const u8, label: []const u8) Allocator.Error![]u8 {
    const name = try arena.alloc(u8, label.len);
    for (label, name) |ch, *out| out.* = if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '@' or ch == '-') ch else '_';
    return std.fmt.allocPrint(arena, "{s}/{s}.bin", .{ dir, name });
}

pub fn load(arena: Allocator, io: Io, path: []const u8) Allocator.Error!?Entry {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(header_len + max_days * 4)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return decode(arena, bytes);
}

/// Atomic: written to `<path>.tmp`, then renamed over `path`.
pub fn save(arena: Allocator, io: Io, path: []const u8, e: Entry) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    try Io.Dir.cwd().createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = try encode(arena, e) });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

const date = @import("date.zig");

test "encode/decode round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const counts = [_]u32{ 0, 5, 0, 4_000_000_000, 7 };
    const e: Entry = .{ .user_id = 213, .last_event_id = 5003131123, .full_scan_day = -3, .start_day = 20400, .counts = &counts };
    const got = (try decode(a, try encode(a, e))).?;
    try std.testing.expectEqual(e.user_id, got.user_id);
    try std.testing.expectEqual(e.last_event_id, got.last_event_id);
    try std.testing.expectEqual(e.full_scan_day, got.full_scan_day);
    try std.testing.expectEqual(e.start_day, got.start_day);
    try std.testing.expectEqualSlices(u32, &counts, got.counts);
}

test "decode treats damaged files as a miss" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const counts = [_]u32{ 1, 2, 3 };
    const good = try encode(a, .{ .user_id = 1, .last_event_id = 2, .full_scan_day = 3, .start_day = 4, .counts = &counts });

    try std.testing.expect(try decode(a, good[0 .. good.len - 1]) == null); // truncated
    try std.testing.expect(try decode(a, good[0..10]) == null);
    try std.testing.expect(try decode(a, "") == null);
    const bad_magic = try a.dupe(u8, good);
    bad_magic[0] = 'X';
    try std.testing.expect(try decode(a, bad_magic) == null);
    const bad_version = try a.dupe(u8, good);
    bad_version[4] = 99;
    try std.testing.expect(try decode(a, bad_version) == null);
    const huge_n = try a.dupe(u8, good);
    std.mem.writeInt(u32, huge_n[32..36], 1 << 30, .little);
    try std.testing.expect(try decode(a, huge_n) == null);
}

test "usableFor: coverage and TTL" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    const cal = calendar.Calendar.init(end);
    const counts = [_]u32{0};
    var e: Entry = .{ .user_id = 1, .last_event_id = 1, .full_scan_day = end, .start_day = cal.start, .counts = &counts };
    try std.testing.expect(e.usableFor(&cal, end));
    try std.testing.expect(e.usableFor(&cal, end + ttl_days));
    try std.testing.expect(!e.usableFor(&cal, end + ttl_days + 1));
    e.start_day = cal.start + 1; // cache starts after the window does: days are missing
    try std.testing.expect(!e.usableFor(&cal, end));
    e.start_day = cal.start - 30; // an older, wider cache still covers it
    try std.testing.expect(e.usableFor(&cal, end));
}

test "applyTo follows the sliding window by date, not position" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var old = calendar.Calendar.init(end - 3);
    old.add(end - 10, 4);
    old.add(end - 3, 9);
    const e = Entry.fromCalendar(1, 1, end - 3, &old);

    var now = calendar.Calendar.init(end); // window moved forward 3 days
    try std.testing.expectEqual(@as(u64, 13), e.applyTo(&now));
    try std.testing.expectEqual(@as(u32, 4), now.counts[now.indexOf(end - 10).?]);
    try std.testing.expectEqual(@as(u32, 9), now.counts[now.indexOf(end - 3).?]);
}

test "cache file path is filesystem-safe" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try pathFor(arena_state.allocator(), "/c", "gitlab.example.org/../bruno passos");
    try std.testing.expectEqualStrings("/c/gitlab.example.org_.._bruno_passos.bin", p);
}

test "save and load through the filesystem" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/nested/cache", .{tmp.sub_path});
    const path = try std.fmt.allocPrint(a, "{s}/x.bin", .{dir});

    try std.testing.expect(try load(a, io, path) == null); // missing file is a miss
    const counts = [_]u32{ 3, 0, 8 };
    try save(a, io, path, .{ .user_id = 9, .last_event_id = 77, .full_scan_day = 1, .start_day = 2, .counts = &counts });
    const got = (try load(a, io, path)).?;
    try std.testing.expectEqual(@as(u64, 77), got.last_event_id);
    try std.testing.expectEqualSlices(u32, &counts, got.counts);
}
