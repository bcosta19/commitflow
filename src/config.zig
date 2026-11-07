//! `~/.config/commitflow/config`: one source per line, `#` comments.
//!
//!     github = @me
//!     gitlab = git.example.org/alice

const std = @import("std");
const Allocator = std.mem.Allocator;
const Source = @import("source.zig").Source;

pub const ParseError = error{InvalidConfig} || Allocator.Error;

/// `line_out` receives the 1-based line number of the first invalid line.
pub fn parse(arena: Allocator, text: []const u8, line_out: *usize) ParseError![]const Source {
    var sources: std.ArrayList(Source) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse {
            line_out.* = n;
            return error.InvalidConfig;
        };
        const key = std.mem.trim(u8, l[0..eq], " \t");
        const value = std.mem.trim(u8, l[eq + 1 ..], " \t");
        if (value.len == 0) {
            line_out.* = n;
            return error.InvalidConfig;
        }
        if (std.mem.eql(u8, key, "github")) {
            try sources.append(arena, .{ .github = .{ .user = value } });
        } else if (std.mem.eql(u8, key, "gitlab")) {
            try sources.append(arena, Source.parseGitlab(value));
        } else {
            line_out.* = n;
            return error.InvalidConfig;
        }
    }
    return sources.items;
}

test "parse config" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var bad: usize = 0;
    const src = try parse(arena_state.allocator(),
        \\# my accounts
        \\github = bcosta19
        \\
        \\gitlab = git.example.org/alice   
        \\gitlab=other
    , &bad);
    try std.testing.expectEqual(@as(usize, 3), src.len);
    try std.testing.expectEqualStrings("bcosta19", src[0].github.user);
    try std.testing.expectEqualStrings("git.example.org", src[1].gitlab.host);
    try std.testing.expectEqualStrings("alice", src[1].gitlab.user);
    try std.testing.expectEqualStrings("gitlab.com", src[2].gitlab.host);
}

test "invalid config reports the line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var bad: usize = 0;
    try std.testing.expectError(error.InvalidConfig, parse(arena_state.allocator(), "github = a\nbitbucket = b\n", &bad));
    try std.testing.expectEqual(@as(usize, 2), bad);
    try std.testing.expectError(error.InvalidConfig, parse(arena_state.allocator(), "github\n", &bad));
    try std.testing.expectError(error.InvalidConfig, parse(arena_state.allocator(), "github =\n", &bad));
}
