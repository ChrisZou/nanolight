//! The panel's window on the Mac: a popover the shadow's margin bigger than
//! the panel, never resized (a window resized on every frame of the
//! height's spring shook as it searched: AppKit's new frame and Metal's
//! next drawable don't land together); only the system's vibrancy under the
//! panel follows its height. A menu bar app: no Dock icon.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const view = @import("view.zig");

/// The system's glass under the panel, which the window's views keep.
var glass: ?objc.Object = null;

pub fn adjust(o: *nanoui.WindowOptions, hidden: bool, h: f32) void {
    o.width = if (hidden) view.width else view.width + 2 * view.shadow_margin;
    o.height = if (hidden) h else view.max_height + 2 * view.shadow_margin;
    o.title_bar = .popover;
}

pub fn setup(app: *nanoui.App, w: *nanoui.Window, s: *view.Nanolight, h: f32) void {
    // A menu bar app: no Dock icon, no menu bar of its own.
    _ = objc.msg(objc.BOOL, app.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
    // The panel's own shadow, not the system's: a shadowed window in dark
    // mode gets a hard black outline round its pixels.
    s.margin = view.shadow_margin;
    s.window_fades = true;
    objc.msg(void, w.nswindow, "setHasShadow:", .{objc.NO});
    glass = backdrop(w, 18, h);
}

/// Where `place` last put the window (its frame's origin): if it isn't
/// there as it is placed again, it was dragged, and that is kept.
var placed: ?objc.CGPoint = null;
const key_x = "PanelOriginX";
const key_y = "PanelOriginY";

fn defaults() objc.Object {
    return objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
}

fn origin(w: *nanoui.Window) objc.CGPoint {
    return objc.msg(objc.CGRect, w.nswindow, "frame", .{}).origin;
}

/// Where the panel was dragged to, kept across launches, if it is still on
/// a screen (one may have been unplugged since).
fn dragged(w: *nanoui.Window) ?objc.CGPoint {
    const d = defaults();
    if (objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString(key_x)}) == null) return null;
    const at: objc.CGPoint = .{ .x = objc.msg(f64, d, "doubleForKey:", .{objc.nsString(key_x)}), .y = objc.msg(f64, d, "doubleForKey:", .{objc.nsString(key_y)}) };
    // The panel itself (the window less its shadow's margin), from its top.
    const f = objc.msg(objc.CGRect, w.nswindow, "frame", .{});
    const m = view.shadow_margin;
    const top: objc.CGRect = .{ .origin = .{ .x = at.x + m, .y = at.y + f.size.height - m - 60 }, .size = .{ .width = view.width, .height = 60 } };
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = objc.msg(objc.NSUInteger, screens, "count", .{});
    for (0..n) |i| {
        const s = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const v = objc.msg(objc.CGRect, s, "visibleFrame", .{});
        if (top.origin.x < v.origin.x + v.size.width and top.origin.x + top.size.width > v.origin.x and
            top.origin.y >= v.origin.y and top.origin.y + top.size.height <= v.origin.y + v.size.height) return at;
    }
    return null;
}

/// Forgets where the panel was dragged: back to where it first opens.
pub fn recenter(w: *nanoui.Window) void {
    const d = defaults();
    objc.msg(void, d, "removeObjectForKey:", .{objc.nsString(key_x)});
    objc.msg(void, d, "removeObjectForKey:", .{objc.nsString(key_y)});
    centered(w);
    placed = origin(w);
}

/// Where it was dragged to last, else a fifth of the way down the main
/// screen, centered.
pub fn place(w: *nanoui.Window) void {
    const now = origin(w);
    if (placed) |p| if (@abs(now.x - p.x) > 0.5 or @abs(now.y - p.y) > 0.5) {
        const d = defaults();
        objc.msg(void, d, "setDouble:forKey:", .{ now.x, objc.nsString(key_x) });
        objc.msg(void, d, "setDouble:forKey:", .{ now.y, objc.nsString(key_y) });
    };
    if (dragged(w)) |at| objc.msg(void, w.nswindow, "setFrameOrigin:", .{at}) else centered(w);
    placed = origin(w);
    // Unseen as it orders in: it still holds the frame it hid with, until
    // the next one is drawn (issue #9). `shown` fades it in.
    objc.msg(void, w.nswindow, "setAlphaValue:", .{@as(f64, 0)});
}

fn centered(w: *nanoui.Window) void {
    const screen = objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return;
    const f = objc.msg(objc.CGRect, screen, "frame", .{});
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const ph = objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
    const top = ph - (f.origin.y + f.size.height);
    // The panel there; the window is the shadow's margin bigger.
    w.setPosition(f.origin.x + (f.size.width - view.width) / 2 - view.shadow_margin, top + f.size.height * 0.2 - view.shadow_margin);
}

/// The glass to the panel's height, in the frame that draws it (a view's
/// frame, not the window's: nothing is laid out again).
pub fn resize(_: *nanoui.Window, h: f32) void {
    const g = glass orelse return;
    // No implicit layer animation: AppKit's would fight the next spring
    // tick and strobe the vibrancy.
    const tx = objc.class("CATransaction");
    objc.msg(void, tx, "begin", .{});
    objc.msg(void, tx, "setDisableActions:", .{objc.YES});
    objc.msg(void, g, "setFrame:", .{glassFrame(h)});
    objc.msg(void, tx, "commit", .{});
}

/// Whether the panel has the keys.
pub fn focused(w: *nanoui.Window) bool {
    return w.isFocused();
}

/// After `show`: the window fades in, the system's glass and the panel
/// together. The panel's entrance couldn't be drawn over that glass (it
/// is the system's, at full strength at once), so the window has it; the
/// fade also hides the frame left from the last showing while the panel
/// draws its new one.
pub fn shown(w: *nanoui.Window) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.class("NSAnimationContext");
    objc.msg(void, cls, "beginGrouping", .{});
    objc.msg(void, objc.msg(objc.Object, cls, "currentContext", .{}), "setDuration:", .{fade_s});
    objc.msg(void, objc.msg(objc.Object, w.nswindow, "animator", .{}), "setAlphaValue:", .{@as(f64, 1)});
    objc.msg(void, cls, "endGrouping", .{});
    // Whole once the fade is over, whatever became of it: a launcher
    // left see-through would be worse than one that didn't fade.
    nanoui.App.after(@intFromFloat(fade_s * 1000 + 80), w, struct {
        fn f(ctx: ?*anyopaque) callconv(.c) void {
            const win: *nanoui.Window = @ptrCast(@alignCast(ctx.?));
            if (win.isVisible()) objc.msg(void, win.nswindow, "setAlphaValue:", .{@as(f64, 1)});
        }
    }.f);
}

const fade_s: f64 = 0.12;

/// Puts the system's vibrancy under the panel (NSVisualEffectView, as
/// launchers use), `height` tall, the shadow's margin in. Not
/// NSGlassEffectView: on macOS 27 it draws an opaque 1-pixel black line
/// just outside its sides, which read as black edges round the panel.
fn backdrop(w: *nanoui.Window, radius: f64, height: f32) ?objc.Object {
    const surface = w.surface orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const b = objc.msg(objc.CGRect, surface.nsview, "bounds", .{});
    const v = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{b});
    // Popover: light or dark with the system, as the panel's colors are.
    objc.msg(void, v, "setMaterial:", .{@as(objc.NSInteger, 6)});
    objc.msg(void, v, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behind the window
    objc.msg(void, v, "setState:", .{@as(objc.NSInteger, 1)}); // always active
    // Rounded as the panel is.
    objc.msg(void, v, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, v, "layer", .{})) |layer| {
        objc.msg(void, layer, "setCornerRadius:", .{radius});
        objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    }
    surface.attachBackdrop(v);
    objc.release(v);
    // In a flipped host view, from the top; the window never resizes.
    objc.msg(void, v, "setAutoresizingMask:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, v, "setFrame:", .{glassFrame(height)});
    return v;
}

/// Where the glass goes: under the panel, the shadow's margin in.
fn glassFrame(h: f32) objc.CGRect {
    const m = view.shadow_margin;
    return .{ .origin = .{ .x = m, .y = m }, .size = .{ .width = view.width, .height = h } };
}
