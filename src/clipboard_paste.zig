//! Public AppKit/AX/CGEvent APIs. The paste pattern follows Maccy's
//! Clipboard.paste: https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift
//! AX permission belongs to the signed app: System Settings > Privacy &
//! Security > Accessibility > Nanolight. Request only on a paste attempt.
const std = @import("std");
const objc = @import("nanoui").objc;

extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn AXIsProcessTrustedWithOptions(objc.Object) bool;
extern "c" const kAXTrustedCheckOptionPrompt: objc.Object;
extern "c" fn CGEventSourceFlagsState(i32) u64;
extern "c" fn CGEventSourceCounterForEventType(i32, u32) u32;
extern "c" fn CGEventCreateKeyboardEvent(?*anyopaque, u16, bool) ?*anyopaque;
extern "c" fn CGEventSetFlags(*anyopaque, u64) void;
extern "c" fn CGEventPostToPid(i32, *anyopaque) void;
extern "c" fn CFRelease(*anyopaque) void;
extern "c" fn CFEqual(*anyopaque, *anyopaque) bool;
extern "c" fn CFGetTypeID(*anyopaque) usize;
extern "c" fn CFStringGetTypeID() usize;
extern "c" fn CFBooleanGetTypeID() usize;
extern "c" fn CFBooleanGetValue(*anyopaque) bool;
extern "c" fn CFArrayGetTypeID() usize;
extern "c" fn CFArrayGetCount(*anyopaque) isize;
extern "c" fn AXUIElementCreateApplication(i32) ?*anyopaque;
extern "c" fn AXUIElementCopyAttributeValue(*anyopaque, objc.Object, *?*anyopaque) i32;
extern "c" fn AXUIElementSetMessagingTimeout(*anyopaque, f32) i32;

fn axAttribute(element: *anyopaque, name: []const u8) ?*anyopaque {
    var value: ?*anyopaque = null;
    if (AXUIElementCopyAttributeValue(element, objc.nsString(name), &value) != 0) return null;
    return value;
}

fn axString(value: *anyopaque) ?[]const u8 {
    if (CFGetTypeID(value) != CFStringGetTypeID()) return null;
    return objc.fromNSString(@ptrCast(value));
}

pub fn trusted(prompt: bool) bool {
    if (!prompt) return AXIsProcessTrusted();
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    const options = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ yes, kAXTrustedCheckOptionPrompt });
    return AXIsProcessTrustedWithOptions(options);
}

/// Counts physical key/click events without recording their contents. Taking
/// the snapshot inside the action includes its triggering Return/click; only
/// later activity cancels an asynchronous paste.
pub const Activity = struct {
    counts: [4]u32,

    pub fn capture() Activity {
        var activity: Activity = undefined;
        for ([_]u32{ 10, 1, 3, 25 }, 0..) |kind, i|
            activity.counts[i] = CGEventSourceCounterForEventType(1, kind);
        return activity;
    }

    pub fn unchanged(activity: Activity) bool {
        return std.mem.eql(u32, &activity.counts, &capture().counts);
    }
};

pub const Target = struct {
    app: ?objc.Object = null,

    pub fn deinit(t: *Target) void {
        if (t.app) |a| objc.msg(void, a, "release", .{});
        t.app = null;
    }

    /// Before showing either mode. Keep the original target when switching
    /// modes inside Nanolight; never paste into the launcher's own field.
    pub fn remember(t: *Target) void {
        const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
        const a = objc.msg(?objc.Object, ws, "frontmostApplication", .{}) orelse return;
        const own = objc.msg(objc.Object, objc.class("NSRunningApplication"), "currentApplication", .{});
        if (objc.msg(i32, a, "processIdentifier", .{}) == objc.msg(i32, own, "processIdentifier", .{})) return;
        _ = objc.msg(objc.Object, a, "retain", .{});
        t.deinit();
        t.app = a;
    }

    /// Resolve an explicit installed app, never whichever process happens
    /// to receive focus while a URL is opening. Ambiguous instances fail.
    pub fn rememberBundle(t: *Target, bundle: []const u8, path: []const u8) bool {
        t.deinit();
        const apps = objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{objc.nsString(bundle)});
        var found: ?objc.Object = null;
        for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
            const app = objc.msg(objc.Object, apps, "objectAtIndex:", .{i});
            if (objc.msg(objc.BOOL, app, "isTerminated", .{})) continue;
            const url = objc.msg(?objc.Object, app, "bundleURL", .{}) orelse continue;
            const actual = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
            if (!std.mem.eql(u8, actual, path)) continue;
            if (found != null) return false;
            found = app;
        }
        const app = found orelse return false;
        _ = objc.msg(objc.Object, app, "retain", .{});
        t.app = app;
        return true;
    }

    /// Warp sets the native window title from its active tab title. A unique
    /// title therefore identifies this handoff without relying on AX tabs,
    /// which Warp's custom UI does not expose. This checks the destination,
    /// not whether the custom input has consumed a posted paste event.
    pub fn windowMatches(t: *const Target, marker: []const u8) bool {
        if (marker.len == 0 or !t.ready() or !trusted(false)) return false;
        const app = AXUIElementCreateApplication(objc.msg(i32, t.app.?, "processIdentifier", .{})) orelse return false;
        defer CFRelease(app);
        _ = AXUIElementSetMessagingTimeout(app, 0.1);
        const window = axAttribute(app, "AXFocusedWindow") orelse return false;
        defer CFRelease(window);
        const role = axAttribute(window, "AXRole") orelse return false;
        defer CFRelease(role);
        if (!std.mem.eql(u8, axString(role) orelse return false, "AXWindow")) return false;
        const title = axAttribute(window, "AXTitle") orelse return false;
        defer CFRelease(title);
        if (!std.mem.eql(u8, axString(title) orelse return false, marker)) return false;
        if (axAttribute(window, "AXModal")) |modal| {
            defer CFRelease(modal);
            if (CFGetTypeID(modal) != CFBooleanGetTypeID() or CFBooleanGetValue(modal)) return false;
        }
        if (axAttribute(window, "AXSheets")) |sheets| {
            defer CFRelease(sheets);
            if (CFGetTypeID(sheets) != CFArrayGetTypeID() or CFArrayGetCount(sheets) != 0) return false;
        }
        if (axAttribute(app, "AXFocusedUIElement")) |focused| {
            defer CFRelease(focused);
            if (axAttribute(focused, "AXWindow")) |focused_window| {
                defer CFRelease(focused_window);
                if (!CFEqual(window, focused_window)) return false;
            }
            if (axAttribute(focused, "AXRole")) |focused_role| {
                defer CFRelease(focused_role);
                const name = axString(focused_role) orelse return false;
                for ([_][]const u8{ "AXButton", "AXMenu", "AXMenuItem", "AXSheet", "AXDialog" }) |blocked| {
                    if (std.mem.eql(u8, name, blocked)) return false;
                }
                // Warp exposes its rendering surface as a text area directly
                // under the window. Its value describes the whole terminal.
                const warp_surface = std.mem.eql(u8, name, "AXTextArea") and surface: {
                    const parent = axAttribute(focused, "AXParent") orelse break :surface false;
                    defer CFRelease(parent);
                    break :surface CFEqual(parent, window);
                };
                if (!warp_surface and (std.mem.eql(u8, name, "AXTextField") or std.mem.eql(u8, name, "AXTextArea"))) {
                    if (axAttribute(focused, "AXValue")) |value| {
                        defer CFRelease(value);
                        if (axString(value)) |text| if (text.len != 0) return false;
                    }
                }
            }
        }
        return t.ready();
    }

    pub fn valid(t: *const Target) bool {
        const a = t.app orelse return false;
        return !objc.msg(objc.BOOL, a, "isTerminated", .{});
    }

    pub fn activate(t: *const Target) bool {
        if (!t.valid()) return false;
        return objc.msg(objc.BOOL, t.app.?, "activateWithOptions:", .{@as(objc.NSUInteger, 2)});
    }

    pub fn ready(t: *const Target) bool {
        if (!t.valid() or !objc.msg(objc.BOOL, t.app.?, "isActive", .{})) return false;
        // Wait out Return and hotkey modifiers so ⇧⌘V never becomes the
        // target app's Paste and Match Style command.
        return CGEventSourceFlagsState(1) & ((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)) == 0;
    }

    pub fn send(t: *const Target) !void {
        if (!t.ready() or !trusted(false)) return error.PasteUnavailable;
        const down = CGEventCreateKeyboardEvent(null, 9, true) orelse return error.EventUnavailable;
        defer CFRelease(down);
        const up = CGEventCreateKeyboardEvent(null, 9, false) orelse return error.EventUnavailable;
        defer CFRelease(up);
        CGEventSetFlags(down, (1 << 20) | 0x8);
        CGEventSetFlags(up, (1 << 20) | 0x8);
        const pid = objc.msg(i32, t.app.?, "processIdentifier", .{});
        // Address the remembered process as well as checking focus: a
        // focus change cannot deliver a delayed paste to another app.
        CGEventPostToPid(pid, down);
        CGEventPostToPid(pid, up);
    }
};
