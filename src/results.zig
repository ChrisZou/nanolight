//! What the panel lists for a query, in order: the answer when it is math,
//! the apps that match it (or, with no query, suggestions), then Ask Codex
//! for exactly what is typed. Built-in commands (`reload` / `quit` / `pm `,
//! and their aliases) list only themselves. Prefix modes (`img` / `f` /
//! `ai`) keep their own lists. With no app or answer, Return asks Codex.
const std = @import("std");
const search = @import("search.zig");
const calc = @import("calc.zig");
const mac = @import("builtin").os.tag == .macos;

/// The key held for the panel's shortcuts (⌘1, ⌘↩, ⌘,): Ctrl on a PC.
pub const mod = if (mac) "⌘" else "Ctrl+";
/// What the panel calls the computer it runs on.
pub const machine = if (mac) "Mac" else "PC";

pub const Kind = enum {
    clipboard,
    /// Relaunch this Nanolight (`reload` / `restart`).
    restart,
    /// Quit Nanolight (`quit`).
    quit,
    /// Send a note to the project manager via webhook (`pm `).
    pm,
    calc,
    app,
    /// A Picemon image hit (`Row.pic`).
    pic,
    /// An FSearch file hit (`Row.file`).
    file,
    /// Ask Codex (default for plain queries, or `ai ` / `ask `).
    ai_ask,
    /// Codex's answer (Return copies it).
    ai_answer,
    ask_grok,
    search_x,
    search_web,
    /// One of Google's completions (`Row.web`).
    suggest,
    /// Nanolight's own Settings, listed when the query asks for them.
    settings,

    /// The row's kind as its trailing label shows it.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .clipboard => "Clipboard",
            .restart, .quit, .pm => "Nanolight",
            .calc => "Calculator",
            .app => "Application",
            .pic => "Image",
            .file => "File",
            .ai_ask, .ai_answer => "AI",
            .settings => "Nanolight",
            .ask_grok, .search_x, .search_web, .suggest => "Web",
        };
    }

    /// What Return does to it.
    pub fn action(k: Kind) []const u8 {
        return switch (k) {
            .clipboard => "Open Clipboard History",
            .restart => "Restart Nanolight",
            .quit => "Quit Nanolight",
            .pm => "Send to PM",
            .calc => "Copy Answer",
            .app => "Open Application",
            .pic => "Open Image",
            .file => "Open File",
            .ai_ask => "Ask Codex",
            .ai_answer => "Copy Answer",
            .settings => "Open Settings",
            .ask_grok => "Ask Grok",
            .search_x => "Search X",
            .search_web, .suggest => "Search Google",
        };
    }

    fn section(k: Kind, suggested: bool) []const u8 {
        return switch (k) {
            .clipboard => "Clipboard",
            .restart, .quit, .pm => "Nanolight",
            .calc => "Calculator",
            .app => if (suggested) "Suggestions" else "Applications",
            .pic => "Images",
            .file => "Files",
            .ai_ask, .ai_answer => "AI",
            .settings => "Nanolight",
            .search_web, .suggest => "Google",
            .ask_grok, .search_x => "Ask & Search",
        };
    }
};

pub const Row = struct {
    kind: Kind,
    /// The app's index (`.app`).
    app: u32 = 0,
    /// Which of the completions (`.suggest`).
    web: u8 = 0,
    /// Which Picemon hit (`.pic`).
    pic: u8 = 0,
    /// Which FSearch hit (`.file`).
    file: u8 = 0,
    /// Which of its name's bytes the query matched.
    match: search.Match = .{ .score = 0 },
};

pub const max_apps = 6;
/// Google's completions (unused in the default list; kept for preview helpers).
pub const max_web = 4;
/// Apps plus Ask Codex; also caps pic/file lists (their own max is 8).
pub const max_rows = 8;
/// The handoff that follows apps: Ask Codex only.
const handoffs = 1;

pub const Results = struct {
    rows: [max_rows]Row = undefined,
    n: usize = 0,
    /// No query: the apps are suggestions, nothing else is listed.
    suggested: bool = false,
    /// The math's answer, as shown.
    answer_buf: [64]u8 = undefined,
    answer: []const u8 = "",
    /// A whole answer in hexadecimal too ("0xC00"), else empty.
    hex_buf: [24]u8 = undefined,
    hex: []const u8 = "",

    pub fn slice(r: *const Results) []const Row {
        return r.rows[0..r.n];
    }

    /// Lists what `query` finds among `names` (with how often each was
    /// opened, `boost`), then Ask Codex. `web` is ignored (kept for call sites).
    /// Empty query lists `suggestions` only.
    pub fn build(r: *Results, query_in: []const u8, names: []const []const u8, boost: []const u16, suggestions: []const u32, web: []const []const u8) void {
        r.n = 0;
        const query = std.mem.trim(u8, query_in, " ");
        r.suggested = query.len == 0;
        if (std.ascii.eqlIgnoreCase(query, "clip") or std.ascii.eqlIgnoreCase(query, "cb")) {
            r.push(.{ .kind = .clipboard });
            return;
        }
        // Built-in commands: exact, Chinese aliases, or short prefixes
        // (`re` / `qui`) so they stay discoverable without Ask Codex covering them.
        if (matchesRestart(query)) {
            r.push(.{ .kind = .restart });
            return;
        }
        if (matchesQuit(query)) {
            r.push(.{ .kind = .quit });
            return;
        }
        if (query.len == 0) {
            for (suggestions[0..@min(suggestions.len, max_apps)]) |i| r.push(.{ .kind = .app, .app = i });
            return;
        }
        if (calc.eval(query)) |v| {
            r.answer = calc.format(&r.answer_buf, v, true);
            r.hex = if (v >= 0 and v < 1e15 and v == @round(v))
                std.fmt.bufPrint(&r.hex_buf, "0x{X}", .{@as(u64, @intFromFloat(v))}) catch ""
            else
                "";
            r.push(.{ .kind = .calc });
        }
        var ranked: [max_apps]search.Ranked = undefined;
        const n = search.rank(query, names, boost, &ranked);
        for (ranked[0..n]) |x| r.push(.{ .kind = .app, .app = x.index, .match = x.match });
        // "settings" / "preferences": Nanolight's own screen, right under
        // the apps: Return still opens System Settings, a key away from this.
        if (isSettings(query)) r.push(.{ .kind = .settings });
        if (r.n > 0 and r.rows[0].kind == .calc) return;
        _ = web;
        _ = handoffs;
        // Ask Codex for what was typed; Google / Grok / X are no longer listed.
        r.push(.{ .kind = .ai_ask });
    }


    /// Picemon hits only (from `img ` / `pic `).
    pub fn buildPic(r: *Results, n: usize) void {
        r.n = 0;
        r.suggested = false;
        r.answer = "";
        r.hex = "";
        for (0..@min(n, max_rows)) |i| r.push(.{ .kind = .pic, .pic = @intCast(i) });
    }

    /// FSearch hits only (from `f ` / `find ` / `file `).
    pub fn buildFile(r: *Results, n: usize) void {
        r.n = 0;
        r.suggested = false;
        r.answer = "";
        r.hex = "";
        for (0..@min(n, max_rows)) |i| r.push(.{ .kind = .file, .file = @intCast(i) });
    }

    /// Codex Q&A rows (from `ai ` / `ask `). `answered` picks the copy row.
    pub fn buildAi(r: *Results, answered: bool) void {
        r.n = 0;
        r.suggested = false;
        r.hex = "";
        if (answered) r.push(.{ .kind = .ai_answer }) else r.push(.{ .kind = .ai_ask });
    }

    /// One "发给项目经理" row (from `pm ` / `PM `).
    pub fn buildPm(r: *Results) void {
        r.n = 0;
        r.suggested = false;
        r.answer = "";
        r.hex = "";
        r.push(.{ .kind = .pm });
    }

    /// "settings" and "preferences", the words people type for this.
    fn isSettings(query: []const u8) bool {
        return std.ascii.eqlIgnoreCase(query, "settings") or std.ascii.eqlIgnoreCase(query, "preferences");
    }

    fn push(r: *Results, row: Row) void {
        if (r.n == max_rows) return;
        r.rows[r.n] = row;
        r.n += 1;
    }

    /// The header above row `i`, if a section starts there.
    pub fn section(r: *const Results, i: usize) ?[]const u8 {
        const k = r.rows[i].kind;
        const name = k.section(r.suggested);
        if (i > 0 and std.mem.eql(u8, r.rows[i - 1].kind.section(r.suggested), name)) return null;
        return name;
    }
};

/// The address a web row opens for `query`.
pub fn url(buf: []u8, kind: Kind, query: []const u8) []const u8 {
    const base = switch (kind) {
        .ask_grok => "https://grok.com/?q=",
        .search_x => "https://x.com/search?f=live&q=",
        .search_web, .suggest => "https://www.google.com/search?q=",
        .calc, .app, .settings, .clipboard, .restart, .quit, .pm, .pic, .file, .ai_ask, .ai_answer => return "",
    };
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(base) catch return "";
    escape(&w, query);
    return w.buffered();
}

/// `query`, trimmed, as a URL's query value: spaces as `+`, the rest of
/// what isn't plain as `%XX`. Stops where `w` is full.
pub fn escape(w: *std.Io.Writer, query: []const u8) void {
    for (std.mem.trim(u8, query, " ")) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            w.writeByte(ch) catch break;
        } else if (ch == ' ') {
            w.writeByte('+') catch break;
        } else w.print("%{X:0>2}", .{ch}) catch break;
    }
}


/// ASCII prefix match: `needle` is a case-insensitive prefix of `haystack`.
fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

/// `reload` / `restart`, Chinese aliases, or a 2+ char prefix of those words.
fn matchesRestart(query: []const u8) bool {
    if (std.mem.eql(u8, query, "重启") or std.mem.eql(u8, query, "重新启动") or std.mem.eql(u8, query, "重载")) return true;
    if (query.len < 2) return false;
    return startsWithIgnoreCase("reload", query) or startsWithIgnoreCase("restart", query);
}

/// `quit`, Chinese aliases, or a 2+ char prefix of `quit`.
fn matchesQuit(query: []const u8) bool {
    if (std.mem.eql(u8, query, "退出") or std.mem.eql(u8, query, "关掉")) return true;
    if (query.len < 2) return false;
    return startsWithIgnoreCase("quit", query);
}

test "math first, then apps; Ask Codex without Google or Ask & Search" {
    const t = std.testing;
    const names = [_][]const u8{ "Safari", "System Settings", "Calculator" };
    var r: Results = .{};
    r.build("saf", &names, &.{}, &.{}, &.{});
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 0), r.rows[0].app);
    try t.expectEqual(Kind.ai_ask, r.rows[r.n - 1].kind);
    try t.expectEqual(@as(usize, 2), r.n);
    try t.expectEqualStrings("Applications", r.section(0).?);
    try t.expectEqualStrings("AI", r.section(1).?);
    r.build("2^10 * 3", &names, &.{}, &.{}, &.{"ignored"});
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("3,072", r.answer);
    try t.expectEqualStrings("0xC00", r.hex);
    try t.expectEqual(@as(usize, 1), r.n);
    r.build("", &names, &.{}, &.{ 2, 0 }, &.{});
    try t.expectEqual(@as(usize, 2), r.n);
    try t.expectEqualStrings("Suggestions", r.section(0).?);
    r.build("liquid glass", &names, &.{}, &.{}, &.{ "ignored" });
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(Kind.ai_ask, r.rows[0].kind);
    try t.expectEqualStrings("AI", r.section(0).?);
    // Google suggestions are ignored even when supplied.
    r.build("liquid gl", &names, &.{}, &.{}, &.{ "liquid glass", "liquid glue" });
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(Kind.ai_ask, r.rows[0].kind);
    // A full list of apps ends with Ask Codex only.
    const many = [_][]const u8{ "Safari", "Mail", "Maps", "Pages", "Calendar", "Calculator", "FaceTime" };
    r.build("a", &many, &.{}, &.{}, &.{ "a1", "a2", "a3", "a4" });
    try t.expectEqual(@as(usize, max_apps + 1), r.n);
    try t.expectEqual(Kind.ai_ask, r.rows[max_apps].kind);
}

test "reload, restart and quit are built-in commands" {
    const t = std.testing;
    const names = [_][]const u8{"Safari"};
    var r: Results = .{};
    r.build("reload", &names, &.{}, &.{}, &.{});
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(Kind.restart, r.rows[0].kind);
    try t.expectEqualStrings("Restart Nanolight", Kind.restart.action());
    r.build("Restart", &names, &.{}, &.{}, &.{});
    try t.expectEqual(Kind.restart, r.rows[0].kind);
    r.build("quit", &names, &.{}, &.{}, &.{});
    try t.expectEqual(Kind.quit, r.rows[0].kind);
    try t.expectEqualStrings("Quit Nanolight", Kind.quit.action());
    // Prefixes and Chinese aliases: only the command row (no Ask Codex).
    for ([_][]const u8{ "re", "rel", "rest", "  re  ", "重启", "重新启动", "重载" }) |q| {
        r.build(q, &names, &.{}, &.{}, &.{});
        try t.expectEqual(@as(usize, 1), r.n);
        try t.expectEqual(Kind.restart, r.rows[0].kind);
    }
    for ([_][]const u8{ "qu", "qui", "退出", "关掉" }) |q| {
        r.build(q, &names, &.{}, &.{}, &.{});
        try t.expectEqual(@as(usize, 1), r.n);
        try t.expectEqual(Kind.quit, r.rows[0].kind);
    }
    // Too short / unrelated stays a normal query.
    r.build("r", &names, &.{}, &.{}, &.{});
    try t.expect(r.n > 1);
    try t.expect(r.rows[0].kind != Kind.restart);
    r.build("q", &names, &.{}, &.{}, &.{});
    try t.expect(r.rows[0].kind != Kind.quit);
}


test "clip and cb open clipboard history" {
    const t = std.testing;
    const names = [_][]const u8{"Safari"};
    var r: Results = .{};
    for ([_][]const u8{ "clip", "CLIP", "cb", "CB", "  cb  " }) |q| {
        r.build(q, &names, &.{}, &.{}, &.{});
        try t.expectEqual(@as(usize, 1), r.n);
        try t.expectEqual(Kind.clipboard, r.rows[0].kind);
        try t.expectEqualStrings("Open Clipboard History", Kind.clipboard.action());
    }
}

test "pm is a built-in command row" {
    var r: Results = .{};
    r.buildPm();
    try std.testing.expectEqual(@as(usize, 1), r.n);
    try std.testing.expectEqual(Kind.pm, r.rows[0].kind);
    try std.testing.expectEqualStrings("Send to PM", Kind.pm.action());
}

test "queries are escaped into the address" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://x.com/search?f=live&q=liquid+glass+%26+UI", url(&buf, .search_x, " liquid glass & UI "));
}
