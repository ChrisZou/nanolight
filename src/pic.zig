//! Picemon image search for the launcher.
//!
//! Picemon has no public CLI, URL scheme, or AppleScript hook (confirmed in
//! its app binary / Info.plist / README). Its searchable index lives in
//! `~/Library/Application Support/Picemon/picemon.db`. This module queries
//! that SQLite file through `/usr/bin/sqlite3` for OCR text, AI descriptions,
//! tags, and paths — a keyword subset of Picemon's in-app search, not a
//! reimplementation of semantic / jieba ranking.
const std = @import("std");

pub const max_rows = 8;
pub const max_path = 512;
pub const max_query = 120;
pub const max_sql = 1024;

/// Alfred-like prefixes; the rest of the query is the needle.
pub const prefixes = [_][]const u8{ "img ", "pic " };

/// When `query` is an image-search command, the needle (may be empty for a
/// bare `img` / `pic` with no words yet); otherwise null.
pub fn take(query_in: []const u8) ?[]const u8 {
    const q = std.mem.trim(u8, query_in, " \t");
    for (prefixes) |p| {
        if (startsIgnoreCase(q, p)) return std.mem.trim(u8, q[p.len..], " \t");
    }
    if (eqlIgnoreCase(q, "img") or eqlIgnoreCase(q, "pic")) return "";
    return null;
}

pub const Hit = struct {
    path: [max_path]u8 = undefined,
    len: u16 = 0,

    pub fn slice(h: *const Hit) []const u8 {
        return h.path[0..h.len];
    }

    pub fn name(h: *const Hit) []const u8 {
        const p = h.slice();
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
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

    pub fn push(l: *List, path: []const u8) void {
        if (l.n == max_rows or path.len == 0 or path.len > max_path) return;
        for (0..l.n) |i| if (std.mem.eql(u8, l.hits[i].slice(), path)) return;
        @memcpy(l.hits[l.n].path[0..path.len], path);
        l.hits[l.n].len = @intCast(path.len);
        l.n += 1;
    }
};

/// `home/Library/Application Support/Picemon/picemon.db` into `buf`.
pub fn dbPath(buf: []u8, home: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/Picemon/picemon.db", .{home}) catch "";
}

/// LIKE-escapes `needle` into `esc`, then builds the SELECT into `buf`.
pub fn sql(buf: []u8, esc: []u8, needle: []const u8) []const u8 {
    const e = escapeLike(esc, needle);
    if (e.len == 0) return "";
    return std.fmt.bufPrint(buf,
        \\SELECT i.path FROM images i JOIN analyses a ON a.hash = i.hash
        \\WHERE a.ocr_text LIKE '%{s}%' ESCAPE '\'
        \\   OR a.description LIKE '%{s}%' ESCAPE '\'
        \\   OR a.tags LIKE '%{s}%' ESCAPE '\'
        \\   OR i.path LIKE '%{s}%' ESCAPE '\'
        \\LIMIT {d};
    , .{ e, e, e, e, max_rows }) catch "";
}

/// sqlite3's one-path-per-line stdout into `out`.
pub fn decode(out: *List, body: []const u8) void {
    out.clear();
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;
        out.push(path);
    }
}

/// Runs `/usr/bin/sqlite3` against Picemon's DB. Empty `needle` clears `out`.
pub fn search(gpa: std.mem.Allocator, io: std.Io, home: []const u8, needle_in: []const u8, out: *List) void {
    out.clear();
    const needle = std.mem.trim(u8, needle_in, " \t");
    if (needle.len == 0 or needle.len > max_query or home.len == 0) return;

    var path_buf: [512]u8 = undefined;
    const db = dbPath(&path_buf, home);
    if (db.len == 0) return;

    var esc_buf: [max_query * 2]u8 = undefined;
    var sql_buf: [max_sql]u8 = undefined;
    const q = sql(&sql_buf, &esc_buf, needle);
    if (q.len == 0) return;

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/sqlite3", db, q },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4 * 1024),
        .create_no_window = true,
    }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) return;
    decode(out, result.stdout);
}

fn escapeLike(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n + 2 > buf.len) break;
        switch (ch) {
            '\'' => {
                buf[n] = '\'';
                n += 1;
                buf[n] = '\'';
                n += 1;
            },
            '\\', '%', '_' => {
                buf[n] = '\\';
                n += 1;
                buf[n] = ch;
                n += 1;
            },
            0...0x1f, 0x7f => {},
            else => {
                buf[n] = ch;
                n += 1;
            },
        }
    }
    return buf[0..n];
}

fn startsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "img/pic prefixes" {
    const t = std.testing;
    try t.expectEqualStrings("羽毛球", take("img 羽毛球").?);
    try t.expectEqualStrings("coffee", take("PIC coffee").?);
    try t.expectEqualStrings("", take("img").?);
    try t.expect(take("image coffee") == null);
    try t.expect(take("saf") == null);
}

test "sql escapes quotes and LIKE metacharacters" {
    var esc: [64]u8 = undefined;
    var buf: [max_sql]u8 = undefined;
    const q = sql(&buf, &esc, "a'b%c_d");
    try std.testing.expect(std.mem.indexOf(u8, q, "a''b\\%c\\_d") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "LIMIT 8") != null);
}

test "decode paths" {
    var list: List = .{};
    decode(&list, "/a/one.png\n/b/two.jpg\n\n/a/one.png\n");
    try std.testing.expectEqual(@as(usize, 2), list.n);
    try std.testing.expectEqualStrings("/a/one.png", list.get(0).slice());
    try std.testing.expectEqualStrings("two.jpg", list.get(1).name());
    try std.testing.expectEqualStrings("b", list.get(1).folder());
}
