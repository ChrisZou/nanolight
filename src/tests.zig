//! Nanolight's parts, and its panel driven through a Tester: keys in,
//! rows and the clipboard out. Nothing is opened; no window shows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");

test {
    _ = @import("search.zig");
    _ = @import("calc.zig");
    _ = @import("results.zig");
    _ = @import("suggest.zig");
    _ = @import("pic.zig");
    _ = @import("file.zig");
    _ = @import("ai.zig");
    _ = @import("pm.zig");
    _ = @import("warp.zig");
    _ = @import("promo_camera.zig");
    _ = @import("settings.zig");
    _ = @import("apps.zig");
    _ = @import("shortcut.zig");
    _ = @import("clipboard_store.zig");
    _ = @import("clipboard.zig");
    _ = @import("clipboard_panel.zig");
    _ = @import("raycast_model.zig");
    _ = @import("raycast.zig");
    _ = @import("raycast_view.zig");
    _ = @import("script_commands.zig");
    _ = @import("script_run.zig");
    _ = @import("tests_ext.zig");
    _ = @import("tests_prefs.zig");
    switch (@import("builtin").os.tag) {
        .macos => {
            _ = @import("single_mac.zig");
            _ = @import("clickthrough.zig");
            _ = @import("hotkey_mac.zig");
            _ = @import("recorder.zig");
        },
        .windows => {
            _ = @import("apps_win.zig");
            _ = @import("hotkey_win.zig");
        },
        else => {
            _ = @import("apps_linux.zig");
            _ = @import("hotkey_x11.zig");
        },
    }
}

pub const Probe = struct {
    opened: [256]u8 = undefined,
    opened_len: usize = 0,
    hidden: bool = false,

    fn open(ctx: *anyopaque, target: []const u8) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        @memcpy(p.opened[0..target.len], target);
        p.opened_len = target.len;
    }
    fn hide(ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.hidden = true;
    }
};

const ClipProbe = struct {
    panel: *@import("clipboard_panel.zig").Panel,
    pasted: ?u64 = null,
    saves: usize = 0,
    closed: bool = false,
    fn action(ctx: *anyopaque, a: @import("clipboard_panel.zig").Action, id: u64) void {
        const p: *ClipProbe = @ptrCast(@alignCast(ctx));
        switch (a) {
            .enable => p.panel.enabled = true,
            .paste => p.pasted = id,
            .save => p.saves += 1,
            .close => p.closed = true,
            .accessibility => {},
        }
    }
};

test "clipboard mode opts in, filters locally, pins, deletes and selects original payloads" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var store: @import("clipboard_store.zig").Store = .init(t.allocator);
    defer store.deinit();
    const first = (try store.add(.text, "First line\nSecond line", 100)).?;
    const second = (try store.add(.text, "another copy", 101)).?;
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.clip.query.deinit();
    s.clip.store = &store;
    var probe: ClipProbe = .{ .panel = &s.clip };
    s.clip.hooks = .{ .ctx = &probe, .func = ClipProbe.action };
    var web: Web = .{};
    s.host = web.host();
    s.reveal();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    press(&tester, &.{.{ .insert = "clip" }});
    try t.expect(tester.hasText("Clipboard History"));
    press(&tester, &.{.{ .command = .insert_newline }});
    tester.settle(1);
    try t.expect(s.clip_mode);
    try t.expect(tester.hasText("Enable Clipboard History"));
    try t.expectEqual(@as(usize, 0), s.clip.n);
    try tester.clickText("Enable Clipboard History");
    tester.settle(1);
    try t.expectEqual(@as(usize, 2), s.clip.n);
    try t.expect(tester.hasText("First line Second line"));
    // Store.filter supplies substring matching; the separate field must
    // never ask the launcher's suggestion hook about clipboard words.
    web.asked_len = 0;
    press(&tester, &.{.{ .insert = "SECOND" }});
    try t.expectEqual(@as(usize, 1), s.clip.n);
    try t.expectEqual(first, s.clip.ids[0]);
    try t.expectEqual(@as(usize, 0), web.asked_len);
    press(&tester, &.{.{ .command = .insert_newline }});
    try t.expectEqual(first, probe.pasted.?);
    try t.expectEqualStrings("First line\nSecond line", store.get(probe.pasted.?).?.data);
    _ = tester.shortcut(.{ .key = 'p', .cmd = true });
    try t.expect(store.get(first).?.pinned);
    _ = tester.shortcut(.{ .key = ui.Shortcut.escape });
    try t.expectEqual(first, s.clip.ids[0]);
    _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(second, s.clip.ids[s.clip.sel]);
    _ = tester.shortcut(.{ .key = 0x7f, .alt = true });
    try t.expect(store.get(second) == null);
    try t.expectEqual(first, s.clip.ids[s.clip.sel]);
    try t.expectEqual(@as(usize, 2), probe.saves);
    // Timer insertion preserves selection by id, including a pinned row.
    _ = try store.add(.text, "new external copy", 102);
    tester.settle(1);
    try t.expectEqual(first, s.clip.ids[s.clip.sel]);
    // Clear APIs invalidate every row, including pins, without stale data.
    store.clear();
    tester.settle(1);
    try t.expectEqual(@as(usize, 0), s.clip.n);
    try t.expect(tester.hasText("No clipboard history"));
    _ = tester.shortcut(.{ .key = ui.Shortcut.escape });
    try t.expect(probe.closed);
}

test "clipboard keyboard navigation reaches history below the fold and clamps after pruning" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var store: @import("clipboard_store.zig").Store = .init(t.allocator);
    defer store.deinit();
    for (0..25) |i| {
        var buf: [64]u8 = undefined;
        _ = try store.add(.text, try std.fmt.bufPrint(&buf, "History {d}", .{i}), 100);
    }
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.clip.query.deinit();
    s.clip.store = &store;
    s.clip.enabled = true;
    s.openClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height });
    defer tester.deinit();
    tester.settle(1);
    for (0..24) |_| _ = tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expectEqual(@as(usize, 24), s.clip.sel);
    var scrolled = false;
    var offsets = tester.ctx.scroll.valueIterator();
    while (offsets.next()) |offset| if (offset.* > 0) {
        scrolled = true;
    };
    try t.expect(scrolled);
    _ = store.prune(100 + store.limits.max_age_s);
    tester.settle(1);
    try t.expectEqual(@as(usize, 0), s.clip.n);
    try t.expectEqual(@as(usize, 0), s.clip.sel);
}

test "clipboard images and file URLs keep their ids and original paste representations" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var store: @import("clipboard_store.zig").Store = .init(t.allocator);
    defer store.deinit();
    const png = (try store.add(.png, view.icon_png, 100)).?;
    _ = try store.add(.file_url, "file:///Users/chris/Documents/Design%20notes.pdf", 100);
    _ = try store.add(.text, "A considered interface needs room to breathe.", 100);
    _ = store.setPinned(png, true);
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.clip.query.deinit();
    s.clip.store = &store;
    s.clip.enabled = true;
    var probe: ClipProbe = .{ .panel = &s.clip };
    s.clip.hooks = .{ .ctx = &probe, .func = ClipProbe.action };
    s.openClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer tester.deinit();
    tester.settle(1);
    try t.expectEqual(png, s.clip.ids[0]);
    try t.expect(tester.containsText("Image:"));
    // The preview says when the selected copy was made.
    try t.expect(tester.containsText("Copied "));
    tester.theme = ui.Theme.light;
    tester.settle(1);
    try t.expect(tester.containsText("Image:"));
    press(&tester, &.{.{ .command = .insert_newline }});
    try t.expectEqual(png, probe.pasted.?);
    try t.expectEqual(@import("clipboard_store.zig").Kind.png, store.get(probe.pasted.?).?.kind);
    try t.expectEqualStrings(view.icon_png, store.get(probe.pasted.?).?.data);
    press(&tester, &.{.{ .insert = "Design" }});
    try t.expectEqual(@as(usize, 1), s.clip.n);
    press(&tester, &.{.{ .command = .insert_newline }});
    try t.expectEqual(@import("clipboard_store.zig").Kind.file_url, store.get(probe.pasted.?).?.kind);
}

/// The Mac's starters, which these tests' apps are named after.
const mac_starters = [_][]const u8{ "Safari", "Notes", "Calendar", "System Settings", "Finder" };

pub fn press(t: *ui.Tester, ops: []const ui.TextOp) void {
    t.textOps(ops);
    t.settle(1);
}

test "the panel finds, moves, answers and hands off" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    ix.starters = &mac_starters;
    for ([_][]const u8{ "Safari", "System Settings", "Notes", "Calculator", "Finder" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var probe: Probe = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = .{ .ctx = &probe, .open = Probe.open, .hide = Probe.hide };
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = 480, .dark = true });
    defer t.deinit();
    t.settle(1);
    // No query: the field alone, no rows and no footer.
    try std.testing.expect(!t.hasText("Suggestions"));
    try std.testing.expect(!t.hasText("Safari"));
    try std.testing.expect(!t.hasText("Settings"));
    try std.testing.expectEqual(view.header_h, s.height());
    press(&t, &.{.{ .insert = "saf" }});
    // After an automatic update, the footer says so in place of the name.
    const bo = @import("build_options");
    var footer: [64]u8 = undefined;
    try std.testing.expect(t.hasText(try std.fmt.bufPrint(&footer, "Nanolight {s} ({d}) · 5 apps", .{ bo.version, bo.build })));
    s.note = "Updated to 0.1.3";
    t.settle(1);
    try std.testing.expect(t.hasText("Updated to 0.1.3 · 5 apps"));
    s.note = "";
    // As Alfred's, a press on the panel's background (the footer's blank
    // middle) moves the window; one on a row or in the field doesn't.
    t.ctx.input.click_count = 1;
    t.moveTo(view.width / 2, s.height() - view.footer_h / 2);
    try std.testing.expect(t.ctx.startsWindowDrag());
    t.moveTo(view.width / 2, view.header_h + 1 + view.list_pad + view.section_h + view.row_h / 2);
    try std.testing.expect(!t.ctx.startsWindowDrag());
    t.moveTo(view.width / 2, view.header_h / 2);
    try std.testing.expect(!t.ctx.startsWindowDrag());

    // The top app's name completes what is typed; → takes it.
    try std.testing.expect(t.hasText("ari"));
    press(&t, &.{.{ .command = .move_right }});
    try std.testing.expectEqualStrings("safari", s.query.text());
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward } });

    press(&t, &.{.{ .insert = "ss" }});
    try std.testing.expect(t.hasText("System Settings"));
    try std.testing.expectEqual(@as(u32, ix.find("System Settings").?), s.res.rows[0].app);
    // Down and back up, then Return opens the first.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try std.testing.expectEqual(@as(usize, 1), s.sel);
    _ = t.shortcut(.{ .key = ui.Shortcut.up });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("/Applications/System Settings.app", probe.opened[0..probe.opened_len]);
    try std.testing.expect(probe.hidden);
    try std.testing.expectEqual(@as(u16, 1), ix.launches.items[ix.find("System Settings").?]);

    // ⌘2 opens the second row at once: Safari, under System Settings,
    // which was just opened.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "s" } });
    try std.testing.expect(t.hasText(results.mod ++ "2"));
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    try std.testing.expectEqualStrings("/Applications/Safari.app", probe.opened[0..probe.opened_len]);

    // Math: answered, and Return copies it.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "2^10 * 3" } });
    try std.testing.expect(t.hasText("3,072"));
    try std.testing.expect(t.hasText("Result · 0xC00"));
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("3072", t.clipboard.items);

    // Plain query: Ask Codex only (no Google / Grok / X rows).
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "liquid glass" } });
    try std.testing.expect(t.containsText("Ask Codex"));
    try std.testing.expect(!t.containsText("Search X for"));
    try std.testing.expect(!t.containsText("Search Google for"));
    try std.testing.expect(!t.containsText("Ask Grok"));
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqual(@import("results.zig").Kind.ai_ask, s.res.rows[0].kind);

    // Escape clears the query, then closes.
    probe.hidden = false;
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expectEqualStrings("", s.query.text());
    try std.testing.expect(!probe.hidden);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(probe.hidden);
}

const suggest = @import("suggest.zig");
const results = @import("results.zig");

/// A host that answers for Google and shows pages: what was asked, shown.
pub const Web = struct {
    probe: Probe = .{},
    asked: [64]u8 = undefined,
    asked_len: usize = 0,
    page: [256]u8 = undefined,
    page_len: ?usize = null,

    pub fn host(w: *Web) view.Host {
        return .{ .ctx = w, .open = open, .hide = hide, .suggest = ask, .preview = show };
    }
    fn open(ctx: *anyopaque, target: []const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        Probe.open(&w.probe, target);
    }
    fn hide(ctx: *anyopaque) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        Probe.hide(&w.probe);
    }
    fn ask(ctx: *anyopaque, q: []const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        @memcpy(w.asked[0..q.len], q);
        w.asked_len = q.len;
    }
    fn show(ctx: *anyopaque, url: ?[]const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        const u = url orelse {
            w.page_len = null;
            return;
        };
        @memcpy(w.page[0..u.len], u);
        w.page_len = u.len;
    }
};

test "plain queries list Ask Codex only; Google rows are gone" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    ix.starters = &mac_starters;
    try ix.add("Safari", "/Applications/Safari.app");
    var web: Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    press(&t, &.{.{ .insert = "liquid gl" }});
    // Suggestions are no longer requested for the default list.
    try std.testing.expectEqual(@as(usize, 0), web.asked_len);
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqual(results.Kind.ai_ask, s.res.rows[0].kind);
    try std.testing.expect(t.hasText("Ask Codex"));
    try std.testing.expect(!t.hasText("Google"));
    try std.testing.expect(!t.hasText("Ask & Search"));
    // answered() is harmless if a stale completion arrives.
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid glass", "liquid glass apple" }) |w| said.push(w);
    s.answered("liquid gl", &said);
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqual(results.Kind.ai_ask, s.res.rows[0].kind);
}

const onboard = @import("onboard.zig");
const shortcut = @import("shortcut.zig");

const Steps = struct {
    applied: ?shortcut.Choice = null,
    done: bool = false,
    fn apply(ctx: *anyopaque, c: shortcut.Choice) void {
        const p: *Steps = @ptrCast(@alignCast(ctx));
        p.applied = c;
    }
    fn fix(_: *anyopaque, _: shortcut.Clash) void {}
    fn finished(ctx: *anyopaque) void {
        const p: *Steps = @ptrCast(@alignCast(ctx));
        p.done = true;
    }
};

test "the welcome: a key, pressed for real, then a first search" {
    // Its keys and clashes are the Mac's (macOS's own shortcuts).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    ix.starters = &mac_starters;
    try ix.add("Safari", "/Applications/Safari.app");
    var o: onboard.Onboard = .{};
    // Hooks only once started: the system's shortcuts are not read in tests.
    o.start(.cmd_space);
    const sys = [_]shortcut.SystemKey{.{ .id = 64, .enabled = true, .key = 49, .mods = 1 << 20 }};
    o.system = &sys;
    var steps: Steps = .{};
    o.hooks = .{ .ctx = &steps, .apply = Steps.apply, .fix = Steps.fix, .done = Steps.finished };
    var s: view.Nanolight = .{ .index = &ix, .onboard = &o };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = 480, .dark = true });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Welcome to Nanolight"));
    // Who holds ⌘Space, by name; going on anyway is said as such.
    try std.testing.expect(t.hasText("macOS gives ⌘ Space to Spotlight first."));
    try std.testing.expect(t.hasText("Use ⌘ Space anyway"));
    t.key(.right);
    try std.testing.expect(t.hasText("⌥ Space is free on this Mac."));
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqual(shortcut.Choice.opt_space, steps.applied.?);
    try std.testing.expect(t.hasText("Press ⌥ Space now"));
    // A button never moves it on: the key closing the panel, then opening it.
    o.pressed(false);
    t.settle(1);
    try std.testing.expectEqual(onboard.Step.try_it, o.step);
    o.pressed(true);
    o.pressed(false);
    t.settle(2);
    try std.testing.expect(t.hasText("You're set."));
    // ⌘2: the math example, run in the launcher.
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(1);
    try std.testing.expect(steps.done and !o.active);
    try std.testing.expect(t.hasText("3,072"));

    // Esc skips from the first step, keeping the key shown there.
    steps = .{};
    o.start(.ctrl_space);
    t.settle(1);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(steps.done and !o.active);
    try std.testing.expectEqual(shortcut.Choice.ctrl_space, steps.applied.?);
}

const SettingsHost = @import("settings_host.zig").SettingsHost;

/// A host that records what Settings asked it to do.
pub const Prefs = struct {
    probe: Probe = .{},
    key: shortcut.Choice = .cmd_space,
    applied: ?shortcut.Choice = null,
    recording: bool = false,
    login_on: bool = false,
    suggest_sets: u8 = 0,
    searches_out: ?bool = null,
    menu_bar_on: bool = true,
    box: SettingsHost = undefined,

    pub fn init(p: *Prefs) void {
        p.box = .{
            .ctx = p,
            .choice = choice,
            .apply = apply,
            .record = record,
            .login = login,
            .suggest = suggestSet,
            .searches_out = searchesOut,
            .menu_bar = menuBar,
            .account = acct,
            .email = email,
            .sign_in = noop,
            .sign_out = noop,
            .terms = noop,
            .version = ver,
            .ready = ready,
            .check = noop,
            .restart = noop,
            .welcome = noop,
            .quit = noop,
        };
    }
    pub fn host(p: *Prefs) view.Host {
        return .{ .ctx = p, .open = open, .hide = hide, .settings = &p.box };
    }
    fn open(ctx: *anyopaque, target: []const u8) void {
        Probe.open(&@as(*Prefs, @ptrCast(@alignCast(ctx))).probe, target);
    }
    fn hide(ctx: *anyopaque) void {
        Probe.hide(&@as(*Prefs, @ptrCast(@alignCast(ctx))).probe);
    }
    fn choice(ctx: *anyopaque) shortcut.Choice {
        return @as(*Prefs, @ptrCast(@alignCast(ctx))).key;
    }
    fn apply(ctx: *anyopaque, c: shortcut.Choice) void {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.applied = c;
        p.key = c;
    }
    fn record(ctx: *anyopaque, on: bool) void {
        @as(*Prefs, @ptrCast(@alignCast(ctx))).recording = on;
    }
    fn login(ctx: *anyopaque, set: ?bool) bool {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        if (set) |on| p.login_on = on;
        return p.login_on;
    }
    fn suggestSet(ctx: *anyopaque, _: bool) void {
        @as(*Prefs, @ptrCast(@alignCast(ctx))).suggest_sets += 1;
    }
    fn searchesOut(ctx: *anyopaque, on: bool) void {
        @as(*Prefs, @ptrCast(@alignCast(ctx))).searches_out = on;
    }
    fn menuBar(ctx: *anyopaque, set: ?bool) bool {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        if (set) |on| p.menu_bar_on = on;
        return p.menu_bar_on;
    }
    fn acct(_: *anyopaque) @import("account.zig").State {
        return .signed_out;
    }
    fn email(_: *anyopaque) []const u8 {
        return "";
    }
    fn ver(_: *anyopaque) []const u8 {
        return "0.1.0";
    }
    fn ready(_: *anyopaque) ?[]const u8 {
        return null;
    }
    fn noop(_: *anyopaque) void {}
};

test "settings opens from ⌘,, from typing, and from the gear" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    ix.starters = &mac_starters;
    try ix.add("Safari", "/Applications/Safari.app");
    var prefs: Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    // The gear is in the footer, named (the footer shows once there are rows).
    press(&t, &.{.{ .insert = "saf" }});
    try std.testing.expect(t.hasText("Settings"));
    try t.clickText("Settings");
    t.settle(1);
    try std.testing.expect(s.settings_ui.open);
    try std.testing.expect(t.hasText("Open Nanolight with"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!s.settings_ui.open);

    // ⌘, opens it; Esc goes back to search.
    try std.testing.expect(t.shortcut(.{ .key = ',', .cmd = true }));
    t.settle(1);
    try std.testing.expect(s.settings_ui.open);
    try std.testing.expect(t.hasText("Google Suggestions"));
    try std.testing.expect(t.hasText("Open at Login"));
    try std.testing.expect(t.hasText("Sign In with Codegraff"));
    try std.testing.expect(t.hasText("Terms & Privacy"));
    try std.testing.expect(t.hasText("Check for Updates"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try std.testing.expect(!s.settings_ui.open);
    try std.testing.expect(t.hasText("Safari"));

    // Typing "settings" lists the row; Return opens it.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    press(&t, &.{.{ .insert = "settings" }});
    try std.testing.expect(t.hasText("Nanolight Settings"));
    try std.testing.expectEqual(results.Kind.settings, s.res.rows[0].kind);
    press(&t, &.{.{ .command = .insert_newline }});
    t.settle(1);
    try std.testing.expect(s.settings_ui.open);

    // → picks the next shortcut and tells the host.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
    try std.testing.expectEqual(shortcut.Choice.opt_space, prefs.applied.?);

    // On the Mac, Return on it records a key of one's own (issue #1): a
    // letter alone is refused, ⌥X is taken, kept, and shown as the chosen
    // one. (A PC keeps to the four.)
    if (@import("builtin").os.tag == .macos) {
        press(&t, &.{.{ .command = .insert_newline }});
        t.settle(1);
        try std.testing.expect(prefs.recording and t.hasText("Type a shortcut"));
        s.settings_ui.took(&s, shortcut.recorded(7, 0, 'x'));
        t.settle(1);
        try std.testing.expect(prefs.recording and t.hasText("Add ⌘, ⌥ or ⌃"));
        s.settings_ui.took(&s, shortcut.recorded(7, 1 << 19, 'x'));
        t.settle(1);
        try std.testing.expect(!prefs.recording and t.hasText("⌥ X"));
        try std.testing.expect(prefs.applied.?.eql(.{ .code = 7, .mods = 1 << 11 }));
        // ← goes back to the four.
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.left }));
        try std.testing.expect(prefs.applied.?.eql(.opt_cmd_space));
        try std.testing.expect(t.hasText("⌥ X"));
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
        try std.testing.expectEqual(shortcut.Choice.opt_space, prefs.applied.?);
    }

    // ↓ onto Google Suggestions, Return flips it.
    try std.testing.expect(s.suggest_on);
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqual(@as(usize, 1), s.settings_ui.sel);
    try std.testing.expectEqual(true, s.settings_ui.open);
    try std.testing.expectEqual(@as(u8, 1), prefs.suggest_sets);
    try std.testing.expect(!s.suggest_on);
    try std.testing.expectEqual(@as(u8, 1), prefs.suggest_sets);
    try std.testing.expect(s.height() <= view.max_height);
}

test "the panel never outgrows its window, which is never resized" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    ix.starters = &mac_starters;
    for ([_][]const u8{ "Safari", "Mail", "Maps", "Music", "Notes", "Numbers", "Pages", "Photos", "Calendar", "Calculator" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var tallest: f32 = 0;
    for ([_][]const u8{ "", "a", "s", "ma", "2^10 * 3", "1+a", "liquid glass" }) |q| {
        s.query.set(q);
        s.rebuild();
        tallest = @max(tallest, s.height());
    }
    try std.testing.expect(tallest <= view.max_height);
    // "a" fills every app row plus Ask Codex; still within the bound.
    s.query.set("a");
    s.rebuild();
    try std.testing.expect(s.height() <= view.max_height);
    try std.testing.expectEqual(results.Kind.ai_ask, s.res.rows[s.res.n - 1].kind);
    var o: onboard.Onboard = .{};
    for ([_]onboard.Step{ .key, .try_it, .done }) |step| {
        o.step = step;
        try std.testing.expect(o.height() <= view.max_height);
    }
}

test "reload and quit are launcher commands" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.query.set("reload");
    s.rebuild();
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqual(results.Kind.restart, s.res.rows[0].kind);
    s.query.set("restart");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.restart, s.res.rows[0].kind);
    s.query.set("re");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.restart, s.res.rows[0].kind);
    s.query.set("重启");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.restart, s.res.rows[0].kind);
    s.query.set("quit");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.quit, s.res.rows[0].kind);
    s.query.set("退出");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.quit, s.res.rows[0].kind);
}

test "img, file and ai prefixes list their own rows" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.pics.push("/Users/chris/Pictures/demo.png");
    s.query.set("img demo");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.pic, s.res.rows[0].kind);
    try std.testing.expectEqualStrings("demo.png", s.pics.get(0).name());
    s.files.push("/Users/chris/code/ai/nanolight/README.md", false);
    s.query.set("find README");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.file, s.res.rows[0].kind);
    try std.testing.expectEqualStrings("README.md", s.files.get(0).name());
    s.ai_status = .ready;
    s.query.set("ai what is zig");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.ai_ask, s.res.rows[0].kind);
    s.ai_status = .done;
    s.ai_text = "Zig is a systems language.";
    s.built = 1;
    s.rebuild();
    try std.testing.expectEqual(results.Kind.ai_answer, s.res.rows[0].kind);
    // Plain query (no prefix): Ask Codex is the only handoff row.
    s.ai_status = .ready;
    s.ai_text = "";
    s.built = 1;
    s.query.set("今天是农历初几 2026");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.ai_ask, s.res.rows[0].kind);
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqualStrings("今天是农历初几 2026", s.ai_question[0..s.ai_question_len]);
    // Answered, then nothing typed: the field alone, not the last answer.
    s.ai_status = .done;
    s.ai_text = "我在，怎么啦？";
    s.ai_question_len = 0;
    s.query.set("");
    s.built = 1;
    s.rebuild();
    try std.testing.expectEqual(@as(usize, 0), s.res.n);
}

test "pm prefix lists send-to-PM row" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.query.set("pm 推进 Nanolight");
    s.rebuild();
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqual(results.Kind.pm, s.res.rows[0].kind);
    try std.testing.expectEqualStrings("推进 Nanolight", s.pm_body[0..s.pm_body_len]);
    s.query.set("PM hello");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.pm, s.res.rows[0].kind);
    try std.testing.expectEqualStrings("hello", s.pm_body[0..s.pm_body_len]);
    s.query.set("af 明早提醒我发视频");
    s.rebuild();
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqual(results.Kind.af, s.res.rows[0].kind);
    try std.testing.expectEqualStrings("明早提醒我发视频", s.pm_body[0..s.pm_body_len]);
    s.query.set("gb 看看今天的 AI 新闻");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.gb, s.res.rows[0].kind);
    try std.testing.expectEqualStrings("看看今天的 AI 新闻", s.pm_body[0..s.pm_body_len]);
    s.query.set("wp 整理一下 Downloads");
    s.rebuild();
    try std.testing.expectEqual(@as(usize, 1), s.res.n);
    try std.testing.expectEqual(results.Kind.warp, s.res.rows[0].kind);
    try std.testing.expectEqualStrings("整理一下 Downloads", s.pm_body[0..s.pm_body_len]);
}

test "on a PC the panel's keys are Ctrl's, and Settings says so" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    ix.starters = &mac_starters;
    try ix.add("Safari", "/Applications/Safari.app");
    try ix.add("System Settings", "/Applications/System Settings.app");
    var prefs: Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    press(&t, &.{.{ .insert = "s" }});
    try std.testing.expect(t.hasText("Ctrl+2"));
    try std.testing.expect(!t.containsText("⌘"));
    try std.testing.expect(t.shortcut(.{ .key = ',', .ctrl = true }));
    t.settle(1);
    try std.testing.expect(s.settings_ui.open);
    try std.testing.expect(t.hasText("This PC"));
    try std.testing.expect(t.hasText("Alt Space"));
    try std.testing.expect(t.hasText("Sync Across Computers"));
}

/// The clipboard row the highlight bar is drawn on, read off the pixels:
/// the one whose middle differs most from the field's background.
fn highlightedClipRow(t: *ui.Tester, n: usize) !usize {
    const px = try t.render(std.testing.allocator);
    defer px.deinit(std.testing.allocator);
    const scale = @as(f32, @floatFromInt(px.width)) / view.width;
    const lum = struct {
        fn at(p: anytype, x: f32, y: f32) i32 {
            const i = (@as(usize, @intFromFloat(y)) * p.width + @as(usize, @intFromFloat(x))) * 4;
            return @as(i32, p.bytes[i]) + p.bytes[i + 1] + p.bytes[i + 2];
        }
    }.at;
    // The list starts under the 58 pt field, its rule and its padding;
    // the middle of a row, right of its label, is bar or background only.
    var best: usize = 0;
    var best_d: i32 = -1;
    const P = @import("clipboard_panel.zig");
    const x = (P.list_w - 90) * scale;
    const base = lum(px, x, 30 * scale);
    for (0..n) |i| {
        const y = (58 + 1 + P.list_pad + P.row_h / 2 + P.row_h * @as(f32, @floatFromInt(i))) * scale;
        const d: i32 = @intCast(@abs(lum(px, x, y) - base));
        if (d > best_d) {
            best_d = d;
            best = i;
        }
    }
    try std.testing.expect(best_d > 6);
    return best;
}

test "the clipboard highlight stays on its row through the caret's blinks" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    var store: @import("clipboard_store.zig").Store = .init(t.allocator);
    defer store.deinit();
    for (0..8) |i| {
        var buf: [32]u8 = undefined;
        _ = try store.add(.text, try std.fmt.bufPrint(&buf, "Item {d}", .{i}), 100);
    }
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    defer s.clip.query.deinit();
    s.clip.store = &store;
    s.clip.enabled = true;
    s.openClipboard();
    var tester: ui.Tester = undefined;
    try tester.init(t.allocator, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height });
    defer tester.deinit();
    tester.settle(1);
    try t.expectEqual(@as(usize, 0), try highlightedClipRow(&tester, 6));
    // ↓ three times in quick succession, as in the recording.
    for (0..3) |_| {
        _ = tester.shortcut(.{ .key = ui.Shortcut.down });
        tester.advance(0.12);
    }
    try t.expectEqual(@as(usize, 3), s.clip.sel);
    try t.expectEqual(@as(usize, 3), try highlightedClipRow(&tester, 6));
    // No keys: the caret blinks every half second. The bar never moves.
    for (0..6) |_| {
        tester.advance(0.25);
        try t.expectEqual(@as(usize, 3), s.clip.sel);
        try t.expectEqual(@as(usize, 3), try highlightedClipRow(&tester, 6));
    }
    // ↑ once, then blinks again.
    _ = tester.shortcut(.{ .key = ui.Shortcut.up });
    tester.advance(0.05);
    try t.expectEqual(@as(usize, 2), try highlightedClipRow(&tester, 6));
    for (0..4) |_| {
        tester.advance(0.25);
        try t.expectEqual(@as(usize, 2), try highlightedClipRow(&tester, 6));
    }
}
