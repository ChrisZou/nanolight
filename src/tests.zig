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
    _ = @import("ai.zig");
    _ = @import("promo_camera.zig");
    _ = @import("single.zig");
    _ = @import("clickthrough.zig");
    _ = @import("settings.zig");
    _ = @import("apps.zig");
    _ = @import("hotkey.zig");
    _ = @import("shortcut.zig");
    _ = @import("clipboard_store.zig");
    _ = @import("clipboard.zig");
    _ = @import("clipboard_panel.zig");
}

const Probe = struct {
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
    try t.expect(tester.containsText("Image ·"));
    tester.theme = ui.Theme.light;
    tester.settle(1);
    try t.expect(tester.containsText("Image ·"));
    press(&tester, &.{.{ .command = .insert_newline }});
    try t.expectEqual(png, probe.pasted.?);
    try t.expectEqual(@import("clipboard_store.zig").Kind.png, store.get(probe.pasted.?).?.kind);
    try t.expectEqualStrings(view.icon_png, store.get(probe.pasted.?).?.data);
    press(&tester, &.{.{ .insert = "Design" }});
    try t.expectEqual(@as(usize, 1), s.clip.n);
    press(&tester, &.{.{ .command = .insert_newline }});
    try t.expectEqual(@import("clipboard_store.zig").Kind.file_url, store.get(probe.pasted.?).?.kind);
}

fn press(t: *ui.Tester, ops: []const ui.TextOp) void {
    t.textOps(ops);
    t.settle(1);
}

test "the panel finds, moves, answers and hands off" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
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
    // No query: suggestions.
    try std.testing.expect(t.hasText("Suggestions"));
    try std.testing.expect(t.hasText("Safari"));
    // After an automatic update, the footer says so in place of the name.
    try std.testing.expect(t.hasText("Nanolight · 5 apps"));
    s.note = "Updated to 0.1.3";
    t.settle(1);
    try std.testing.expect(t.hasText("Updated to 0.1.3 · 5 apps"));
    s.note = "";

    // The top app's name completes what is typed; → takes it.
    press(&t, &.{.{ .insert = "saf" }});
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
    try std.testing.expect(t.hasText("⌘2"));
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    try std.testing.expectEqualStrings("/Applications/Safari.app", probe.opened[0..probe.opened_len]);

    // Math: answered, and Return copies it.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "2^10 * 3" } });
    try std.testing.expect(t.hasText("3,072"));
    try std.testing.expect(t.hasText("Result · 0xC00"));
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("3072", t.clipboard.items);

    // Anything else: Google, Grok, X.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "liquid glass" } });
    try std.testing.expect(t.containsText("Search X for"));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://x.com/search?f=live&q=liquid+glass", probe.opened[0..probe.opened_len]);

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
const Web = struct {
    probe: Probe = .{},
    asked: [64]u8 = undefined,
    asked_len: usize = 0,
    page: [256]u8 = undefined,
    page_len: ?usize = null,

    fn host(w: *Web) view.Host {
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

test "Google's completions land below, and a search shows in the panel" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
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
    // An address is never asked about; words are.
    press(&t, &.{.{ .insert = "ziglang.org" }});
    try std.testing.expectEqual(@as(usize, 0), web.asked_len);
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "liquid gl" } });
    try std.testing.expectEqualStrings("liquid gl", web.asked[0..web.asked_len]);
    // Return would search what was typed. The selection, moved before
    // the answer comes, stays on its row, though the completions land
    // above it, a key under the search.
    try std.testing.expectEqual(results.Kind.search_web, s.res.rows[s.sel].kind);
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expectEqual(results.Kind.search_x, s.res.rows[s.sel].kind);
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid glass", "liquid glass apple" }) |w| said.push(w);
    s.answered("liquid gl", &said);
    t.settle(1);
    try std.testing.expect(t.hasText("Google"));
    try std.testing.expect(t.hasText("liquid glass apple"));
    try std.testing.expectEqual(results.Kind.suggest, s.res.rows[1].kind);
    try std.testing.expectEqual(results.Kind.search_x, s.res.rows[s.sel].kind);
    // The first completion shows faintly in the field; Tab takes it.
    try std.testing.expect(t.hasText("ass"));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab }));
    t.settle(1);
    try std.testing.expectEqualStrings("liquid glass", s.query.text());
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "liquid gl" } });
    // Known at once this time, yet Return still searches what was typed,
    // not a completion nobody picked.
    try std.testing.expectEqual(results.Kind.suggest, s.res.rows[1].kind);
    try std.testing.expectEqual(results.Kind.search_web, s.res.rows[s.sel].kind);
    // ⌘2 is Google's first completion.
    try std.testing.expect(t.hasText("⌘2"));
    // One more letter: the answer so far stands in, and nothing is asked
    // again for words already answered.
    web.asked_len = 0;
    press(&t, &.{.{ .insert = "a" }});
    try std.testing.expectEqualStrings("liquid gla", web.asked[0..web.asked_len]);
    try std.testing.expect(t.hasText("liquid glass apple"));
    web.asked_len = 0;
    press(&t, &.{.{ .command = .delete_backward }});
    try std.testing.expectEqual(@as(usize, 0), web.asked_len);

    // ⌘3, the second completion: its words in the field, Google's page in the panel.
    try std.testing.expect(t.shortcut(.{ .key = '3', .cmd = true }));
    t.settle(1);
    try std.testing.expectEqualStrings("liquid glass apple", s.query.text());
    try std.testing.expectEqualStrings("https://www.google.com/search?q=liquid+glass+apple", web.page[0..web.page_len.?]);
    t.settle(2);
    try std.testing.expect(t.hasText("Open in Browser"));
    try std.testing.expectEqual(view.max_height, s.height());
    try std.testing.expect(!web.probe.hidden);
    // Escape: the rows again, the page gone.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(web.page_len == null);
    try std.testing.expectEqualStrings("liquid glass apple", s.query.text());

    // Return on words no app matches: Google's page; typing takes it away.
    press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "pizza" } });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizza", web.page[0..web.page_len.?]);
    press(&t, &.{.{ .insert = "s" }});
    try std.testing.expect(web.page_len == null);
    try std.testing.expect(t.hasText("Search Google for “pizzas”"));

    // ⌘↩ in the page, and on the row: the browser, and the panel hides.
    while (s.res.rows[s.sel].kind != .search_web) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expect(web.page_len != null);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizzas", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden);
    s.reveal();
    try std.testing.expect(web.page_len == null);
    web.probe = .{};
    t.settle(1);
    while (s.res.rows[s.sel].kind != .search_web) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizzas", web.probe.opened[0..web.probe.opened_len]);
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
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
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

test "the panel never outgrows its window, which is never resized" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
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
    // "a" fills every app row there is, and Google's completions the
    // rest: the bound is the real one.
    s.query.set("a");
    s.rebuild();
    var four: @import("suggest.zig").List = .{};
    for ([_][]const u8{ "a1", "a2", "a3", "a4" }) |w| four.push(w);
    s.answered("a", &four);
    try std.testing.expectEqual(view.max_height, s.height());
    var o: onboard.Onboard = .{};
    for ([_]onboard.Step{ .key, .try_it, .done }) |step| {
        o.step = step;
        try std.testing.expect(o.height() <= view.max_height);
    }
}


test "img and ai prefixes list their own rows" {
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
    s.ai_status = .ready;
    s.query.set("ai what is zig");
    s.rebuild();
    try std.testing.expectEqual(results.Kind.ai_ask, s.res.rows[0].kind);
    s.ai_status = .done;
    s.ai_text = "Zig is a systems language.";
    s.built = 1;
    s.rebuild();
    try std.testing.expectEqual(results.Kind.ai_answer, s.res.rows[0].kind);
}
