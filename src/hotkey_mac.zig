//! A key combination the whole system hands to this app, from any app:
//! Carbon's hot keys, which every launcher uses (they need no
//! Accessibility permission, and the keys go to no other app).
const std = @import("std");

const EventTypeSpec = extern struct { class: u32, kind: u32 };
const HotKeyId = extern struct { signature: u32, id: u32 };
const Handler = *const fn (call: ?*anyopaque, event: ?*anyopaque, user: ?*anyopaque) callconv(.c) i32;

extern "c" fn GetApplicationEventTarget() ?*anyopaque;
extern "c" fn InstallEventHandler(target: ?*anyopaque, handler: Handler, count: u32, list: [*]const EventTypeSpec, user: ?*anyopaque, out: ?*?*anyopaque) i32;
extern "c" fn RegisterEventHotKey(key_code: u32, modifiers: u32, id: HotKeyId, target: ?*anyopaque, options: u32, out: *?*anyopaque) i32;
extern "c" fn UnregisterEventHotKey(ref: ?*anyopaque) i32;
extern "c" fn GetEventParameter(event: ?*anyopaque, name: u32, kind: u32, actual: ?*u32, size: u32, actual_size: ?*u32, data: *HotKeyId) i32;

/// Carbon's modifier bits.
pub const cmd: u32 = 1 << 8;
pub const shift: u32 = 1 << 9;
pub const option: u32 = 1 << 11;
pub const control: u32 = 1 << 12;
/// kVK_Space.
pub const space: u32 = 49;

pub const Pressed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

/// Slot 0 is the launcher's key, slot 1 the clipboard's ⌘⇧V.
var pressed: [2]?Pressed = .{ null, null };
var installed = false;
var current: [2]?*anyopaque = .{ null, null };

fn handle(_: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    var id: HotKeyId = undefined;
    if (GetEventParameter(event, fourcc("----"), fourcc("hkid"), null, @sizeOf(HotKeyId), null, &id) != 0) return -9874;
    return dispatch(id);
}

fn dispatch(id: HotKeyId) i32 {
    if (id.signature != fourcc("nsPL") or id.id < 1 or id.id > pressed.len) return -9874;
    if (pressed[id.id - 1]) |p| p.func(p.ctx);
    return 0;
}

/// Calls `on` on the main thread each time `key` with `modifiers` is
/// pressed. Registering again replaces only the launcher key. Carbon
/// grants it even when another app holds the same keys (`shortcut.zig`
/// looks for those).
pub fn registerKey(key: u32, modifiers: u32, on: Pressed) !void {
    try registerSlot(0, key, modifiers, on);
}

/// `choice`'s key with its modifiers (hotkey.zig).
pub fn register(choice: @import("shortcut.zig").Choice, on: Pressed) !void {
    return registerKey(choice.code, choice.mods, on);
}

/// ⌘⇧V (kVK_ANSI_V), independent of the launcher's key.
pub fn registerClipboard(on: Pressed) !void {
    try registerSlot(1, 9, cmd | shift, on);
}

/// Gives the launcher's key back (while another is recorded); `register`
/// takes one again. The clipboard's key stays.
pub fn unregister() void {
    if (current[0]) |r| _ = UnregisterEventHotKey(r);
    current[0] = null;
}

fn registerSlot(slot: usize, key: u32, modifiers: u32, on: Pressed) !void {
    if (!installed) {
        const spec = [_]EventTypeSpec{.{ .class = fourcc("keyb"), .kind = 5 }}; // kEventHotKeyPressed
        if (InstallEventHandler(GetApplicationEventTarget(), &handle, 1, &spec, null, null) != 0) return error.HandlerFailed;
        installed = true;
    }
    if (current[slot]) |r| _ = UnregisterEventHotKey(r);
    current[slot] = null;
    pressed[slot] = on;
    // Exclusive registration fails if another app already owns ⇧⌘V,
    // instead of silently opening two clipboard viewers on the same key.
    const options: u32 = if (slot == 1) 1 else 0;
    if (RegisterEventHotKey(key, modifiers, .{ .signature = fourcc("nsPL"), .id = @intCast(slot + 1) }, GetApplicationEventTarget(), options, &current[slot]) != 0) {
        pressed[slot] = null;
        return error.HotKeyTaken;
    }
}

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

test "four characters read as Carbon's codes" {
    try std.testing.expectEqual(@as(u32, 0x6B657962), fourcc("keyb"));
}

test "Carbon ids dispatch independently and ignore foreign events" {
    const Counter = struct {
        n: usize = 0,
        fn hit(ctx: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.n += 1;
        }
    };
    var launcher: Counter = .{};
    var clips: Counter = .{};
    const saved = pressed;
    defer pressed = saved;
    pressed = .{ .{ .ctx = &launcher, .func = Counter.hit }, .{ .ctx = &clips, .func = Counter.hit } };
    _ = dispatch(.{ .signature = fourcc("nsPL"), .id = 2 });
    try std.testing.expectEqual(@as(usize, 0), launcher.n);
    try std.testing.expectEqual(@as(usize, 1), clips.n);
    _ = dispatch(.{ .signature = fourcc("nsPL"), .id = 1 });
    try std.testing.expectEqual(@as(usize, 1), launcher.n);
    try std.testing.expectEqual(@as(usize, 1), clips.n);
    _ = dispatch(.{ .signature = fourcc("else"), .id = 2 });
    _ = dispatch(.{ .signature = fourcc("nsPL"), .id = 0 });
    _ = dispatch(.{ .signature = fourcc("nsPL"), .id = 3 });
    try std.testing.expectEqual(@as(usize, 1), clips.n);
}
