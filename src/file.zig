//! FSearch whole-disk file search for the launcher.
//!
//! Talks to the installed `fsearch` CLI (`~/.local/bin/fsearch`), which owns
//! the index and daemon. Keyword: `f ` / `find ` / `file `. Return opens the
//! path through the host's `open` (same as Picemon hits).
const std = @import("std");

pub const max_rows = 8;
pub const max_path = 512;
pub const max_query = 120;

/// Alfred-like prefixes; longer ones first so `file` / `find` win over `f`.
pub const prefixes = [_][]const u8{ "find ", "file ", "f " };

/// When `query` is a file-search command, the needle (may be empty); else null.
pub fn take(query_in: []const u8) ?[]const u8 {
    const q = std.mem.trim(u8, query_in, " \t");
    for (prefixes) |p| {
        if (startsIgnoreCase(q, p)) return std.mem.trim(u8, q[p.len..], " \t");
    }
    if (eqlIgnoreCase(q, "find") or eqlIgnoreCase(q, "file") or eqlIgnoreCase(q, "f")) return "";
    return null;
}

pub const Hit = struct {
    path: [max_path]u8 = undefined,
    len: u16 = 0,
    is_dir: bool = false,

    pub fn slice(h: *const Hit) []const u8 {
        return h.path[0..h.len];
    }

    pub fn name(h: *const Hit) []const u8 {
        const p = h.slice();
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
            if (i + 1 < p.len) return p[i + 1 ..];
        }
        return p;
    }

    pub fn folder(h: *const Hit) []const u8 {
        const p = h.slice();
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
            const parent = p[0..i];
            if (std.mem.lastIndexOfScalar(u8, parent, '/')) |j| return parent[j + 1 ..];
            return parent;
        }
        return "";
    }
};

pub const List = struct {
    hits: [max_rows]Hit = undefined,
    n: usize = 0,

    pub fn clear(l: *List) void {
        l.n = 0;
    }

    pub fn get(l: *const List, i: usize) *const Hit {
        return &l.hits[i];
    }

    pub fn push(l: *List, path: []const u8, is_dir: bool) void {
        if (l.n == max_rows or path.len == 0 or path.len > max_path) return;
        for (0..l.n) |i| if (std.mem.eql(u8, l.hits[i].slice(), path)) return;
        @memcpy(l.hits[l.n].path[0..path.len], path);
        l.hits[l.n].len = @intCast(path.len);
        l.hits[l.n].is_dir = is_dir;
        l.n += 1;
    }
};

pub const bin_candidates_suffix = "/.local/bin/fsearch";
pub const bin_fallbacks = [_][]const u8{
    "/opt/homebrew/bin/fsearch",
    "/usr/local/bin/fsearch",
};

/// Absolute path to `fsearch` into `buf`, preferring `home/.local/bin`.
pub fn findBin(io: std.Io, buf: []u8, home: []const u8) []const u8 {
    if (home.len > 0) {
        const n = home.len + bin_candidates_suffix.len;
        if (n <= buf.len) {
            @memcpy(buf[0..home.len], home);
            @memcpy(buf[home.len..][0..bin_candidates_suffix.len], bin_candidates_suffix);
            const p = buf[0..n];
            if (std.Io.Dir.accessAbsolute(io, p, .{})) |_| return p else |_| {}
        }
    }
    for (bin_fallbacks) |c| {
        std.Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        if (c.len <= buf.len) {
            @memcpy(buf[0..c.len], c);
            return buf[0..c.len];
        }
    }
    return "";
}

/// FSearch is asked for this many, so `max_rows` remain once `wanted`
/// drops the noise.
pub const ask_rows = 32;

/// `needle` plus `limit:N` into `buf` for the CLI query.
pub fn cliQuery(buf: []u8, needle: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} limit:{d}", .{ needle, ask_rows }) catch "";
}

/// Where apps keep their own data: never what someone types `f` for, and
/// full of long generated names a fuzzy match catches by chance.
const noise = [_][]const u8{
    "/Library/Caches/",         "/Library/Application Support/", "/Library/Containers/",
    "/Library/Group Containers/", "/Library/Logs/",              "/Library/Saved Application State/",
    "/.Trash/",                 "/node_modules/",                "/.git/",
    "/.zig-cache/",             "/.cache/",                      "/DerivedData/",
};

/// Whether `path` is worth a row for `needle`: outside app data, and
/// holding every typed word (`key:value` filters aside), case aside.
pub fn wanted(path: []const u8, needle: []const u8) bool {
    for (noise) |n| if (std.mem.indexOf(u8, path, n) != null) return false;
    var words = std.mem.tokenizeAny(u8, needle, " \t");
    while (words.next()) |w| {
        if (std.mem.indexOfScalar(u8, w, ':') != null) continue;
        if (std.ascii.findIgnoreCase(path, w) == null) return false;
    }
    return true;
}

const JsonHit = struct {
    path: []const u8 = "",
    kind: []const u8 = "",
};

const JsonResp = struct {
    ok: bool = false,
    hits: []const JsonHit = &.{},
};

/// FSearch `--json` body into `out` (paths only; dirs flagged), keeping
/// only what `wanted` keeps for `needle`.
pub fn decode(out: *List, body: []const u8, needle: []const u8) void {
    out.clear();
    if (body.len == 0) return;
    // Stack arena: enough for a short hits list.
    var buf: [96 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSliceLeaky(JsonResp, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch return;
    if (!parsed.ok) return;
    for (parsed.hits) |h| {
        if (h.path.len == 0 or !wanted(h.path, needle)) continue;
        out.push(h.path, std.mem.eql(u8, h.kind, "dir"));
    }
}

/// Runs `fsearch --json <needle limit:N>`. Empty `needle` clears `out`.
pub fn search(gpa: std.mem.Allocator, io: std.Io, home: []const u8, needle_in: []const u8, out: *List) void {
    out.clear();
    const needle = std.mem.trim(u8, needle_in, " \t");
    if (needle.len == 0 or needle.len > max_query) return;

    var bin_buf: [512]u8 = undefined;
    const bin = findBin(io, &bin_buf, home);
    if (bin.len == 0) return;

    var q_buf: [max_query + 32]u8 = undefined;
    const q = cliQuery(&q_buf, needle);
    if (q.len == 0) return;

    const result = std.process.run(gpa, io, .{
        .argv = &.{ bin, "--json", q },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(4 * 1024),
        .create_no_window = true,
    }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    // FSearch prints JSON on stdout even when indexing (ok:false); decode handles it.
    decode(out, result.stdout, needle);
}

fn startsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "f/find/file prefixes" {
    const t = std.testing;
    try t.expectEqualStrings("Cargo.toml", take("f Cargo.toml").?);
    try t.expectEqualStrings("readme", take("FIND readme").?);
    try t.expectEqualStrings("main.zig", take("file main.zig").?);
    try t.expectEqualStrings("", take("find").?);
    try t.expectEqualStrings("", take("f").?);
    try t.expect(take("firefox") == null);
    try t.expect(take("saf") == null);
    // Longer prefix wins: "file x" is not "f ile x".
    try t.expectEqualStrings("x", take("file x").?);
}

test "cliQuery appends limit" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("readme limit:32", cliQuery(&buf, "readme"));
}

test "decode json hits" {
    var list: List = .{};
    decode(&list,
        \\{"hits":[{"kind":"file","path":"/Users/chris/a/one.txt","score":1},{"kind":"dir","path":"/Users/chris/a/two","score":2},{"kind":"file","path":"/Users/chris/a/one.txt","score":1}],"ok":true}
    , "a");
    try std.testing.expectEqual(@as(usize, 2), list.n);
    try std.testing.expectEqualStrings("/Users/chris/a/one.txt", list.get(0).slice());
    try std.testing.expect(!list.get(0).is_dir);
    try std.testing.expectEqualStrings("two", list.get(1).name());
    try std.testing.expectEqualStrings("a", list.get(1).folder());
    try std.testing.expect(list.get(1).is_dir);
    decode(&list, "{\"ok\":false,\"error\":\"indexing\"}", "a");
    try std.testing.expectEqual(@as(usize, 0), list.n);
}

test "app data and paths missing a typed word are dropped" {
    const t = std.testing;
    try t.expect(wanted("/Users/chris/code/README.md", "readme"));
    try t.expect(wanted("/Users/chris/Documents/Q3 Report.pdf", "q3 report"));
    try t.expect(wanted("/Users/chris/Documents/Q3 Report.pdf", "report ext:pdf"));
    try t.expect(!wanted("/Users/chris/Documents/Q3 Report.pdf", "q4 report"));
    try t.expect(!wanted("/Users/chris/Library/Application Support/Grok Bot/sand/onqw4zbomnwg.blob", "zzqxnotexist"));
    try t.expect(!wanted("/Users/chris/Library/Caches/readme.txt", "readme"));
    try t.expect(!wanted("/Users/chris/code/app/node_modules/x/README.md", "readme"));
}
