//! Public AppKit/AX/CGEvent APIs. The paste pattern follows Maccy's
//! Clipboard.paste: https://github.com/p0deje/Maccy/blob/master/Maccy/Clipboard.swift
//! AX permission belongs to the signed app: System Settings > Privacy &
//! Security > Accessibility > Nanolight. Request only on a paste attempt.
const objc = @import("nanoui").objc;

extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn AXIsProcessTrustedWithOptions(objc.Object) bool;
extern "c" const kAXTrustedCheckOptionPrompt: objc.Object;
extern "c" fn CGEventSourceFlagsState(i32) u64;
extern "c" fn CGEventCreateKeyboardEvent(?*anyopaque, u16, bool) ?*anyopaque;
extern "c" fn CGEventSetFlags(*anyopaque, u64) void;
extern "c" fn CGEventPostToPid(i32, *anyopaque) void;
extern "c" fn CFRelease(*anyopaque) void;

pub fn trusted(prompt: bool) bool {
    if (!prompt) return AXIsProcessTrusted();
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    const options = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ yes, kAXTrustedCheckOptionPrompt });
    return AXIsProcessTrustedWithOptions(options);
}

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
