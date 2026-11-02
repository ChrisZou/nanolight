//! The promo's title cards: one idea a beat, a word slammed in on a flat
//! colour, in the icon's Bauhaus primaries. The hook (what it does, then
//! the key), the numbers, and the end.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const view = @import("view.zig");

pub const cream = ui.Color.hex(0xF0EBE0);
pub const yellow = ui.Color.hex(0xF2B705);
pub const red = ui.Color.hex(0xD7372A);
pub const ink = ui.Color.hex(0x1B1B1B);

pub const Kind = enum { hook, stats, end };

/// A word lands: big, then settled, in a quarter of a second.
const slam: motion.Motion = .{
    .initial = .{ .opacity = 0, .scale = 1.5 },
    .transition = .{ .spring = .{ .stiffness = 700, .damping = 34 } },
};
const rise: motion.Motion = .{
    .initial = .{ .opacity = 0, .y = 24 },
    .transition = .{ .spring = .{ .stiffness = 420, .damping = 32 } },
};

/// When each card's beats land (seconds into it): a cut, or a hit.
pub fn beats(kind: Kind) []const f32 {
    return switch (kind) {
        .hook => &.{ 0, 0.5, 1.0, 1.5, 2.0 },
        .stats => &.{ 0, 1, 2 },
        .end => &.{ 0, 0.25, 0.5 },
    };
}

pub const Card = struct {
    kind: Kind,
    w: f32,
    h: f32,
    /// Seconds into the card.
    now: f32 = 0,
    /// The numbers: what, and what it means.
    stats: [3][2][]const u8 = .{ .{ "", "" }, .{ "", "" }, .{ "", "" } },

    pub fn draw(d: *Card, c: *ui.Context) void {
        switch (d.kind) {
            .hook => d.hook(c),
            .stats => d.numbers(c),
            .end => d.end(c),
        }
    }

    fn beat(d: *const Card) usize {
        var n: usize = 0;
        for (beats(d.kind), 0..) |b, i| if (d.now >= b) {
            n = i;
        };
        return n;
    }

    fn hook(d: *Card, c: *ui.Context) void {
        const words = [_]struct { []const u8, ui.Color, ui.Color }{
            .{ "Find apps.", yellow, ink },
            .{ "Do math.", red, cream },
            .{ "Google it.", ink, cream },
            .{ "One key.", cream, ink },
        };
        const b = @min(d.beat(), words.len - 1);
        const wd = words[b];
        const root = ui.div(c).size(d.w, d.h).column().itemsCenter().justifyCenter().gap(40).bg(wd[1]);
        defer root.end();
        {
            ui.key(c, c.print("hook-{d}", .{b}));
            const t = ui.div(c).motion(motion.frame(c, slam));
            defer t.end();
            ui.text(c, wd[0], .{ .size = 150, .weight = .bold, .color = wd[2], .tracking = -5 });
        }
        if (b < 3) return;
        // The key, pressed on the last beat.
        ui.key(c, if (d.now >= 2.0) "keys-pressed" else "keys");
        const press: motion.Motion = if (d.now >= 2.0)
            .{ .initial = .{ .scale = 0.86, .y = 6 }, .transition = .{ .spring = .{ .stiffness = 600, .damping = 18 } } }
        else
            rise;
        const k = ui.div(c).row().gap(18).motion(motion.frame(c, press));
        defer k.end();
        keycap(c, "⌘", 130);
        keycap(c, "Space", 330);
    }

    fn numbers(d: *Card, c: *ui.Context) void {
        const tones = [_]ui.Color{ yellow, red, cream };
        const b = @min(d.beat(), 2);
        const root = ui.div(c).size(d.w, d.h).column().itemsCenter().justifyCenter().gap(18).bg(ink);
        defer root.end();
        ui.key(c, c.print("stat-{d}", .{b}));
        {
            const t = ui.div(c).motion(motion.frame(c, slam));
            defer t.end();
            ui.text(c, d.stats[b][0], .{ .size = 190, .weight = .bold, .color = tones[b], .tracking = -6, .tabular = true });
        }
        ui.key(c, c.print("stat-sub-{d}", .{b}));
        var r = rise;
        r.delay = 0.12;
        const s = ui.div(c).motion(motion.frame(c, r));
        defer s.end();
        ui.text(c, d.stats[b][1], .{ .size = 40, .weight = .semibold, .color = cream.alpha(0.85) });
    }

    fn end(d: *Card, c: *ui.Context) void {
        const root = ui.div(c).size(d.w, d.h).column().itemsCenter().justifyCenter().gap(22).bg(cream);
        defer root.end();
        {
            ui.key(c, "end-icon");
            const i = ui.div(c).motion(motion.frame(c, slam));
            defer i.end();
            view.appIcon(c, 150);
        }
        const lines = [_]struct { []const u8, f32, ui.Weight, ui.Color, f32 }{
            .{ "Nanolight", 120, .bold, ink, -4 },
            .{ "The ⌘Space launcher for your Mac.", 40, .semibold, ink.alpha(0.8), -0.5 },
        };
        for (lines, 0..) |l, i| {
            ui.key(c, c.print("end-{d}", .{i}));
            var r = rise;
            r.delay = 0.25 * @as(f32, @floatFromInt(i + 1));
            const t = ui.div(c).motion(motion.frame(c, r));
            defer t.end();
            ui.text(c, l[0], .{ .size = l[1], .weight = l[2], .color = l[3], .tracking = l[4] });
        }
        ui.key(c, "end-link");
        var r = rise;
        r.delay = 0.8;
        const row = ui.div(c).row().gap(16).pt(18).itemsCenter().motion(motion.frame(c, r));
        defer row.end();
        {
            const pill = ui.div(c).row().px(28).h(64).itemsCenter().roundedFull().bg(ink);
            defer pill.end();
            ui.text(c, "github.com/justrach/nanolight", .{ .size = 28, .weight = .semibold, .color = cream, .mono = true });
        }
        {
            const pill = ui.div(c).row().px(26).h(64).itemsCenter().roundedFull().bg(yellow);
            defer pill.end();
            ui.text(c, "Free · MIT · macOS 14+", .{ .size = 26, .weight = .bold, .color = ink });
        }
    }
};

/// A keyboard key, `w` points wide.
pub fn keycap(c: *ui.Context, label: []const u8, w: f32) void {
    const k = ui.div(c).w(w).h(130).center().rounded(26).bg(.white).border(ink.alpha(0.18))
        .shadows(&.{ .{ .color = ink.alpha(0.9), .blur = 0, .y = 10 }, .{ .color = .{ .a = 0.25 }, .blur = 30, .y = 18 } });
    defer k.end();
    ui.text(c, label, .{ .size = if (label.len > 3) 46 else 64, .weight = .semibold, .color = ink });
}
