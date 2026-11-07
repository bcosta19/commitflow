//! Synthetic commit history for `--demo`: no accounts, network or CLI tools needed.
//!
//! The shape is meant to look like a real developer's year: busy weekdays, quiet weekends, a slow
//! wave of intensity, a couple of week-long breaks and the occasional huge day.

const std = @import("std");
const calendar = @import("calendar.zig");
const date = @import("date.zig");

pub const default_seed: u64 = 2026;

/// Fills `cal` (days up to `cal.end`) deterministically from `seed`.
pub fn fill(cal: *calendar.Calendar, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const last = cal.lastIndex();
    var break_left: usize = 0;
    for (0..last + 1) |i| {
        if (break_left > 0) {
            break_left -= 1;
            continue;
        }
        // Roughly two breaks per year: 4-9 days off.
        if (rng.uintLessThan(u16, 200) == 0) {
            break_left = 3 + rng.uintLessThan(usize, 6);
            continue;
        }

        const weekday = i % 7; // the window starts on a Sunday
        const weekend = weekday == 0 or weekday == 6;
        const wave = 0.5 + 0.5 * @sin(@as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / 83.0);
        const base: f32 = if (weekend) 0.22 else 0.82;
        const p_active: f32 = base * (0.55 + 0.45 * wave);
        if (rng.float(f32) >= p_active) continue;

        // Exponential-ish: many small days, a few big ones; busier during the wave's crest.
        const mean: f32 = 1.5 + 5.5 * wave;
        const n: f32 = 1.0 + @floor(-@log(1.0 - rng.float(f32)) * mean);
        const spike: f32 = if (rng.uintLessThan(u8, 50) == 0) 4.0 else 1.0;
        cal.counts[i] = @intFromFloat(@min(n * spike, 150.0));
    }
}

test "demo data is deterministic and varies with the seed" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var a = calendar.Calendar.init(end);
    var b = calendar.Calendar.init(end);
    var c = calendar.Calendar.init(end);
    fill(&a, default_seed);
    fill(&b, default_seed);
    fill(&c, default_seed + 1);
    try std.testing.expectEqualSlices(u32, &a.counts, &b.counts);
    try std.testing.expect(!std.mem.eql(u32, &a.counts, &c.counts));
}

test "demo data looks like a working year" {
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var cal = calendar.Calendar.init(end);
    fill(&cal, default_seed);
    const s = cal.stats();
    try std.testing.expect(s.total > 500 and s.total < 20_000);
    try std.testing.expect(s.active_days > 100 and s.active_days < 330);
    try std.testing.expect(s.longest_streak >= 5);

    // Weekdays must be clearly busier than weekends.
    var weekday_sum: u64 = 0;
    var weekend_sum: u64 = 0;
    for (cal.counts[0 .. cal.lastIndex() + 1], 0..) |n, i| {
        if (i % 7 == 0 or i % 7 == 6) weekend_sum += n else weekday_sum += n;
    }
    try std.testing.expect(weekday_sum / 5 > 2 * (weekend_sum / 2));
}

test "demo data never touches future cells" {
    const end = (try date.Date.parse("2026-11-04")).toEpochDay(); // Wednesday: rest of week is future
    var cal = calendar.Calendar.init(end);
    fill(&cal, default_seed);
    for (cal.counts[cal.lastIndex() + 1 ..]) |n| try std.testing.expectEqual(@as(u32, 0), n);
}
