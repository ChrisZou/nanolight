//! Send a note to one of Chris's Grok Bots via its webhook.
//! Keywords: `pm ` (项目经理), `af ` (Alfred) and `gb ` (Grok Bot). Return POSTs JSON
//! `{"text":…}` using URL/key from
//! `~/Library/Application Support/Nanolight/<bot>-webhook.json` (not in the repo).
const std = @import("std");

pub const max_body = 2000;

/// The bots a note can go to.
pub const Bot = enum {
    /// 项目经理 (`pm `).
    pm,
    /// Alfred (`af `).
    af,
    /// Grok Bot (`gb `).
    gb,

    /// What the row and the banner call it.
    pub fn title(b: Bot) []const u8 {
        return switch (b) {
            .pm => "发给项目经理",
            .af => "发给 Alfred",
            .gb => "发给 Grok Bot",
        };
    }
};

/// A note typed for a bot.
pub const Note = struct { bot: Bot, body: []const u8 };

/// When `query` is a bot command, the bot and the body (may be empty);
/// else null. `pm` alone counts; `af` and `gb` need their space, so
/// typing "af" or "gb" still finds apps (Affinity, GarageBand).
pub fn take(query_in: []const u8) ?Note {
    const q = std.mem.trimStart(u8, query_in, " \t");
    for (std.enums.values(Bot)) |b| {
        const word = @tagName(b);
        if (q.len > word.len and startsIgnoreCase(q, word) and (q[word.len] == ' ' or q[word.len] == '\t'))
            return .{ .bot = b, .body = std.mem.trim(u8, q[word.len..], " \t") };
    }
    if (eqlIgnoreCase(std.mem.trimEnd(u8, q, " \t"), "pm")) return .{ .bot = .pm, .body = "" };
    return null;
}

/// Absolute webhook config path for `bot` into `buf`.
pub fn configPath(buf: []u8, home: []const u8, bot: Bot) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/Nanolight/{s}-webhook.json", .{ home, @tagName(bot) }) catch "";
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
pub fn prepare(arena: std.mem.Allocator, io: std.Io, home: []const u8, bot: Bot, body_in: []const u8) ?Post {
    const body = std.mem.trim(u8, body_in, " \t\r\n");
    if (home.len == 0 or body.len == 0 or body.len > max_body) return null;

    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf, home, bot);
    if (path.len == 0) return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024)) catch return null;
    return fromConfig(arena, raw, body);
}

/// `prepare` past reading the file: the config's JSON and the note.
pub fn fromConfig(arena: std.mem.Allocator, raw: []const u8, body: []const u8) ?Post {
    // `senderKey` is what GoodDay's copy of the Alfred config calls it.
    const Config = struct { url: []const u8, key: []const u8 = "", senderKey: []const u8 = "" };
    const cfg = std.json.parseFromSliceLeaky(Config, arena, raw, .{ .ignore_unknown_fields = true }) catch return null;
    if (!std.mem.startsWith(u8, cfg.url, "https://")) return null;
    const key = stripCrLf(if (cfg.key.len > 0) cfg.key else cfg.senderKey);
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
pub fn notify(gpa: std.mem.Allocator, io: std.Io, bot: Bot, ok: bool) void {
    const t = std.Thread.spawn(.{}, notifyNow, .{ gpa, io, bot, ok }) catch return;
    t.detach();
}

fn notifyNow(gpa: std.mem.Allocator, io: std.Io, bot: Bot, ok: bool) void {
    var buf: [128]u8 = undefined;
    const script = std.fmt.bufPrint(&buf, "display notification \"{s}\" with title \"{s}\"", .{
        if (ok) "已发送" else "发送失败",
        bot.title(),
    }) catch return;
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
    try t.expectEqualStrings("推进 Nanolight", take("pm 推进 Nanolight").?.body);
    try t.expectEqual(Bot.pm, take("PM hello").?.bot);
    try t.expectEqualStrings("hello", take("PM hello").?.body);
    try t.expectEqualStrings("", take("pm").?.body);
    try t.expectEqualStrings("", take("PM").?.body);
    try t.expect(take("pms") == null);
    try t.expect(take("p m hi") == null);
}

test "af prefixes go to Alfred; af alone still finds apps" {
    const t = std.testing;
    try t.expectEqual(Bot.af, take("af 明天提醒我交稿").?.bot);
    try t.expectEqualStrings("明天提醒我交稿", take("af 明天提醒我交稿").?.body);
    try t.expectEqualStrings("hi", take("AF hi").?.body);
    try t.expectEqualStrings("", take("af ").?.body);
    try t.expect(take("af") == null);
    try t.expect(take("affinity") == null);
}

test "gb prefixes go to Grok Bot; gb alone still finds apps" {
    const t = std.testing;
    try t.expectEqual(Bot.gb, take("gb 查一下明天天气").?.bot);
    try t.expectEqualStrings("查一下明天天气", take("GB 查一下明天天气").?.body);
    try t.expect(take("gb") == null);
    try t.expect(take("gba") == null);
}

test "config path under Application Support" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/Users/chris/Library/Application Support/Nanolight/pm-webhook.json",
        configPath(&buf, "/Users/chris", .pm),
    );
    try std.testing.expectEqualStrings(
        "/Users/chris/Library/Application Support/Nanolight/af-webhook.json",
        configPath(&buf, "/Users/chris", .af),
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
    try std.testing.expectEqualStrings("Bearer s", fromConfig(a, "{\"url\":\"https://e.com\",\"senderKey\":\"s\"}", "x").?.auth);
    // Plain http, or no key: nothing is sent.
    try std.testing.expect(fromConfig(a, "{\"url\":\"http://e.com\",\"key\":\"k\"}", "x") == null);
    try std.testing.expect(fromConfig(a, "{\"url\":\"https://e.com\",\"key\":\" \"}", "x") == null);
}
