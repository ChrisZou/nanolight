//! Which key combination opens the panel, kept in the app's defaults, and
//! who else may answer it. Carbon grants a hot key even when another app
//! holds the same one, so clashes are found here instead: in the system's
//! own shortcuts (Spotlight's ⌘Space, the input sources' ⌃Space) and among
//! the launchers that are running.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const hotkey = @import("hotkey.zig");
const mac = builtin.os.tag == .macos;
const objc = nanoui.objc;

pub const Choice = enum {
    cmd_space,
    opt_space,
    ctrl_space,
    opt_cmd_space,

    pub const all = [_]Choice{ .cmd_space, .opt_space, .ctrl_space, .opt_cmd_space };

    pub fn label(c: Choice) []const u8 {
        return switch (c) {
            .cmd_space => "⌘ Space",
            .opt_space => "⌥ Space",
            .ctrl_space => "⌃ Space",
            .opt_cmd_space => "⌥ ⌘ Space",
        };
    }

    /// The modifier glyphs alone, for a key cap.
    pub fn mods(c: Choice) []const u8 {
        return switch (c) {
            .cmd_space => "⌘",
            .opt_space => "⌥",
            .ctrl_space => "⌃",
            .opt_cmd_space => "⌥⌘",
        };
    }

    /// Carbon's modifier bits.
    pub fn carbon(c: Choice) u32 {
        return switch (c) {
            .cmd_space => hotkey.cmd,
            .opt_space => hotkey.option,
            .ctrl_space => hotkey.control,
            .opt_cmd_space => hotkey.option | hotkey.cmd,
        };
    }

    /// AppKit's modifier flags, as the system's shortcut table keeps them.
    pub fn appkit(c: Choice) u64 {
        return switch (c) {
            .cmd_space => ns_cmd,
            .opt_space => ns_opt,
            .ctrl_space => ns_ctrl,
            .opt_cmd_space => ns_opt | ns_cmd,
        };
    }
};

const ns_ctrl: u64 = 1 << 18;
const ns_opt: u64 = 1 << 19;
const ns_cmd: u64 = 1 << 20;
const ns_mods: u64 = (1 << 17) | ns_ctrl | ns_opt | ns_cmd;

const store_key = "nanolight.hotkey";
const onboarded_key = "nanolight.onboarded";

pub fn load(store: nanoui.kv.Store, gpa: std.mem.Allocator) Choice {
    const v = (store.get(gpa, store_key) catch null) orelse return .cmd_space;
    defer gpa.free(v);
    return std.meta.stringToEnum(Choice, v) orelse .cmd_space;
}

pub fn save(store: nanoui.kv.Store, c: Choice) void {
    store.set(store_key, @tagName(c)) catch {};
}

pub fn onboarded(store: nanoui.kv.Store) bool {
    return store.has(onboarded_key);
}

pub fn setOnboarded(store: nanoui.kv.Store) void {
    store.set(onboarded_key, "1") catch {};
}

/// One of the system's shortcuts, as `com.apple.symbolichotkeys` keeps it.
pub const SystemKey = struct { id: u32, enabled: bool, key: u32, mods: u64 };

/// The launchers that are running, by name.
pub const Others = struct {
    names: [6][]const u8 = undefined,
    n: usize = 0,

    pub fn slice(o: *const Others) []const []const u8 {
        return o.names[0..o.n];
    }
};

/// What is in the way of a choice: a system shortcut that takes it first,
/// and launchers that may be using it too.
pub const Clash = struct {
    /// "Spotlight", "Input sources"…, when the system takes it.
    system: ?[]const u8 = null,
    /// The system's shortcut id (Keyboard Shortcuts in System Settings).
    system_id: u32 = 0,
    launchers: []const []const u8 = &.{},

    pub fn clear(c: Clash) bool {
        return c.system == null and c.launchers.len == 0;
    }
};

fn systemName(id: u32) []const u8 {
    return switch (id) {
        64 => "Spotlight",
        65 => "Finder's search window",
        60, 61 => "the input source switcher",
        else => "a macOS shortcut",
    };
}

/// The clash for `c`, from the system's shortcuts and the running launchers.
pub fn clash(c: Choice, system: []const SystemKey, others: *const Others) Clash {
    var out: Clash = .{};
    for (system) |k| if (k.enabled and k.key == hotkey.space and k.mods & ns_mods == c.appkit()) {
        out.system = systemName(k.id);
        out.system_id = k.id;
        break;
    };
    // Launchers live on ⌘Space and ⌥Space; ⌃Space and ⌥⌘Space are quiet.
    if (c == .cmd_space or c == .opt_space) out.launchers = others.slice();
    return out;
}

/// The system's shortcuts on Space (macOS keeps them in its defaults).
pub fn systemKeys(buf: []SystemKey) []SystemKey {
    if (!mac) return buf[0..0];
    const pool = objc.Pool.push();
    defer pool.pop();
    const ud = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    const domain = objc.msg(?objc.Object, ud, "persistentDomainForName:", .{objc.nsString("com.apple.symbolichotkeys")}) orelse return buf[0..0];
    const table = objc.msg(?objc.Object, domain, "objectForKey:", .{objc.nsString("AppleSymbolicHotKeys")}) orelse return buf[0..0];
    const keys = objc.msg(objc.Object, table, "allKeys", .{});
    var n: usize = 0;
    for (0..objc.msg(objc.NSUInteger, keys, "count", .{})) |i| {
        if (n == buf.len) break;
        const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
        const entry = objc.msg(?objc.Object, table, "objectForKey:", .{k}) orelse continue;
        const enabled = objc.msg(?objc.Object, entry, "objectForKey:", .{objc.nsString("enabled")}) orelse continue;
        const value = objc.msg(?objc.Object, entry, "objectForKey:", .{objc.nsString("value")}) orelse continue;
        const params = objc.msg(?objc.Object, value, "objectForKey:", .{objc.nsString("parameters")}) orelse continue;
        if (objc.msg(objc.NSUInteger, params, "count", .{}) < 3) continue;
        const key: objc.NSInteger = objc.msg(objc.NSInteger, objc.msg(objc.Object, params, "objectAtIndex:", .{@as(objc.NSUInteger, 1)}), "integerValue", .{});
        if (key != hotkey.space) continue;
        const flags = objc.msg(objc.NSInteger, objc.msg(objc.Object, params, "objectAtIndex:", .{@as(objc.NSUInteger, 2)}), "integerValue", .{});
        buf[n] = .{
            .id = @intCast(@max(0, objc.msg(objc.NSInteger, k, "integerValue", .{}))),
            .enabled = objc.msg(objc.BOOL, enabled, "boolValue", .{}),
            .key = hotkey.space,
            .mods = @bitCast(@as(i64, flags)),
        };
        n += 1;
    }
    return buf[0..n];
}

const launchers = [_]struct { []const u8, []const u8 }{
    .{ "com.raycast.macos", "Raycast" },
    .{ "com.runningwithcrayons.Alfred", "Alfred" },
    .{ "com.peeklight.peekalight", "Peekalight" },
    .{ "at.obdev.LaunchBar", "LaunchBar" },
};

/// Asks the launcher called `name` to quit, as its Quit menu item would.
pub fn quit(name: []const u8) void {
    if (!mac) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = for (launchers) |l| {
        if (std.mem.eql(u8, l[1], name)) break l[0];
    } else return;
    const apps = objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{objc.nsString(id)});
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i|
        _ = objc.msg(objc.BOOL, objc.msg(objc.Object, apps, "objectAtIndex:", .{i}), "terminate", .{});
}

/// The launchers that are running now.
pub fn runningLaunchers() Others {
    var o: Others = .{};
    if (!mac) return o;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const apps = objc.msg(objc.Object, ws, "runningApplications", .{});
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
        const a = objc.msg(objc.Object, apps, "objectAtIndex:", .{i});
        const id = objc.fromNSString(objc.msg(?objc.Object, a, "bundleIdentifier", .{}));
        for (launchers) |l| {
            if (!std.mem.eql(u8, id, l[0]) or o.n == o.names.len) continue;
            const seen = for (o.slice()) |name| {
                if (std.mem.eql(u8, name, l[1])) break true;
            } else false;
            if (!seen) {
                o.names[o.n] = l[1];
                o.n += 1;
            }
        }
    }
    return o;
}

test "a clash is found in the system's shortcuts and among launchers" {
    const t = std.testing;
    const sys = [_]SystemKey{
        .{ .id = 64, .enabled = true, .key = 49, .mods = ns_cmd },
        .{ .id = 60, .enabled = false, .key = 49, .mods = ns_ctrl },
        .{ .id = 65, .enabled = true, .key = 49, .mods = ns_cmd | ns_opt | (1 << 23) },
    };
    var others: Others = .{};
    others.names[0] = "Peekalight";
    others.n = 1;
    const a = clash(.cmd_space, &sys, &others);
    try t.expectEqualStrings("Spotlight", a.system.?);
    try t.expectEqual(@as(usize, 1), a.launchers.len);
    // Turned off in System Settings: free.
    try t.expect(clash(.ctrl_space, &sys, &.{}).clear());
    // Device bits beyond the modifiers don't hide a clash.
    try t.expectEqualStrings("Finder's search window", clash(.opt_cmd_space, &sys, &others).system.?);
    try t.expect(clash(.opt_cmd_space, &sys, &others).launchers.len == 0);
}

test "the choice is kept" {
    var mem: nanoui.kv.Memory = .{ .gpa = std.testing.allocator };
    defer mem.deinit();
    try std.testing.expectEqual(Choice.cmd_space, load(mem.store(), std.testing.allocator));
    save(mem.store(), .ctrl_space);
    try std.testing.expectEqual(Choice.ctrl_space, load(mem.store(), std.testing.allocator));
    try std.testing.expect(!onboarded(mem.store()));
    setOnboarded(mem.store());
    try std.testing.expect(onboarded(mem.store()));
}
