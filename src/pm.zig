//! Send a note to Chris's project-manager bot via the local outbox.
//! Keyword: `pm ` / `PM `. Return writes UTF-8 text under
//! `~/Library/Application Support/Nanolight/outbox/`; a Grok Bot routine
//! forwards it with SendToAgent. Nanolight itself does not talk to the bot.
const std = @import("std");

extern "c" fn time(t: ?*i64) i64;

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

/// Absolute outbox directory into `buf` (no trailing slash).
pub fn outboxDir(buf: []u8, home: []const u8) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/Nanolight/outbox", .{home}) catch "";
}

/// Writes `body` as UTF-8 into a new `pm-<unix>-<pid>.txt`. Returns the path
/// length written into `path_buf`, or 0 on failure / empty body.
pub fn writeOutbox(io: std.Io, home: []const u8, body_in: []const u8, path_buf: []u8) usize {
    const body = std.mem.trim(u8, body_in, " \t\r\n");
    if (home.len == 0 or body.len == 0 or body.len > max_body) return 0;
    var dir_buf: [512]u8 = undefined;
    const dir = outboxDir(&dir_buf, home);
    if (dir.len == 0) return 0;
    std.Io.Dir.cwd().createDirPath(io, dir) catch return 0;
    const now = time(null);
    const pid: u32 = @intCast(std.c.getpid());
    const path = std.fmt.bufPrint(path_buf, "{s}/pm-{d}-{d}.txt", .{ dir, now, pid }) catch return 0;
    var f = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return 0;
    defer f.close(io);
    f.writeStreamingAll(io, body) catch return 0;
    f.writeStreamingAll(io, "\n") catch {};
    return path.len;
}

/// Optional macOS banner; failures are ignored.
pub fn notify(gpa: std.mem.Allocator, io: std.Io) void {
    const script =
        \\display notification "已写入 outbox，等待转发" with title "发给项目经理"
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

test "outbox dir under Application Support" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/Users/chris/Library/Application Support/Nanolight/outbox",
        outboxDir(&buf, "/Users/chris"),
    );
}
