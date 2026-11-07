const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const calendar = @import("calendar.zig");
const config = @import("config.zig");
const date = @import("date.zig");
const demo = @import("demo.zig");
const render = @import("render.zig");
const source = @import("source.zig");
const term = @import("term.zig");

const usage =
    \\commitflow — animate a year of commits in the terminal
    \\
    \\usage: commitflow [options]
    \\
    \\sources (default: ~/.config/commitflow/config, else `--github @me`):
    \\  --github USER        GitHub user via `gh` (@me = authenticated user). Repeatable.
    \\  --gitlab SPEC        GitLab user via `glab`: USER, HOST/USER or HOST/ (authenticated
    \\                       user on HOST); HOST defaults to gitlab.com. Repeatable.
    \\
    \\options:
    \\  --end YYYY-MM-DD     last day of the window (default: today)
    \\  --duration SECONDS   animation length (default 6)
    \\  --fps N              frames per second (default 30)
    \\  --static             print only the final frame
    \\  --no-color           plain glyphs instead of 24-bit colour (also honours NO_COLOR)
    \\  --refresh            ignore the GitLab cache and rescan (the cache is rewritten)
    \\  --no-cache           neither read nor write the cache
    \\  --demo               animate synthetic data (no accounts, network or CLI tools needed)
    \\  --config PATH        config file (default $XDG_CONFIG_HOME/commitflow/config)
    \\  -h, --help           show this help
    \\
    \\config file lines:  github = USER   |   gitlab = [HOST/]USER   |   # comment
    \\cache: $XDG_CACHE_HOME/commitflow/ (default ~/.cache/commitflow/), GitLab only; reused while
    \\no new push event appears and the last full scan is at most 7 days old.
    \\
;

const Options = struct {
    sources: std.ArrayList(source.Source) = .empty,
    end: ?date.Date = null,
    duration: f64 = 6,
    fps: u32 = 30,
    static: bool = false,
    no_color: bool = false,
    refresh: bool = false,
    no_cache: bool = false,
    demo: bool = false,
    config_path: ?[]const u8 = null,
    help: bool = false,
};

const ArgError = error{BadArgs} || Allocator.Error;

fn parseArgs(arena: Allocator, args: []const [:0]const u8) ArgError!Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (eq(a, "-h") or eq(a, "--help")) {
            o.help = true;
        } else if (eq(a, "--static")) {
            o.static = true;
        } else if (eq(a, "--no-color")) {
            o.no_color = true;
        } else if (eq(a, "--refresh")) {
            o.refresh = true;
        } else if (eq(a, "--no-cache")) {
            o.no_cache = true;
        } else if (eq(a, "--demo")) {
            o.demo = true;
        } else if (eq(a, "--github")) {
            try o.sources.append(arena, .{ .github = .{ .user = try value(args, &i) } });
        } else if (eq(a, "--gitlab")) {
            try o.sources.append(arena, source.Source.parseGitlab(try value(args, &i)));
        } else if (eq(a, "--config")) {
            o.config_path = try value(args, &i);
        } else if (eq(a, "--end")) {
            o.end = date.Date.parse(try value(args, &i)) catch return fail("--end expects YYYY-MM-DD", .{});
        } else if (eq(a, "--duration")) {
            const v = std.fmt.parseFloat(f64, try value(args, &i)) catch return fail("--duration expects a number of seconds", .{});
            if (!(v >= 0 and v <= 600)) return fail("--duration must be between 0 and 600", .{});
            o.duration = v;
        } else if (eq(a, "--fps")) {
            const v = std.fmt.parseInt(u32, try value(args, &i), 10) catch return fail("--fps expects a positive integer", .{});
            if (v == 0 or v > 240) return fail("--fps must be between 1 and 240", .{});
            o.fps = v;
        } else {
            return fail("unknown option: {s}", .{a});
        }
    }
    return o;
}

fn value(args: []const [:0]const u8, i: *usize) ArgError![]const u8 {
    if (i.* + 1 >= args.len) return fail("{s} needs a value", .{args[i.*]});
    i.* += 1;
    return args[i.*];
}

fn fail(comptime fmt: []const u8, args: anytype) error{BadArgs} {
    std.debug.print("commitflow: " ++ fmt ++ "\n", args);
    return error.BadArgs;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    var opts = parseArgs(arena, args) catch |err| switch (err) {
        error.BadArgs => return 2,
        error.OutOfMemory => return err,
    };
    if (opts.help) {
        try Io.File.stdout().writeStreamingAll(io, usage);
        return 0;
    }

    const today = if (opts.end) |d| d.toEpochDay() else try todayEpochDay(arena, io);
    var cal = calendar.Calendar.init(today);

    if (opts.demo) {
        if (opts.sources.items.len != 0) {
            std.debug.print("commitflow: --demo cannot be combined with --github/--gitlab\n", .{});
            return 2;
        }
        demo.fill(&cal, demo.default_seed);
        try play(io, init.environ_map, &opts, &cal, "demo · synthetic data");
        return 0;
    }

    const sources = (try resolveSources(arena, io, init.environ_map, &opts)) orelse return 2;
    const cc: source.CacheConfig = .{
        .dir = if (opts.no_cache) null else try defaultCacheDir(arena, init.environ_map),
        .refresh = opts.refresh,
    };

    var failed: usize = 0;
    var labels: std.ArrayList(u8) = .empty;
    for (sources) |src| {
        const label = try src.label(arena);
        std.debug.print("fetching {s} ...\n", .{label});
        const added = source.fetch(init.gpa, arena, io, cc, src, &cal) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.SourceFailed, error.BadResponse => {
                failed += 1;
                continue;
            },
        };
        std.debug.print("  {d} {s}\n", .{ added, if (src == .github) "contributions" else "commits" });
        if (labels.items.len != 0) try labels.appendSlice(arena, " + ");
        try labels.appendSlice(arena, label);
    }
    if (failed == sources.len) {
        std.debug.print("commitflow: no source could be fetched\n", .{});
        return 1;
    }
    if (failed != 0) std.debug.print("commitflow: {d} of {d} sources failed; showing the rest\n", .{ failed, sources.len });

    try play(io, init.environ_map, &opts, &cal, labels.items);
    return 0;
}

/// CLI sources win; otherwise the config file; otherwise the authenticated GitHub user.
/// Returns null (after printing a diagnostic) if the config file is invalid.
fn resolveSources(arena: Allocator, io: Io, env: *const std.process.Environ.Map, opts: *Options) !?[]const source.Source {
    if (opts.sources.items.len != 0) return opts.sources.items;

    const path = opts.config_path orelse (try defaultConfigPath(arena, env));
    if (path) |p| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                std.debug.print("commitflow: cannot read {s}: {s}\n", .{ p, @errorName(err) });
                return null;
            },
        };
        if (text) |t| {
            var bad_line: usize = 0;
            const parsed = config.parse(arena, t, &bad_line) catch |err| switch (err) {
                error.InvalidConfig => {
                    std.debug.print("commitflow: {s}:{d}: invalid line (expected `github = USER` or `gitlab = [HOST/]USER`)\n", .{ p, bad_line });
                    return null;
                },
                error.OutOfMemory => return err,
            };
            if (parsed.len != 0) return parsed;
        } else if (opts.config_path != null) {
            std.debug.print("commitflow: config file not found: {s}\n", .{p});
            return null;
        }
    }
    const default = try arena.alloc(source.Source, 1);
    default[0] = .{ .github = .{ .user = source.me } };
    return default;
}

fn defaultCacheDir(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len != 0) return try std.fmt.allocPrint(arena, "{s}/commitflow", .{x});
    if (env.get("HOME")) |h| if (h.len != 0) return try std.fmt.allocPrint(arena, "{s}/.cache/commitflow", .{h});
    return null;
}

fn defaultConfigPath(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len != 0) return try std.fmt.allocPrint(arena, "{s}/commitflow/config", .{x});
    if (env.get("HOME")) |h| if (h.len != 0) return try std.fmt.allocPrint(arena, "{s}/.config/commitflow/config", .{h});
    return null;
}

/// Local calendar date (so an evening in UTC-3 is still "today"); falls back to the UTC date.
fn todayEpochDay(arena: Allocator, io: Io) !i32 {
    if (std.process.run(arena, io, .{ .argv = &.{ "date", "+%F" } })) |r| {
        if (r.term.success()) {
            if (date.Date.parse(std.mem.trim(u8, r.stdout, " \n"))) |d| return d.toEpochDay() else |_| {}
        }
    } else |_| {}
    const now = Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s * std.time.s_per_day));
}

fn play(io: Io, env: *const std.process.Environ.Map, opts: *const Options, cal: *const calendar.Calendar, title: []const u8) !void {
    const stdout: Io.File = .stdout();
    const is_tty = try stdout.isTty(io);
    const no_color_env = if (env.get("NO_COLOR")) |v| v.len != 0 else false;
    const color = is_tty and !opts.no_color and !no_color_env;

    const sz = term.size();
    // Without a TTY (piped output, docs) COLUMNS picks the width, so a narrow frame can be captured.
    const env_cols: ?usize = if (env.get("COLUMNS")) |c| std.fmt.parseInt(usize, c, 10) catch null else null;
    const cols = if (sz) |s| s.cols else env_cols orelse 200;
    const cell_w: u8 = if (cols >= render.Renderer.minColumns(2) + 2) 2 else 1;
    if (cols < render.Renderer.minColumns(1)) {
        std.debug.print("commitflow: terminal too narrow ({d} columns, need {d})\n", .{ cols, render.Renderer.minColumns(1) });
        return error.TerminalTooSmall;
    }

    var animate = is_tty and !opts.static and opts.duration > 0;
    if (animate) if (sz) |s| if (s.rows <= render.line_count) {
        std.debug.print("commitflow: terminal too short to animate ({d} rows, need {d}); printing final frame\n", .{ s.rows, render.line_count + 1 });
        animate = false;
    };

    const r = render.Renderer.init(cal, cell_w, color, title);
    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(stdout, io, &buf);
    const w = &fw.interface;

    const total_days = cal.lastIndex() + 1;
    if (!animate) {
        try r.frame(w, total_days);
        try w.flush();
        return;
    }

    term.installCursorRestore();
    try w.writeAll(term.hide_cursor);
    defer {
        w.writeAll(term.show_cursor) catch {};
        w.flush() catch {};
    }

    const frames: usize = @max(1, @as(usize, @intFromFloat(@ceil(opts.duration * @as(f64, @floatFromInt(opts.fps))))));
    const frame_time: Io.Duration = .fromNanoseconds(@intCast(std.time.ns_per_s / opts.fps));
    for (0..frames + 1) |f| {
        const t = @as(f64, @floatFromInt(f)) / @as(f64, @floatFromInt(frames));
        const eased = t * t * (3 - 2 * t); // smoothstep: slow start, fast middle, slow finish
        const visible: usize = @intFromFloat(@round(eased * @as(f64, @floatFromInt(total_days))));
        if (f > 0) try w.print("\x1b[{d}A", .{render.line_count});
        try r.frame(w, if (f == frames) total_days else visible);
        try w.flush();
        if (f != frames) try io.sleep(frame_time, .awake);
    }
}

test {
    _ = @import("cache.zig");
    _ = @import("calendar.zig");
    _ = @import("config.zig");
    _ = @import("date.zig");
    _ = @import("demo.zig");
    _ = @import("render.zig");
    _ = @import("source.zig");
}
