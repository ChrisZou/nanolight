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

/// POST `body_in` to the project-manager webhook. Returns true on HTTP 2xx.
pub fn postWebhook(gpa: std.mem.Allocator, io: std.Io, home: []const u8, body_in: []const u8) bool {
    const body = std.mem.trim(u8, body_in, " \t\r\n");
    if (home.len == 0 or body.len == 0 or body.len > max_body) return false;

    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf, home);
    if (path.len == 0) return false;

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024)) catch return false;
    defer gpa.free(raw);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const Config = struct { url: []const u8, key: []const u8 };
    const cfg = std.json.parseFromSliceLeaky(Config, arena.allocator(), raw, .{ .ignore_unknown_fields = true }) catch return false;
    if (cfg.url.len == 0 or !std.mem.startsWith(u8, cfg.url, "https://")) return false;
    if (cfg.key.len == 0) return false;

    const key = stripCrLf(cfg.key);
    if (key.len == 0) return false;

    const auth = if (std.mem.startsWith(u8, key, "Bearer "))
        key
    else
        std.fmt.allocPrint(arena.allocator(), "Bearer {s}", .{key}) catch return false;

    const Payload = struct { text: []const u8 };
    const json = std.json.Stringify.valueAlloc(gpa, Payload{ .text = body }, .{}) catch return false;
    defer gpa.free(json);

    const auth_header = std.fmt.allocPrint(gpa, "Authorization: {s}", .{auth}) catch return false;
    defer gpa.free(auth_header);

    const argv = [_][]const u8{
        "/usr/bin/curl",
        "-sS",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "-X",
        "POST",
        cfg.url,
        "-H",
        auth_header,
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        json,
    };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(1024),
        .create_no_window = true,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const code_s = std.mem.trim(u8, result.stdout, " \t\r\n");
    const code = std.fmt.parseInt(u16, code_s, 10) catch return false;
    return code >= 200 and code < 300;
}

/// Optional macOS banner; failures are ignored.
pub fn notify(gpa: std.mem.Allocator, io: std.Io, ok: bool) void {
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
