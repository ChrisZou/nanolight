//! The promo: 30 seconds at 60 fps. The interface is the shot: Apple's
//! MacBook Air (Blender, tools/promo/laptop.py) pushes into its display as
//! ⌘Space opens the panel, then the panel fills the frame and one thing is
//! done a shot, the camera easing in and out on an S-curve and a loupe
//! lifting the one detail that matters. Labels are small and quiet; the
//! end is the panel becoming the icon beside the name. (After a study of
//! Apple's, Raycast's, Linear's and Cursor's launch films, and Emil
//! Kowalski's easing: docs/promo.md.)
//!
//! Everything is drawn by nanoui offscreen, the panel by the app's own
//! code driven by keys through a Tester: no window shows, nothing opens.
//!
//!     tools/promo.sh                                  # the whole video
//!     zig-out/bin/nanolight-promo --shot=screen > f.bgra   # 1838×1195, the display
//!     zig-out/bin/nanolight-promo --shot=main [--from=S --to=S] > f.bgra  # 1920×1080
//!     zig-out/bin/nanolight-promo --cues              # when sounds land
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const cam = @import("promo_camera.zig");
const scene_mod = @import("promo_scene.zig");
const Scene = scene_mod.Scene;
const Label = scene_mod.Label;

pub const fps = 60;
pub const total: f32 = 30;
/// The laptop's shot is the first `laptop` seconds; the main shot takes
/// over from `main_from` (they cross for the difference).
pub const laptop: f32 = 3.4;
pub const main_from: f32 = 3.2;
/// When the panel opens on the laptop's display.
pub const open_at: f32 = 1.4;
pub const end_at: f32 = 24.4;

const S = ui.Shortcut;

const Op = union(enum) {
    show,
    label: struct { []const u8, []const u8 },
    text: []const u8,
    clear,
    enter,
    accept,
    key: struct { sc: ui.Shortcut, label: []const u8 },
    end,
};

const Step = struct { at: f32, op: Op };

fn typing(comptime at: f32, comptime str: []const u8, comptime every: f32) [str.len]Step {
    var out: [str.len]Step = undefined;
    // Human: a little uneven, every third key a touch slower.
    for (str, 0..) |_, i| out[i] = .{ .at = at + every * @as(f32, @floatFromInt(i)) + if (i % 3 == 2) every * 0.35 else 0, .op = .{ .text = str[i .. i + 1] } };
    return out;
}

fn say(text: []const u8, key: []const u8) Op {
    return .{ .label = .{ text, key } };
}

const down: Op = .{ .key = .{ .sc = .{ .key = S.down }, .label = "↓" } };
const tab: Op = .{ .key = .{ .sc = .{ .key = S.tab }, .label = "Tab" } };
const esc: Op = .{ .key = .{ .sc = .{ .key = S.escape }, .label = "esc" } };

/// The main shot, in seconds into the video.
const script = [_]Step{
    .{ .at = 2.4, .op = .show },
    .{ .at = 4.0, .op = say("Any app, as you type", "") },
} ++ typing(4.0, "saf", 0.11) ++ [_]Step{
    .{ .at = 4.8, .op = .accept },
    .{ .at = 4.8, .op = say("Any app, as you type", "→") },
    .{ .at = 5.6, .op = .clear },
    .{ .at = 5.8, .op = say("Initials: ss is System Settings", "") },
} ++ typing(5.8, "ss", 0.16) ++ [_]Step{
    .{ .at = 7.0, .op = .clear },
    .{ .at = 7.2, .op = say("Typos, forgiven", "") },
} ++ typing(7.2, "chorme", 0.11) ++ [_]Step{
    .{ .at = 8.8, .op = .clear },
    .{ .at = 9.0, .op = say("Math, as you type", "") },
} ++ typing(9.0, "2^10 * 3", 0.075) ++ [_]Step{
    .{ .at = 10.7, .op = .enter },
    .{ .at = 10.7, .op = say("Copied", "↩") },
    .{ .at = 12.1, .op = .clear },
    .{ .at = 12.4, .op = say("Google suggests as you type", "") },
} ++ typing(12.4, "liquid gl", 0.09) ++ [_]Step{
    .{ .at = 14.3, .op = tab },
    .{ .at = 14.3, .op = say("Tab takes the suggestion", "Tab") },
    .{ .at = 16.0, .op = .enter },
    .{ .at = 16.0, .op = say("Results, right in the panel", "↩") },
    .{ .at = 19.2, .op = esc },
    .{ .at = 19.2, .op = say("", "") },
    .{ .at = 19.5, .op = .clear },
} ++ typing(19.7, "best ramen", 0.065) ++ [_]Step{
    .{ .at = 20.6, .op = down },
    .{ .at = 20.6, .op = say("Ask Grok. Search X.", "↓") },
    .{ .at = 21.25, .op = down },
    .{ .at = 22.4, .op = say("", "") },
    .{ .at = 22.6, .op = esc },
    .{ .at = end_at, .op = .end },
};

/// The laptop's display: the desktop, then ⌘Space.
const screen_script = [_]Step{.{ .at = open_at, .op = .show }};

const centre: cam.View = .{ .zoom = 1, .cx = scene_mod.width / 2, .cy = scene_mod.height / 2 };
/// How close the camera means to be: eased between these on an S-curve.
/// It never goes closer than keeps the panel and its label in frame
/// (`follow`), so a list that grows pulls it back.
fn closer(z: f32) cam.View {
    return .{ .zoom = z, .cx = centre.cx, .cy = centre.cy };
}
const moves = [_]cam.Move{
    .{ .at = 3.9, .len = 1.3, .to = closer(1.45) },
    .{ .at = 8.8, .len = 0.9, .to = closer(1.5) },
    .{ .at = 12.1, .len = 0.9, .to = closer(1.6) },
    .{ .at = 15.95, .len = 0.9, .to = closer(1.0) },
    .{ .at = 19.4, .len = 0.9, .to = closer(1.6) },
    .{ .at = 22.5, .len = 1.0, .to = closer(1.15) },
};

/// The camera on the panel: the zoom meant now, but no closer than fits
/// the panel (its top, its springing height) and its label, and centred
/// on them.
fn frame(sc: *const Scene, now: f32) cam.View {
    const meant = cam.camera(centre, &moves, now).zoom;
    const top = sc.top - 26;
    const bottom = sc.top + sc.s.last_h + scene_mod.label_room;
    const fit = scene_mod.height / (bottom - top);
    return .{ .zoom = @max(1, @min(meant, fit)), .cx = centre.cx, .cy = (top + bottom) / 2 };
}

/// What each loupe lifts: text the scene shows (found as it opens), else
/// a stage point.
const Lift = struct { loupe: cam.Loupe, find: []const u8 = "", dy: f32 = 0 };
const lifts = [_]Lift{
    .{ .loupe = .{ .at = 9.9, .mag = 1.65, .hold = 1.0 }, .find = "3,072", .dy = 14 },
    // The faint completion, then Tab making it the query's.
    .{ .loupe = .{ .at = 13.75, .mag = 1.8, .hold = 0.55, .x = scene_mod.panel_x + 150, .y = scene_mod.panel_top + 29, .w = 900, .h = 220 } },
};

/// The apps the panel finds: Apple's own and Chrome (the typo's), the same
/// on any Mac, rather than whatever this one has.
const apps = [_][]const u8{
    "/Applications/Safari.app",                            "/Applications/Google Chrome.app",
    "/System/Applications/System Settings.app",            "/System/Applications/Calculator.app",
    "/System/Applications/Calendar.app",                   "/System/Applications/Mail.app",
    "/System/Applications/Maps.app",                       "/System/Applications/Messages.app",
    "/System/Applications/Music.app",                      "/System/Applications/Notes.app",
    "/System/Applications/Photos.app",                     "/System/Applications/FaceTime.app",
    "/System/Library/CoreServices/Finder.app",             "/System/Applications/App Store.app",
    "/System/Applications/Books.app",                      "/System/Applications/Freeform.app",
    "/System/Applications/Preview.app",                    "/System/Applications/Reminders.app",
    "/System/Applications/Shortcuts.app",                  "/System/Applications/Utilities/Terminal.app",
    "/System/Applications/Utilities/Activity Monitor.app", "/System/Applications/Weather.app",
    "/System/Applications/Podcasts.app",                   "/System/Applications/TV.app",
    "/System/Applications/TextEdit.app",                   "/System/Applications/Contacts.app",
};

fn isKey(op: Op) bool {
    return switch (op) {
        .text, .clear, .enter, .accept, .key => true,
        else => false,
    };
}

/// When sounds land, in seconds into the video: `key`, `tab`, `enter` for
/// keys, `open` as the panel opens, `lift` as a loupe does, `page` as
/// Google's page shows, `cross` where the laptop gives way, and `end`,
/// `name` for the end.
fn cues(io: std.Io) !void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    // ⌘Space, then the panel.
    try o.print("key {d:.3}\nopen {d:.3}\ncross {d:.3}\n", .{ open_at - 0.12, open_at, main_from });
    for (script) |st| if (isKey(st.op) and st.at >= main_from) {
        const kind = switch (st.op) {
            .key => |k| if (k.sc.key == S.tab) "tab" else "key",
            .enter => "enter",
            else => "key",
        };
        try o.print("{s} {d:.3}\n", .{ kind, st.at });
    };
    for (lifts) |l| try o.print("lift {d:.3}\n", .{l.loupe.at});
    try o.print("page {d:.3}\nend {d:.3}\nname {d:.3}\n", .{ 16.35, end_at, end_at + 0.7 });
    try o.flush();
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
    var from: f32 = -1;
    var to: f32 = -1;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cues")) return cues(io);
        if (std.mem.startsWith(u8, arg, "--shot=")) shot = arg[7..] else if (std.mem.startsWith(u8, arg, "--wall=")) wall_path = arg[7..] else if (std.mem.startsWith(u8, arg, "--serp=")) serp_path = arg[7..] else if (std.mem.startsWith(u8, arg, "--from=")) from = try std.fmt.parseFloat(f32, arg[7..]) else if (std.mem.startsWith(u8, arg, "--to=")) to = try std.fmt.parseFloat(f32, arg[5..]) else return error.UnknownArgument;
    }
    const screen = std.mem.eql(u8, shot, "screen");
    if (!screen and !std.mem.eql(u8, shot, "main")) {
        std.debug.print("nanolight-promo: --shot=main or --shot=screen\n", .{});
        return error.UnknownShot;
    }
    const wall = readAll(io, gpa, wall_path);
    defer if (wall) |b| gpa.free(b);
    const serp = readAll(io, gpa, serp_path);
    defer if (serp) |b| gpa.free(b);

    var ix: Index = .init(gpa);
    defer ix.deinit();
    for (apps) |p| ix.add(std.fs.path.stem(p), p) catch {};

    var s: view.Nanolight = .{ .index = &ix, .own_glass = true };
    defer s.query.deinit();
    var sc: Scene = .{ .s = &s, .gpa = gpa, .wall = wall, .serp = serp, .screen = screen };
    // The display is a 13-inch MacBook Air's desktop (1470×956 points).
    if (screen) {
        sc.w = 1470;
        sc.h = 956;
    }
    s.host = sc.host();
    const scale: f32 = if (screen) 1.25 else 3840.0 / scene_mod.width;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&sc, Scene.draw), .{ .width = sc.w, .height = sc.h, .scale = scale, .theme = ui.Theme.dark_theme });
    defer t.deinit();
    t.dt = 1.0 / @as(f32, fps);

    const steps: []const Step = if (screen) &screen_script else &script;
    // The main shot runs from before it is seen, so the panel has opened.
    const start: f32 = if (screen) 0 else 2.2;
    const first: f32 = if (from >= 0) from else if (screen) 0 else main_from;
    const last: f32 = if (to >= 0) to else if (screen) laptop else total;
    t.time = start;
    const lens: cam.Lens = .{ .stage_w = scene_mod.width, .stage_h = scene_mod.height, .out_w = 1920, .out_h = 1080 };
    var out_buf: []u8 = &.{};
    if (!screen) out_buf = try gpa.alloc(u8, 1920 * 1080 * 4);
    defer if (!screen) gpa.free(out_buf);
    var found: [lifts.len]?[2]f32 = @splat(null);

    const clear_ops = [_]ui.TextOp{ .{ .command = .select_all }, .{ .command = .delete_backward } };
    const enter_ops = [_]ui.TextOp{.{ .command = .insert_newline }};
    const accept_ops = [_]ui.TextOp{.{ .command = .move_right }};
    var ops: [1]ui.TextOp = undefined;
    var next: usize = 0;
    const out = std.Io.File.stdout();
    var i: u32 = 0;
    while (true) : (i += 1) {
        const now = start + @as(f32, @floatFromInt(i)) / fps;
        if (now >= last - 0.5 / @as(f32, fps)) break;
        sc.now = now;
        // Followed smoothly, as an editor's auto-zoom does (a fifth of a
        // second to settle), from the frame before's panel.
        const want = frame(&sc, now);
        const settle: f32 = if (i == 0) 1 else 1 - @exp(-1.0 / (@as(f32, fps) * 0.16));
        sc.view = .{ .zoom = cam.mix(sc.view.zoom, want.zoom, settle), .cx = want.cx, .cy = cam.mix(sc.view.cy, want.cy, settle) };
        while (next < steps.len and steps[next].at <= now) : (next += 1) switch (steps[next].op) {
            .show => {
                sc.shown = true;
                s.reveal();
            },
            .label => |l| {
                // The same words keep their place; only the key changes.
                const same = if (sc.label) |old| std.mem.eql(u8, old.text, l[0]) else false;
                sc.label = .{ .text = l[0], .key = l[1], .at = if (same) sc.label.?.at else now };
            },
            .text => |ch| {
                ops[0] = .{ .insert = ch };
                t.ctx.input.ops = &ops;
            },
            .clear => t.ctx.input.ops = &clear_ops,
            .enter => t.ctx.input.ops = &enter_ops,
            .accept => t.ctx.input.ops = &accept_ops,
            .key => |k| {
                t.ctx.shortcut_taken = false;
                t.ctx.input.shortcut = k.sc;
            },
            .end => sc.end_at = now,
        };
        t.frame();
        t.ctx.input.ops = &.{};
        t.ctx.input.shortcut = null;
        sc.google();
        if (now < first - 0.5 / @as(f32, fps)) continue;
        const pixels = try t.render(gpa);
        defer pixels.deinit(gpa);
        if (screen) {
            try out.writeStreamingAll(io, pixels.bytes);
            continue;
        }
        // The loupe open now, if one is: where its text is, found as it opens.
        var lit: ?cam.Lit = null;
        for (lifts, 0..) |lf, k| {
            const a = lf.loupe.amount(now);
            if (a <= 0) continue;
            if (found[k] == null) {
                var p: [2]f32 = .{ lf.loupe.x, lf.loupe.y };
                if (lf.find.len > 0) if (t.findText(lf.find)) |r| {
                    p = .{ r.x + r.w / 2, r.y + r.h / 2 + lf.dy };
                };
                found[k] = p;
            }
            const at = found[k].?;
            const o = lens.toOut(lens.clamp(sc.view), at[0], at[1]);
            lit = (cam.Lit{ .ox = o[0], .oy = o[1], .x = at[0], .y = at[1], .mag = lf.loupe.mag, .a = a, .w = lf.loupe.w, .h = lf.loupe.h }).placed(lens);
        }
        cam.shoot(.{ .bytes = pixels.bytes, .w = pixels.width, .h = pixels.height, .px_per_pt = scale }, lens, sc.view, lit, i, out_buf);
        try out.writeStreamingAll(io, out_buf);
    }
}

test {
    _ = cam;
}
