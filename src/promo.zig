//! The promo: 31 seconds cut to a 120 BPM beat, one idea a shot, a word on
//! screen at every moment (no voice to follow). Everything here is drawn
//! by nanoui offscreen, the panel by the app's own code driven by keys
//! through a Tester: no window shows, nothing is opened. The laptop shots
//! are Blender's (tools/promo/laptop.py), with this program's `screen-in`
//! and `screen-out` frames on the laptop's display.
//!
//!     tools/promo.sh                       # the whole video
//!     zig-out/bin/nanolight-promo --shot=panel --wall=W --serp=S > frames.bgra
//!     zig-out/bin/nanolight-promo --cues   # when keys and cuts land
//!
//! Google's answers are the ones it gave for these words (decoded by
//! suggest.zig, as the app decodes them), shown a beat after typing as
//! they would arrive; the results page is Google's, captured in a WebKit
//! view as the panel loads it (tools/promo/serp.swift).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const results = @import("results.zig");
const suggest = @import("suggest.zig");
const cards = @import("promo_cards.zig");

pub const fps = 30;
pub const total: f32 = 31;

pub const Kind = enum { hook, laptop_in, panel, stats, laptop_out, end };
pub const Shot = struct { kind: Kind, at: f32, len: f32 };
pub const shots = [_]Shot{
    .{ .kind = .hook, .at = 0, .len = 2.5 },
    .{ .kind = .laptop_in, .at = 2.5, .len = 3.5 },
    .{ .kind = .panel, .at = 6, .len = 15 },
    .{ .kind = .stats, .at = 21, .len = 3 },
    .{ .kind = .laptop_out, .at = 24, .len = 4 },
    .{ .kind = .end, .at = 28, .len = 3 },
};

const Caption = struct { word: []const u8, sub: []const u8, tone: ui.Color };

const Op = union(enum) {
    show,
    caption: Caption,
    text: []const u8,
    /// The query, all at once.
    set: []const u8,
    clear,
    enter,
    /// →: the faint completion taken.
    accept,
    key: struct { sc: ui.Shortcut, label: []const u8 },
};

const Step = struct { at: f32, op: Op };

const S = ui.Shortcut;
const down: Op = .{ .key = .{ .sc = .{ .key = S.down }, .label = "↓" } };
const esc: Op = .{ .key = .{ .sc = .{ .key = S.escape }, .label = "esc" } };
const tab: Op = .{ .key = .{ .sc = .{ .key = S.tab }, .label = "Tab" } };

fn typing(comptime at: f32, comptime str: []const u8, comptime every: f32) [str.len]Step {
    var out: [str.len]Step = undefined;
    for (str, 0..) |_, i| out[i] = .{ .at = at + every * @as(f32, @floatFromInt(i)), .op = .{ .text = str[i .. i + 1] } };
    return out;
}

fn cap(word: []const u8, sub: []const u8, tone: ui.Color) Op {
    return .{ .caption = .{ .word = word, .sub = sub, .tone = tone } };
}

/// The middle: the panel, close, and what each thing it does is called.
const panel_script = [_]Step{
    .{ .at = 0, .op = .show },
    .{ .at = 0, .op = cap("APPS.", "found as you type", cards.yellow) },
} ++ typing(0.4, "saf", 0.12) ++ [_]Step{
    .{ .at = 1.2, .op = .accept },
    .{ .at = 2.0, .op = .clear },
    .{ .at = 2.0, .op = cap("INITIALS.", "ss → System Settings", cards.cream) },
} ++ typing(2.3, "ss", 0.15) ++ [_]Step{
    .{ .at = 3.6, .op = .clear },
    .{ .at = 3.6, .op = cap("TYPOS.", "chorme? Chrome.", cards.red) },
} ++ typing(3.9, "chorme", 0.08) ++ [_]Step{
    .{ .at = 5.2, .op = .clear },
    .{ .at = 5.2, .op = cap("MATH.", "answered as you type", cards.yellow) },
} ++ typing(5.5, "2^10 * 3", 0.06) ++ [_]Step{
    .{ .at = 6.5, .op = .enter },
    .{ .at = 6.5, .op = cap("MATH.", "↩ copies the answer", cards.yellow) },
    .{ .at = 7.6, .op = .clear },
    .{ .at = 7.6, .op = cap("GOOGLE.", "suggests as you type", cards.cream) },
} ++ typing(7.9, "liquid gl", 0.06) ++ [_]Step{
    .{ .at = 9.3, .op = tab },
    .{ .at = 9.3, .op = cap("GOOGLE.", "Tab takes the suggestion", cards.cream) },
    .{ .at = 10.3, .op = down },
    .{ .at = 10.8, .op = .enter },
    .{ .at = 10.8, .op = cap("RESULTS.", "right in the panel", cards.red) },
    .{ .at = 13.0, .op = esc },
    .{ .at = 13.0, .op = cap("GROK & X.", "one row away", cards.yellow) },
    .{ .at = 13.5, .op = down },
    .{ .at = 14.1, .op = down },
};

/// The laptop's display as the camera comes in: the desktop, then ⌘Space.
const screen_in_script = [_]Step{
    .{ .at = 0.9, .op = .show },
} ++ typing(1.4, "saf", 0.15) ++ [_]Step{
    .{ .at = 2.3, .op = .accept },
};

/// The display as the camera leaves: a search's page in the panel
/// (loaded in the second before it, `pre`).
const screen_out_script = [_]Step{
    .{ .at = -1.0, .op = .show },
    .{ .at = -1.0, .op = .{ .set = "liquid glass apple" } },
    .{ .at = -0.9, .op = .enter },
};

/// What Google answered for these words (suggestqueries, client=firefox).
const answers = [_]struct { []const u8, []const u8 }{
    .{ "liquid gl", "[\"liquid gl\",[\"liquid glass\",\"liquid glue\",\"liquid glass apple\",\"liquid glass wallpaper\",\"liquid glycerol\",\"liquid glass ui\"]]" },
    .{ "liquid glass", "[\"liquid glass\",[\"liquid glass\",\"liquid glass apple\",\"liquid glass wallpaper\",\"liquid glass ui\",\"liquid glass iphone\"]]" },
};

/// The apps the panel finds: Apple's own and Chrome (the typo's), the
/// same on any Mac, rather than whatever this one has. The numbers card
/// ranks this Mac's real list.
const apps = [_][]const u8{
    "/Applications/Safari.app",                 "/Applications/Google Chrome.app",
    "/System/Applications/System Settings.app", "/System/Applications/Calculator.app",
    "/System/Applications/Calendar.app",        "/System/Applications/Mail.app",
    "/System/Applications/Maps.app",            "/System/Applications/Messages.app",
    "/System/Applications/Music.app",           "/System/Applications/Notes.app",
    "/System/Applications/Photos.app",          "/System/Applications/FaceTime.app",
    "/System/Library/CoreServices/Finder.app",  "/System/Applications/App Store.app",
    "/System/Applications/Books.app",           "/System/Applications/Freeform.app",
    "/System/Applications/Preview.app",         "/System/Applications/Reminders.app",
    "/System/Applications/Shortcuts.app",       "/System/Applications/Utilities/Terminal.app",
    "/System/Applications/Utilities/Activity Monitor.app", "/System/Applications/Weather.app",
    "/System/Applications/Podcasts.app",        "/System/Applications/TV.app",
    "/System/Applications/TextEdit.app",        "/System/Applications/Contacts.app",
    "/System/Applications/Clock.app",           "/System/Applications/Passwords.app",
    "/System/Applications/Journal.app",         "/System/Applications/Stocks.app",
    "/System/Applications/Home.app",            "/System/Applications/News.app",
};

/// The panel on a wallpaper: close up, beside its caption (`screen` false),
/// or on a desktop as the laptop's display shows it.
const Scene = struct {
    s: *view.Nanolight,
    w: f32,
    h: f32,
    screen: bool,
    wall: ?[]const u8,
    wall_scale: f32,
    serp: ?[]const u8,
    gpa: std.mem.Allocator,
    now: f64 = 0,
    shown: bool = false,
    caption: ?Caption = null,
    key: []const u8 = "",
    key_at: f64 = -10,
    page: bool = false,
    asked: [suggest.max_len]u8 = undefined,
    asked_len: usize = 0,
    asked_at: f64 = -1,

    fn panelX(d: *const Scene) f32 {
        return if (d.screen) (d.w - view.width) / 2 else d.w - view.width - 56;
    }
    fn panelY(d: *const Scene) f32 {
        return if (d.screen) d.h * 0.2 else 22;
    }

    fn draw(d: *Scene, c: *ui.Context) void {
        const root = ui.div(c).size(d.w, d.h);
        defer root.end();
        {
            const wl = ui.div(c).absolute().offset(0, 0).size(d.w, d.h).bg(.hex(0x10203a));
            defer wl.end();
            if (d.wall) |bytes| _ = ui.image(c, .{ .key = "wall", .bytes = bytes, .max_width = d.w, .max_height = d.h, .radius = 0, .scale = d.wall_scale });
        }
        if (d.screen) d.menuBar(c) else ui.div(c).absolute().offset(0, 0).size(d.w, d.h).bg(ui.Color.black.alpha(0.3)).end();
        if (motion.present(c, "panel", d.shown, .{
            .initial = .{ .opacity = 0, .y = -12, .scale = 0.96 },
            .transition = .{ .spring = view.spring },
        })) |f| {
            const p = ui.div(c).absolute().offset(d.panelX(), d.panelY()).motion(f);
            defer p.end();
            d.s.panel(c);
        }
        d.results(c);
        if (!d.screen) d.side(c);
    }

    /// Google's page over the panel's body while it previews, a moment
    /// after Return, as a page loads.
    fn results(d: *Scene, c: *ui.Context) void {
        const bytes = d.serp orelse return;
        const area = view.webArea(d.s.last_h);
        if (motion.present(c, "page", d.s.previewing and d.page, .{
            .initial = .{ .opacity = 0, .y = 10 },
            .exit = .{ .opacity = 0 },
            .transition = .{ .spring = view.spring },
            .delay = 0.3,
        })) |f| {
            const pg = ui.div(c).absolute().offset(d.panelX(), d.panelY() + area.y).size(view.width, area.h).clip().bg(.white).motion(f);
            defer pg.end();
            _ = ui.image(c, .{ .key = "serp", .bytes = bytes, .max_width = view.width, .max_height = 1000, .radius = 0, .scale = 2 });
        }
    }

    /// The close-up's left column: the name, what it is, the key pressed.
    fn side(d: *Scene, c: *ui.Context) void {
        {
            const brand = ui.div(c).absolute().offset(56, 52).row().gap(12).itemsCenter();
            defer brand.end();
            view.appIcon(c, 40);
            ui.text(c, "Nanolight", .{ .size = 24, .weight = .bold, .color = .white, .tracking = -0.5 });
        }
        if (d.caption) |cp| {
            ui.key(c, cp.word);
            const f = motion.frame(c, .{ .initial = .{ .opacity = 0, .scale = 1.35, .x = -20 }, .transition = .{ .spring = .{ .stiffness = 650, .damping = 34 } } });
            const col = ui.div(c).absolute().offset(56, 200).w(460).column().gap(18).motion(f);
            defer col.end();
            ui.text(c, cp.word, .{ .size = 84, .weight = .bold, .color = cp.tone, .tracking = -3 });
            ui.div(c).w(110).h(12).roundedFull().bg(cp.tone).end();
            ui.key(c, cp.sub);
            const sf = motion.frame(c, .{ .initial = .{ .opacity = 0, .y = 14 }, .transition = .{ .spring = view.spring } });
            const sub = ui.div(c).wFull().motion(sf);
            defer sub.end();
            ui.text(c, cp.sub, .{ .size = 34, .weight = .semibold, .color = .white, .wrap = true, .line_height = 42 });
        }
        if (motion.present(c, c.print("key-{s}-{d}", .{ d.key, @as(i64, @intFromFloat(d.key_at * 100)) }), d.now - d.key_at < 0.9, .{
            .initial = .{ .opacity = 0, .scale = 0.7 },
            .exit = .{ .opacity = 0, .scale = 0.95 },
            .transition = .{ .spring = .{ .stiffness = 600, .damping = 26 } },
        })) |f| {
            const k = ui.div(c).absolute().offset(56, 520).motion(f);
            defer k.end();
            const kc = ui.div(c).row().px(26).h(84).minW(84).justifyCenter().itemsCenter().rounded(18).bg(.white)
                .shadows(&.{.{ .color = cards.ink.alpha(0.8), .blur = 0, .y = 7 }});
            defer kc.end();
            ui.text(c, d.key, .{ .size = 36, .weight = .bold, .color = cards.ink });
        }
    }

    fn menuBar(d: *Scene, c: *ui.Context) void {
        const bar = ui.div(c).absolute().offset(0, 0).size(d.w, 30).row().px(18).gap(20).itemsCenter().bg(ui.Color.black.alpha(0.18));
        defer bar.end();
        const st: ui.TextStyle = .{ .size = 14, .weight = .medium, .color = .white };
        ui.text(c, "\u{F8FF}", .{ .size = 16, .color = .white });
        ui.text(c, "Finder", .{ .size = 14, .weight = .bold, .color = .white });
        for ([_][]const u8{ "File", "Edit", "View", "Go", "Window", "Help" }) |m| ui.text(c, m, st);
        ui.spacer(c);
        {
            const on = ui.div(c).row().px(6).h(22).itemsCenter().rounded(6).bg(ui.Color.white.alpha(if (d.shown) 0.25 else 0));
            defer on.end();
            ui.icon(c, "magnifyingglass", .{ .size = 13, .weight = .semibold, .color = .white });
        }
        ui.icon(c, "wifi", .{ .size = 14, .weight = .medium, .color = .white });
        ui.icon(c, "battery.75percent", .{ .size = 17, .color = .white });
        ui.text(c, "Mon 2 Nov  9:41", st);
    }

    /// Google answers a beat after it's asked, as it would.
    fn google(d: *Scene) void {
        if (d.asked_at < 0 or d.now - d.asked_at < 0.3) return;
        d.asked_at = -1;
        const q = d.asked[0..d.asked_len];
        for (answers) |a| if (std.mem.eql(u8, a[0], q)) {
            var arena: std.heap.ArenaAllocator = .init(d.gpa);
            defer arena.deinit();
            var list: suggest.List = .{};
            if (suggest.decode(arena.allocator(), a[1], q, &list)) d.s.answered(q, &list);
        };
    }

    fn host(d: *Scene) view.Host {
        return .{ .ctx = d, .open = open, .hide = hide, .resize = resize, .suggest = ask, .preview = preview };
    }
    fn open(_: *anyopaque, _: []const u8) void {}
    fn hide(ctx: *anyopaque) void {
        const d: *Scene = @ptrCast(@alignCast(ctx));
        d.shown = false;
    }
    /// Only so the panel keeps its height (`last_h`) for the page.
    fn resize(_: *anyopaque, _: f32) void {}
    fn ask(ctx: *anyopaque, q: []const u8) void {
        const d: *Scene = @ptrCast(@alignCast(ctx));
        const t = std.mem.trim(u8, q, " ");
        @memcpy(d.asked[0..t.len], t);
        d.asked_len = t.len;
        d.asked_at = d.now;
    }
    fn preview(ctx: *anyopaque, url: ?[]const u8) void {
        const d: *Scene = @ptrCast(@alignCast(ctx));
        d.page = url != null;
    }
};

fn script(kind: []const u8) ?struct { steps: []const Step, len: f32, pre: f32, screen: bool } {
    if (std.mem.eql(u8, kind, "panel")) return .{ .steps = &panel_script, .len = shots[2].len, .pre = 0, .screen = false };
    if (std.mem.eql(u8, kind, "screen-in")) return .{ .steps = &screen_in_script, .len = shots[1].len, .pre = 0, .screen = true };
    if (std.mem.eql(u8, kind, "screen-out")) return .{ .steps = &screen_out_script, .len = shots[4].len, .pre = 1.2, .screen = true };
    return null;
}

fn isKey(op: Op) bool {
    return switch (op) {
        .text, .clear, .enter, .accept, .key => true,
        else => false,
    };
}

/// When things land, in seconds from the start: `cut` at each shot, `hit`
/// on each card's beat, `click` for each key (tools/promo.sh's sounds).
fn cues(io: std.Io) !void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    for (shots) |sh| {
        try o.print("cut {d:.3}\n", .{sh.at});
        const steps: []const Step = switch (sh.kind) {
            .panel => &panel_script,
            .laptop_in => &screen_in_script,
            else => &.{},
        };
        for (steps) |st| if (isKey(st.op) and st.at >= 0) try o.print("click {d:.3}\n", .{sh.at + st.at});
        const kind: ?cards.Kind = switch (sh.kind) {
            .hook => .hook,
            .stats => .stats,
            .end => .end,
            else => null,
        };
        if (kind) |k| for (cards.beats(k)) |b| try o.print("hit {d:.3}\n", .{sh.at + b});
    }
    try o.flush();
}

extern "c" fn CACurrentMediaTime() f64;

/// The slowest key's ranking of every app on this Mac, in microseconds.
fn slowest(ix: *Index) f64 {
    var worst: f64 = 0;
    var r: results.Results = .{};
    var sug: [results.max_apps]u32 = undefined;
    const ns = ix.suggestions(&sug);
    for ([_][]const u8{ "s", "saf", "ss", "chorme", "2^10 * 3", "liquid glass", "zqxjkvwy" }) |q| {
        const runs = 2000;
        const t0 = CACurrentMediaTime();
        for (0..runs) |_| {
            r.build(q, ix.names.items, ix.launches.items, sug[0..ns], &.{});
            std.mem.doNotOptimizeAway(&r);
        }
        worst = @max(worst, (CACurrentMediaTime() - t0) / runs * 1e6);
    }
    return worst;
}

fn readAll(io: std.Io, gpa: std.mem.Allocator, path: ?[]const u8) ?[]const u8 {
    const p = path orelse return null;
    return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 20)) catch |e| {
        std.debug.print("nanolight-promo: {s}: {t}\n", .{ p, e });
        return null;
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var shot: []const u8 = "";
    var wall_path: ?[]const u8 = null;
    var serp_path: ?[]const u8 = null;
    var size: []const u8 = "1.6 MB";
    var still: ?struct { frame: usize, path: []const u8 } = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cues")) return cues(io);
        if (std.mem.startsWith(u8, arg, "--shot=")) shot = arg[7..] else if (std.mem.startsWith(u8, arg, "--wall=")) wall_path = arg[7..] else if (std.mem.startsWith(u8, arg, "--serp=")) serp_path = arg[7..] else if (std.mem.startsWith(u8, arg, "--size=")) size = arg[7..] else if (std.mem.startsWith(u8, arg, "--still=")) {
            const v = arg[8..];
            const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.BadStill;
            still = .{ .frame = @intFromFloat(@round(try std.fmt.parseFloat(f32, v[0..colon]) * fps)), .path = v[colon + 1 ..] };
        } else return error.UnknownArgument;
    }
    const wall = readAll(io, gpa, wall_path);
    defer if (wall) |b| gpa.free(b);
    const serp = readAll(io, gpa, serp_path);
    defer if (serp) |b| gpa.free(b);

    const card_kind = std.meta.stringToEnum(cards.Kind, shot);
    const sc = script(shot);
    if (card_kind == null and sc == null) {
        std.debug.print("nanolight-promo: --shot= hook, panel, stats, end, screen-in or screen-out\n", .{});
        return error.UnknownShot;
    }
    var ix: Index = .init(gpa);
    defer ix.deinit();
    if (card_kind == .stats) ix.scan(io, init.environ_map.get("HOME")) else for (apps) |p| {
        const name = std.fs.path.stem(p);
        ix.add(name, p) catch {};
    }
    const screen = if (sc) |x| x.screen else false;
    // 1920×1080 for the video's own shots; the laptop's display is a
    // 13-inch MacBook Air's desktop (1470×956 points), 1838×1195 pixels.
    const w: f32 = if (screen) 1470 else 1280;
    const h: f32 = if (screen) 956 else 720;
    const scale: f32 = if (screen) 1.25 else 1.5;

    var s: view.Nanolight = .{ .index = &ix, .own_glass = true };
    defer s.query.deinit();
    var scene: Scene = .{ .s = &s, .w = w, .h = h, .screen = screen, .wall = wall, .wall_scale = scale, .serp = serp, .gpa = gpa };
    s.host = scene.host();
    var card: cards.Card = .{ .kind = card_kind orelse .end, .w = w, .h = h };
    var numbers: [2][48]u8 = undefined;
    if (card_kind == .stats) card.stats = .{
        .{ size, "the whole app" },
        .{ try std.fmt.bufPrint(&numbers[0], "{d:.0} µs", .{@ceil(slowest(&ix))}), try std.fmt.bufPrint(&numbers[1], "to rank all {d} apps, per key", .{ix.apps.items.len}) },
        .{ "Zig", "native · no Electron" },
    };

    var t: ui.Tester = undefined;
    const v: ui.View = if (card_kind != null) .init(&card, cards.Card.draw) else .init(&scene, Scene.draw);
    try t.init(gpa, v, .{ .width = w, .height = h, .scale = scale, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.dt = 1.0 / @as(f32, fps);
    t.time = 0;

    const len: f32 = if (sc) |x| x.len else switch (card.kind) {
        .hook => shots[0].len,
        .stats => shots[3].len,
        .end => shots[5].len,
    };
    const pre: f32 = if (sc) |x| x.pre else 0;
    const steps: []const Step = if (sc) |x| x.steps else &.{};
    const pre_frames: usize = @intFromFloat(@round(pre * fps));
    const frames: usize = pre_frames + @as(usize, @intFromFloat(@round(len * fps)));
    const clear_ops = [_]ui.TextOp{ .{ .command = .select_all }, .{ .command = .delete_backward } };
    const enter_ops = [_]ui.TextOp{.{ .command = .insert_newline }};
    const accept_ops = [_]ui.TextOp{.{ .command = .move_right }};
    var ops: [1]ui.TextOp = undefined;
    var next: usize = 0;
    const out = std.Io.File.stdout();
    for (0..frames) |i| {
        const now = @as(f32, @floatFromInt(i)) / fps - pre;
        scene.now = now;
        card.now = now;
        while (next < steps.len and steps[next].at <= now) : (next += 1) switch (steps[next].op) {
            .show => {
                scene.shown = true;
                s.reveal();
            },
            .caption => |cp| scene.caption = cp,
            .text => |ch| {
                ops[0] = .{ .insert = ch };
                t.ctx.input.ops = &ops;
            },
            .set => |q| s.query.set(q),
            .clear => {
                t.ctx.input.ops = &clear_ops;
                scene.key = "⌘A ⌫";
                scene.key_at = now;
            },
            .enter => {
                t.ctx.input.ops = &enter_ops;
                scene.key = "↩";
                scene.key_at = now;
            },
            .accept => {
                t.ctx.input.ops = &accept_ops;
                scene.key = "→";
                scene.key_at = now;
            },
            .key => |k| {
                t.ctx.shortcut_taken = false;
                t.ctx.input.shortcut = k.sc;
                scene.key = k.label;
                scene.key_at = now;
            },
        };
        t.frame();
        t.ctx.input.ops = &.{};
        t.ctx.input.shortcut = null;
        scene.google();
        if (i < pre_frames) continue;
        if (still) |st| {
            if (st.frame == i - pre_frames) return t.screenshot(st.path);
            continue;
        }
        const pixels = try t.render(gpa);
        defer pixels.deinit(gpa);
        try out.writeStreamingAll(io, pixels.bytes);
    }
}
