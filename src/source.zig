//! Commit sources. GitHub and GitLab are queried through the user's already-authenticated `gh` and
//! `glab` CLIs, so commitflow never handles tokens itself.
//!
//! * GitHub: GraphQL `contributionCalendar` (per-day contributions; GitHub exposes no per-day
//!   commit-only series, so PRs, issues and reviews are included).
//! * GitLab: the user's push events find their projects, then each project's commits are counted by
//!   author and authored date (commits only; merges excluded).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const calendar = @import("calendar.zig");
const date = @import("date.zig");
const cache = @import("cache.zig");

pub const me = "@me";
pub const default_gitlab_host = "gitlab.com";

pub const Source = union(enum) {
    github: struct { user: []const u8 },
    gitlab: struct { host: []const u8, user: []const u8 },

    /// `USER`, `HOST/USER` or `HOST/` (authenticated user on HOST). `@me` is accepted as USER.
    pub fn parseGitlab(spec: []const u8) Source {
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
            const user = spec[slash + 1 ..];
            return .{ .gitlab = .{ .host = spec[0..slash], .user = if (user.len == 0) me else user } };
        }
        return .{ .gitlab = .{ .host = default_gitlab_host, .user = spec } };
    }

    /// "github.com" / "gitlab.example.org", plus the user unless it is the authenticated one.
    pub fn label(self: Source, arena: Allocator) Allocator.Error![]const u8 {
        return switch (self) {
            .github => |g| if (std.mem.eql(u8, g.user, me)) "github.com" else std.fmt.allocPrint(arena, "github.com/{s}", .{g.user}),
            .gitlab => |g| if (std.mem.eql(u8, g.user, me)) g.host else std.fmt.allocPrint(arena, "{s}/{s}", .{ g.host, g.user }),
        };
    }
};

pub const FetchError = error{ SourceFailed, BadResponse } || Allocator.Error;

pub const CacheConfig = struct {
    /// Directory for cache files; null disables caching.
    dir: ?[]const u8 = null,
    /// Ignore existing cache files (they are still rewritten).
    refresh: bool = false,
};

/// Adds the source's per-day counts to `cal`. Returns the number of commits/contributions added.
/// On failure the reason is printed to stderr and `error.SourceFailed` is returned.
pub fn fetch(gpa: Allocator, arena: Allocator, io: Io, cc: CacheConfig, src: Source, cal: *calendar.Calendar) FetchError!u64 {
    return switch (src) {
        .github => |g| fetchGithub(arena, io, g.user, cal),
        .gitlab => |g| fetchGitlab(gpa, arena, io, cc, g.host, g.user, cal),
    };
}

// ---------------------------------------------------------------- process

const cli_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(25), .clock = .awake } };

/// Runs `argv`, returning stdout. A non-zero exit, timeout or missing binary yields
/// `error.SourceFailed`, after printing a one-line reason to stderr unless `quiet`.
pub fn capture(arena: Allocator, io: Io, argv: []const []const u8, quiet: bool) FetchError![]const u8 {
    const result = std.process.run(arena, io, .{ .argv = argv, .timeout = cli_timeout }) catch |err| {
        if (!quiet) switch (err) {
            error.Timeout => std.debug.print("  {s}: timed out after 25s (host unreachable? VPN?)\n", .{argv[0]}),
            error.FileNotFound => std.debug.print("  {s}: not found in PATH\n", .{argv[0]}),
            else => std.debug.print("  {s}: {s}\n", .{ argv[0], @errorName(err) }),
        };
        return error.SourceFailed;
    };
    if (!result.term.success()) {
        if (!quiet) {
            const msg = std.mem.trim(u8, result.stderr, " \r\n\t");
            var line = if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| msg[0..nl] else msg;
            if (std.mem.startsWith(u8, line, argv[0])) line = std.mem.trimStart(u8, line[argv[0].len..], ": ");
            std.debug.print("  {s}: {s}\n", .{ argv[0], if (line.len == 0) "failed" else line });
        }
        return error.SourceFailed;
    }
    return result.stdout;
}

// ---------------------------------------------------------------- github

const gh_query_viewer =
    \\query($from:DateTime!,$to:DateTime!){viewer{contributionsCollection(from:$from,to:$to){contributionCalendar{weeks{contributionDays{date contributionCount}}}}}}
;
const gh_query_user =
    \\query($login:String!,$from:DateTime!,$to:DateTime!){user(login:$login){contributionsCollection(from:$from,to:$to){contributionCalendar{weeks{contributionDays{date contributionCount}}}}}}
;

/// GitHub rejects ranges longer than one year, and our window is 53 weeks.
const github_chunk_days = 180;

fn fetchGithub(arena: Allocator, io: Io, user: []const u8, cal: *calendar.Calendar) FetchError!u64 {
    var total: u64 = 0;
    var from = cal.start;
    while (from <= cal.end) {
        const to = @min(from + github_chunk_days - 1, cal.end);
        const from_arg = try std.fmt.allocPrint(arena, "from={f}T00:00:00Z", .{date.Date.fromEpochDay(from)});
        const to_arg = try std.fmt.allocPrint(arena, "to={f}T23:59:59Z", .{date.Date.fromEpochDay(to)});
        const query_arg = try std.fmt.allocPrint(arena, "query={s}", .{if (isMe(user)) gh_query_viewer else gh_query_user});

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "gh", "api", "graphql", "-f", query_arg, "-f", from_arg, "-f", to_arg });
        if (!isMe(user)) try argv.appendSlice(arena, &.{ "-f", try std.fmt.allocPrint(arena, "login={s}", .{user}) });

        const body = try capture(arena, io, argv.items, false);
        total += parseGithubCalendar(arena, body, cal) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.SourceFailed;
        };
        from = to + 1;
    }
    return total;
}

const GhDay = struct { date: []const u8, contributionCount: u32 };
const GhWeek = struct { contributionDays: []const GhDay };
const GhUser = struct { contributionsCollection: struct { contributionCalendar: struct { weeks: []const GhWeek } } };
const GhError = struct { message: []const u8 = "" };
const GhResponse = struct {
    data: ?struct { viewer: ?GhUser = null, user: ?GhUser = null } = null,
    errors: ?[]const GhError = null,
};

/// Parses a `gh api graphql` response and adds each day's count to `cal`.
pub fn parseGithubCalendar(arena: Allocator, body: []const u8, cal: *calendar.Calendar) !u64 {
    const resp = std.json.parseFromSliceLeaky(GhResponse, arena, body, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("  github: unexpected response\n", .{});
        return error.BadResponse;
    };
    if (resp.errors) |errs| {
        if (errs.len > 0) std.debug.print("  github: {s}\n", .{errs[0].message});
    }
    const data = resp.data orelse return error.BadResponse;
    const user = data.viewer orelse data.user orelse {
        std.debug.print("  github: user not found\n", .{});
        return error.BadResponse;
    };
    var added: u64 = 0;
    for (user.contributionsCollection.contributionCalendar.weeks) |week| {
        for (week.contributionDays) |day| {
            const d = date.Date.parse(day.date) catch continue;
            cal.add(d.toEpochDay(), day.contributionCount);
            added += day.contributionCount;
        }
    }
    return added;
}

// ---------------------------------------------------------------- gitlab
//
// `push_data.commit_count` on "created branch" events carries the branch's whole history (hundreds
// of commits for one push), so push events are only used to discover which projects the user
// pushes to. The commits themselves are then listed per project and counted by author and
// `authored_date`, merges excluded, each SHA once.

const gitlab_page_size = 100;
const gitlab_max_pages = 1000;

const GlProfile = struct {
    id: u64,
    name: []const u8 = "",
    username: []const u8 = "",
    email: ?[]const u8 = null,
    commit_email: ?[]const u8 = null,
    public_email: ?[]const u8 = null,
};
const GlEmail = struct { email: []const u8 };

/// Who counts as "me" in a project's commit list.
pub const Identity = struct {
    id: u64 = 0,
    names: []const []const u8,
    emails: []const []const u8,

    pub fn matches(self: Identity, name: []const u8, email: []const u8) bool {
        for (self.emails) |e| if (std.ascii.eqlIgnoreCase(e, email)) return true;
        for (self.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

/// Cached path: one probe (the newest push event id) decides whether anything changed. Any change,
/// an expired or too-narrow cache, or `--refresh` falls through to a full scan, which rewrites the
/// cache. Counts go into a private calendar so the cache never contains other sources' data.
fn fetchGitlab(gpa: Allocator, arena: Allocator, io: Io, cc: CacheConfig, host: []const u8, user: []const u8, cal: *calendar.Calendar) FetchError!u64 {
    const cache_path: ?[]const u8 = if (cc.dir) |d|
        try cache.pathFor(arena, d, try std.fmt.allocPrint(arena, "gitlab_{s}_{s}", .{ host, user }))
    else
        null;
    const today = cache.utcToday(io);

    if (!cc.refresh) if (cache_path) |p| if (try cache.load(arena, io, p)) |entry| {
        if (try gitlabCacheHit(arena, io, host, user, entry, cal, today)) |total| return total;
    };

    const ident = try gitlabIdentity(arena, io, host, user);

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    var own = calendar.Calendar.init(cal.end);

    // `after`/`before` are exclusive.
    const after = date.Date.fromEpochDay(own.start - 1);
    const before = date.Date.fromEpochDay(own.end + 1);

    // 1. Projects the user pushed to in the window.
    var projects: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    var latest_event: u64 = 0;
    var page: u32 = 1;
    while (page <= gitlab_max_pages) : (page += 1) {
        _ = scratch.reset(.retain_capacity);
        const endpoint = try std.fmt.allocPrint(
            scratch.allocator(),
            "users/{d}/events?action=pushed&after={f}&before={f}&per_page={d}&page={d}",
            .{ ident.id, after, before, gitlab_page_size, page },
        );
        const body = try capture(scratch.allocator(), io, &.{ "glab", "api", "--hostname", host, endpoint }, false);
        const r = parseGitlabProjects(scratch.allocator(), arena, body, &projects) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.SourceFailed;
        };
        if (page == 1) latest_event = r.max_id; // newest first; read before the commit scan starts
        if (r.events < gitlab_page_size) break;
    }
    std.debug.print("  {d} projects with pushes\n", .{projects.count()});

    // 2. Commits by this user in each project.
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    var total: u64 = 0;
    var skipped: usize = 0;
    for (projects.keys()) |project_id| {
        total += gitlabProjectCommits(gpa, &scratch, io, host, project_id, ident, after, before, &seen, &own) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SourceFailed, error.BadResponse => {
                skipped += 1;
                continue;
            },
        };
    }
    if (skipped != 0) std.debug.print("  skipped {d} projects (no access, deleted or unreadable)\n", .{skipped});

    // A partial scan must not be cached as if it were complete.
    if (cache_path) |p| if (skipped == 0) {
        cache.save(arena, io, p, cache.Entry.fromCalendar(ident.id, latest_event, today, &own)) catch |err| {
            std.debug.print("  cache: could not write {s}: {s}\n", .{ p, @errorName(err) });
        };
    };

    cal.merge(&own);
    return total;
}

/// Returns the cached total if nothing changed upstream, null if a full scan is needed.
fn gitlabCacheHit(arena: Allocator, io: Io, host: []const u8, user: []const u8, entry: cache.Entry, cal: *calendar.Calendar, today: i32) FetchError!?u64 {
    if (!entry.usableFor(cal, today)) {
        std.debug.print("  cache expired or does not cover this window; rescanning\n", .{});
        return null;
    }
    if (isMe(user)) {
        // Logging in as someone else on the same host must not reuse the previous account's counts.
        const body = try capture(arena, io, &.{ "glab", "api", "--hostname", host, "user" }, false);
        const p = std.json.parseFromSliceLeaky(GlProfile, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
        if (p.id != entry.user_id) return null;
    }
    const endpoint = try std.fmt.allocPrint(arena, "users/{d}/events?action=pushed&per_page=1", .{entry.user_id});
    const body = try capture(arena, io, &.{ "glab", "api", "--hostname", host, endpoint }, false);
    var ignored: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    const page = parseGitlabProjects(arena, arena, body, &ignored) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.SourceFailed;
    };
    if (page.max_id != entry.last_event_id) {
        std.debug.print("  new pushes since the last scan; rescanning\n", .{});
        return null;
    }
    std.debug.print("  cache hit: no new pushes\n", .{});
    return entry.applyTo(cal);
}

fn gitlabProjectCommits(
    gpa: Allocator,
    scratch: *std.heap.ArenaAllocator,
    io: Io,
    host: []const u8,
    project_id: u64,
    ident: Identity,
    after: date.Date,
    before: date.Date,
    seen: *std.AutoHashMapUnmanaged(u64, void),
    cal: *calendar.Calendar,
) FetchError!u64 {
    var total: u64 = 0;
    var page: u32 = 1;
    while (page <= gitlab_max_pages) : (page += 1) {
        _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        const endpoint = try std.fmt.allocPrint(
            a,
            "projects/{d}/repository/commits?all=true&since={f}T00:00:00Z&until={f}T23:59:59Z&per_page={d}&page={d}",
            .{ project_id, after, before, gitlab_page_size, page },
        );
        const body = try capture(a, io, &.{ "glab", "api", "--hostname", host, endpoint }, true);
        const r = try countGitlabCommits(gpa, a, body, ident, seen, cal);
        total += r.counted;
        if (r.listed < gitlab_page_size) break;
    }
    return total;
}

/// Resolves the target user's id plus every name/email their commits may carry.
fn gitlabIdentity(arena: Allocator, io: Io, host: []const u8, user: []const u8) FetchError!Identity {
    // The authenticated account: needed for `@me`, and its verified emails (`user/emails`) are only
    // visible when it is the target.
    const self_body: ?[]const u8 = capture(arena, io, &.{ "glab", "api", "--hostname", host, "user" }, !isMe(user)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SourceFailed, error.BadResponse => if (isMe(user)) return error.SourceFailed else null,
    };
    const self_profile: ?GlProfile = if (self_body) |b|
        std.json.parseFromSliceLeaky(GlProfile, arena, b, .{ .ignore_unknown_fields = true }) catch null
    else
        null;

    var target: GlProfile = undefined;
    if (isMe(user)) {
        target = self_profile orelse {
            std.debug.print("  gitlab: unexpected response for authenticated user\n", .{});
            return error.SourceFailed;
        };
    } else {
        const endpoint = try std.fmt.allocPrint(arena, "users?username={s}", .{user});
        const body = try capture(arena, io, &.{ "glab", "api", "--hostname", host, endpoint }, false);
        const users = std.json.parseFromSliceLeaky([]const GlProfile, arena, body, .{ .ignore_unknown_fields = true }) catch {
            std.debug.print("  gitlab: unexpected response looking up user\n", .{});
            return error.SourceFailed;
        };
        if (users.len == 0) {
            std.debug.print("  gitlab: user '{s}' not found on {s}\n", .{ user, host });
            return error.SourceFailed;
        }
        target = users[0];
    }

    var names: std.ArrayList([]const u8) = .empty;
    var emails: std.ArrayList([]const u8) = .empty;
    try addNonEmpty(arena, &names, target.name);
    try addNonEmpty(arena, &names, target.username);
    try addNonEmpty(arena, &emails, target.email);
    try addNonEmpty(arena, &emails, target.commit_email);
    try addNonEmpty(arena, &emails, target.public_email);

    if (self_profile) |sp| if (sp.id == target.id) {
        try addNonEmpty(arena, &emails, sp.email);
        try addNonEmpty(arena, &emails, sp.commit_email);
        try addNonEmpty(arena, &emails, sp.public_email);
        if (capture(arena, io, &.{ "glab", "api", "--hostname", host, "user/emails" }, true)) |body| {
            if (std.json.parseFromSliceLeaky([]const GlEmail, arena, body, .{ .ignore_unknown_fields = true })) |list| {
                for (list) |e| try addNonEmpty(arena, &emails, e.email);
            } else |_| {}
        } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    };

    if (emails.items.len == 0) {
        std.debug.print("  gitlab: no emails known for '{s}'; matching commits by author name only\n", .{target.username});
    }
    return .{ .id = target.id, .names = names.items, .emails = emails.items };
}

fn addNonEmpty(arena: Allocator, list: *std.ArrayList([]const u8), s: anytype) Allocator.Error!void {
    const v: []const u8 = if (@typeInfo(@TypeOf(s)) == .optional) (s orelse return) else s;
    if (v.len == 0) return;
    for (list.items) |existing| if (std.ascii.eqlIgnoreCase(existing, v)) return;
    try list.append(arena, v);
}

const GlEvent = struct { id: u64 = 0, project_id: ?u64 = null };

pub const EventPage = struct { events: usize, max_id: u64 };

/// Adds the project ids of one page of `users/:id/events` to `projects`. Returns the page's event
/// count and its highest event id (GitLab ids grow over time; 0 for an empty page).
pub fn parseGitlabProjects(
    scratch: Allocator,
    arena: Allocator,
    body: []const u8,
    projects: *std.AutoArrayHashMapUnmanaged(u64, void),
) !EventPage {
    const events = std.json.parseFromSliceLeaky([]const GlEvent, scratch, body, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("  gitlab: unexpected events response\n", .{});
        return error.BadResponse;
    };
    var max_id: u64 = 0;
    for (events) |ev| {
        max_id = @max(max_id, ev.id);
        if (ev.project_id) |id| try projects.put(arena, id, {});
    }
    return .{ .events = events.len, .max_id = max_id };
}

const GlCommit = struct {
    id: []const u8,
    authored_date: []const u8,
    author_name: []const u8 = "",
    author_email: []const u8 = "",
    parent_ids: []const []const u8 = &.{},
};

pub const CommitPage = struct { listed: usize, counted: u64 };

/// Counts one page of `projects/:id/repository/commits`: the user's own, non-merge commits that
/// were not seen before, on their `authored_date` (author's local day).
pub fn countGitlabCommits(
    gpa: Allocator,
    scratch: Allocator,
    body: []const u8,
    ident: Identity,
    seen: *std.AutoHashMapUnmanaged(u64, void),
    cal: *calendar.Calendar,
) !CommitPage {
    const commits = std.json.parseFromSliceLeaky([]const GlCommit, scratch, body, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("  gitlab: unexpected commits response\n", .{});
        return error.BadResponse;
    };
    var counted: u64 = 0;
    for (commits) |c| {
        if (c.parent_ids.len > 1) continue;
        if (!ident.matches(c.author_name, c.author_email)) continue;
        const d = date.Date.parse(c.authored_date) catch continue;
        const gop = try seen.getOrPut(gpa, std.hash.Wyhash.hash(0, c.id));
        if (gop.found_existing) continue;
        if (cal.indexOf(d.toEpochDay()) == null) continue;
        cal.add(d.toEpochDay(), 1);
        counted += 1;
    }
    return .{ .listed = commits.len, .counted = counted };
}

fn isMe(user: []const u8) bool {
    return std.mem.eql(u8, user, me);
}

test "parseGitlab spec" {
    const a = Source.parseGitlab("alice");
    try std.testing.expectEqualStrings("gitlab.com", a.gitlab.host);
    try std.testing.expectEqualStrings("alice", a.gitlab.user);
    const b = Source.parseGitlab("git.example.org/bruno");
    try std.testing.expectEqualStrings("git.example.org", b.gitlab.host);
    try std.testing.expectEqualStrings("bruno", b.gitlab.user);
    const c = Source.parseGitlab("git.example.org/");
    try std.testing.expectEqualStrings("@me", c.gitlab.user);
}

test "parse github calendar (viewer and user shapes)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var cal = calendar.Calendar.init(end);

    const viewer =
        \\{"data":{"viewer":{"contributionsCollection":{"contributionCalendar":{"weeks":[
        \\ {"contributionDays":[{"date":"2026-11-06","contributionCount":3},{"date":"2026-11-07","contributionCount":0}]}]}}}}}
    ;
    try std.testing.expectEqual(@as(u64, 3), try parseGithubCalendar(arena, viewer, &cal));
    const user =
        \\{"data":{"user":{"contributionsCollection":{"contributionCalendar":{"weeks":[
        \\ {"contributionDays":[{"date":"2026-11-06","contributionCount":2},{"date":"2020-01-01","contributionCount":50}]}]}}}}}
    ;
    _ = try parseGithubCalendar(arena, user, &cal);
    try std.testing.expectEqual(@as(u32, 5), cal.counts[cal.indexOf(end - 1).?]);
    // Out-of-window day is ignored by the calendar.
    try std.testing.expectEqual(@as(u64, 5), cal.stats().total);
}

test "parse github error responses" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var cal = calendar.Calendar.init(20000);
    try std.testing.expectError(error.BadResponse, parseGithubCalendar(arena_state.allocator(), "{\"data\":{\"user\":null},\"errors\":[{\"message\":\"Could not resolve to a User\"}]}", &cal));
    try std.testing.expectError(error.BadResponse, parseGithubCalendar(arena_state.allocator(), "not json", &cal));
}

test "gitlab: project discovery from push events" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var projects: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    const body =
        \\[{"id":900,"project_id":241,"push_data":{"commit_count":622,"action":"created"}},
        \\ {"id":700,"project_id":241,"push_data":{"commit_count":2,"action":"pushed"}},
        \\ {"id":300,"project_id":257,"push_data":{"commit_count":1}}]
    ;
    const page = try parseGitlabProjects(arena, arena, body, &projects);
    try std.testing.expectEqual(@as(usize, 3), page.events);
    try std.testing.expectEqual(@as(u64, 900), page.max_id); // what the cache probe compares
    try std.testing.expectEqual(@as(usize, 2), projects.count());
    try std.testing.expect(projects.contains(241) and projects.contains(257));

    // No pushes at all: id 0, which a cache entry for an idle account also stores.
    const empty = try parseGitlabProjects(arena, arena, "[]", &projects);
    try std.testing.expectEqual(@as(usize, 0), empty.events);
    try std.testing.expectEqual(@as(u64, 0), empty.max_id);
}

test "gitlab: commits are counted by author, not by push size, merges and duplicates excluded" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const end = (try date.Date.parse("2026-11-07")).toEpochDay();
    var cal = calendar.Calendar.init(end);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    const ident: Identity = .{ .names = &.{"Bruno Costa dos Passos"}, .emails = &.{"Me@Example.com"} };

    const body =
        \\[{"id":"a1","authored_date":"2026-11-06T23:30:00.000-03:00","author_name":"bcosta19","author_email":"me@example.com","parent_ids":["p"]},
        \\ {"id":"a2","authored_date":"2026-11-06T09:00:00.000-03:00","author_name":"Bruno Costa dos Passos","author_email":"other@x.org","parent_ids":["p"]},
        \\ {"id":"a3","authored_date":"2026-11-06T10:00:00.000-03:00","author_name":"Someone Else","author_email":"else@x.org","parent_ids":["p"]},
        \\ {"id":"a4","authored_date":"2026-11-06T11:00:00.000-03:00","author_name":"bcosta19","author_email":"me@example.com","parent_ids":["p","q"]},
        \\ {"id":"a1","authored_date":"2026-11-06T23:30:00.000-03:00","author_name":"bcosta19","author_email":"me@example.com","parent_ids":["p"]},
        \\ {"id":"a5","authored_date":"2019-01-01T11:00:00.000-03:00","author_name":"bcosta19","author_email":"me@example.com","parent_ids":[]}]
    ;
    const page = try countGitlabCommits(std.testing.allocator, arena, body, ident, &seen, &cal);
    try std.testing.expectEqual(@as(usize, 6), page.listed);
    // a1 (email, case-insensitive) and a2 (name) count; a3 other author; a4 merge; dup a1; a5 out of window.
    try std.testing.expectEqual(@as(u64, 2), page.counted);
    try std.testing.expectEqual(@as(u32, 2), cal.counts[cal.indexOf(end - 1).?]);

    // Same SHA in another project (fork/mirror) is not counted twice.
    const again = try countGitlabCommits(std.testing.allocator, arena, body, ident, &seen, &cal);
    try std.testing.expectEqual(@as(u64, 0), again.counted);
}
