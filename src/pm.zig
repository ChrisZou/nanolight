//! Send a note to Chris's 项目经理 Grok Bot via its webhook.
//! Keyword: `pm ` / `PM `. Return POSTs JSON `{"text":…}` using URL/key from
//! `~/Library/Application Support/Nanolight/pm-webhook.json` (not in the repo).
const std = @import("std");

pub const max_body = 2000;
pub const prefixes = [_][]const u8{ "pm ", "PM " };

/// When `query` is a PM command, the body (may be empty); else null.
pub fn take(query_in: []const u8) ?[]const u8 {
    const q = std.mem.trim(u8, query_in, " \t");
    for (prefixes) |p| {
        if (startsIgnoreCase(q, p)) return std.mem.trim(u8, q[p.len..], " \t");
    }
    if (eqlIgnoreCase(q, "pm")) return "";
    return null;
}

/// Absolute webhook config path into `buf`.
pub fn configPath(buf: []u8, home: []const u8) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/Nanolight/pm-webhook.json", .{home}) catch "";
}

/// Seconds the webhook gets before the note counts as failed.
pub const timeout_s: f64 = 10;

/// What a POST to the webhook needs, owned by `arena`.
pub const Post = struct {
    url: []const u8,
    auth: []const u8,
    json: []const u8,
};

/// Reads the webhook config and builds the POST for `body_in` into
/// `arena`. Null when the note is empty or too long, or the config is
/// missing or not https.
pub fn prepare(arena: std.mem.Allocator, io: std.Io, home: []const u8, body_in: []const u8) ?Post {
    const body = std.mem.trim(u8, body_in, " \t\r\n");
    if (home.len == 0 or body.len == 0 or body.len > max_body) return null;

    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf, home);
    if (path.len == 0) return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024)) catch return null;
    return fromConfig(arena, raw, body);
}

/// `prepare` past reading the file: the config's JSON and the note.
pub fn fromConfig(arena: std.mem.Allocator, raw: []const u8, body: []const u8) ?Post {
    const Config = struct { url: []const u8, key: []const u8 };
    const cfg = std.json.parseFromSliceLeaky(Config, arena, raw, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.startsWith(u8, cfg.url, "https://")) return null;
    const key = stripCrLf(cfg.key);
    if (key.len == 0) return null;
    const auth = if (std.mem.startsWith(u8, key, "Bearer "))
        key
    else
        std.fmt.allocPrint(arena, "Bearer {s}", .{key}) catch return null;
    const Payload = struct { text: []const u8 };
    const json = std.json.Stringify.valueAlloc(arena, Payload{ .text = body }, .{}) catch return null;
    return .{ .url = cfg.url, .auth = auth, .json = json };
}

/// A macOS banner saying whether it went, from a thread of its own (the
/// panel never waits on osascript); failures are ignored.
pub fn notify(gpa: std.mem.Allocator, io: std.Io, ok: bool) void {
    const t = std.Thread.spawn(.{}, notifyNow, .{ gpa, io, ok }) catch return;
    t.detach();
}

fn notifyNow(gpa: std.mem.Allocator, io: std.Io, ok: bool) void {
    const script = if (ok)
        \\display notification "已发送" with title "发给项目经理"
    else
        \\display notification "发送失败" with title "发给项目经理"
    ;
    const argv = [_][]const u8{ "/usr/bin/osascript", "-e", script };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
        .create_no_window = true,
    }) catch return;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

fn stripCrLf(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn startsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "pm prefixes" {
    const t = std.testing;
    try t.expectEqualStrings("推进 Nanolight", take("pm 推进 Nanolight").?);
    try t.expectEqualStrings("hello", take("PM hello").?);
    try t.expectEqualStrings("", take("pm").?);
    try t.expectEqualStrings("", take("PM").?);
    try t.expect(take("pms") == null);
    try t.expect(take("p m hi") == null);
}

test "config path under Application Support" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/Users/chris/Library/Application Support/Nanolight/pm-webhook.json",
        configPath(&buf, "/Users/chris"),
    );
}

test "a webhook POST carries the note as JSON and the key as a Bearer token" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const post = fromConfig(a, "{\"url\":\"https://example.com/hook\",\"key\":\"abc\\n\"}", "say \"hi\"").?;
    try std.testing.expectEqualStrings("https://example.com/hook", post.url);
    try std.testing.expectEqualStrings("Bearer abc", post.auth);
    try std.testing.expectEqualStrings("{\"text\":\"say \\\"hi\\\"\"}", post.json);
    try std.testing.expectEqualStrings("Bearer xyz", fromConfig(a, "{\"url\":\"https://e.com\",\"key\":\"Bearer xyz\"}", "x").?.auth);
    // Plain http, or no key: nothing is sent.
    try std.testing.expect(fromConfig(a, "{\"url\":\"http://e.com\",\"key\":\"k\"}", "x") == null);
    try std.testing.expect(fromConfig(a, "{\"url\":\"https://e.com\",\"key\":\" \"}", "x") == null);
}
