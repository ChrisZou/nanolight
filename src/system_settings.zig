//! Read-only navigation to macOS System Settings. Each pane owns its aliases
//! and a fixed URL; user input is never used as a command or URL parameter.
const std = @import("std");

pub const Pane = struct {
    title: []const u8,
    url: []const u8,
    aliases: []const []const u8,

    pub fn matches(p: Pane, input: []const u8) bool {
        const q = std.mem.trim(u8, input, " \t\r\n");
        // No fuzzy/subsequence matching: short words otherwise flood the list.
        if (q.len < 2) return false;
        for (p.aliases) |alias| {
            if (q.len <= alias.len and std.ascii.eqlIgnoreCase(q, alias[0..q.len])) return true;
        }
        return false;
    }
};

pub const panes = [_]Pane{
    .{ .title = "Keyboard", .url = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension", .aliases = &.{ "keyboard", "键盘" } },
    .{ .title = "Mouse", .url = "x-apple.systempreferences:com.apple.Mouse-Settings.extension", .aliases = &.{ "mouse", "鼠标" } },
    .{ .title = "Trackpad", .url = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension", .aliases = &.{ "trackpad", "touchpad", "触控板", "触摸板" } },
    .{ .title = "Displays", .url = "x-apple.systempreferences:com.apple.Displays-Settings.extension", .aliases = &.{ "displays", "display", "monitor", "显示器", "显示屏" } },
    .{ .title = "Sound", .url = "x-apple.systempreferences:com.apple.Sound-Settings.extension", .aliases = &.{ "sound", "audio", "声音", "音频" } },
    .{ .title = "Network", .url = "x-apple.systempreferences:com.apple.Network-Settings.extension", .aliases = &.{ "network", "网络" } },
    .{ .title = "Wi-Fi", .url = "x-apple.systempreferences:com.apple.wifi-settings-extension", .aliases = &.{ "wi-fi", "wifi", "wi fi", "无线网络", "无线局域网" } },
    .{ .title = "Bluetooth", .url = "x-apple.systempreferences:com.apple.BluetoothSettings", .aliases = &.{ "bluetooth", "蓝牙" } },
    .{ .title = "Privacy & Security", .url = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension", .aliases = &.{ "privacy", "security", "privacy & security", "privacy and security", "隐私", "安全", "隐私与安全性", "隐私与安全", "安全性与隐私" } },
    .{ .title = "Accessibility", .url = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension", .aliases = &.{ "accessibility", "辅助功能", "无障碍" } },
};

/// Dispatch only catalog URLs to the OS URL opener. No shell, preferences
/// store, scripts, or settings-writing API is involved. Shared by Live and tests.
pub fn openIfPane(target: []const u8, opener: *const fn ([]const u8) bool) bool {
    for (panes) |pane| {
        if (std.mem.eql(u8, target, pane.url)) {
            _ = opener(pane.url);
            return true;
        }
    }
    return false;
}

test "every bilingual alias maps to exactly one pane with a unique URL" {
    for (panes, 0..) |pane, i| {
        for (panes[0..i]) |other| try std.testing.expect(!std.mem.eql(u8, pane.url, other.url));
        for (pane.aliases) |alias| {
            var count: usize = 0;
            for (panes) |candidate| if (candidate.matches(alias)) {
                count += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), count);
            try std.testing.expect(pane.matches(alias));
        }
    }
}

test "prefixes and case work without unrelated fuzzy or sentence matches" {
    for ([_][]const u8{ "KEYBOARD", "  keyboard  ", "keyb", "键" }) |q| try std.testing.expect(panes[0].matches(q));
    for ([_][]const u8{ "", " ", "s", "ss", "safari", "keynote", "monkey", "keyboard shortcuts in vim", "how to fix sound", "网络小说" }) |q| {
        for (panes) |pane| try std.testing.expect(!pane.matches(q));
    }
}

test "pane dispatch invokes only URL opener with fixed allowlisted routes" {
    const Spy = struct {
        var calls: usize = 0;
        var url: []const u8 = "";
        fn open(target: []const u8) bool {
            calls += 1;
            url = target;
            return true;
        }
    };
    Spy.calls = 0;
    for (panes, 0..) |pane, i| {
        try std.testing.expect(openIfPane(pane.url, Spy.open));
        try std.testing.expectEqualStrings(pane.url, Spy.url);
        try std.testing.expectEqual(i + 1, Spy.calls);
    }
    for ([_][]const u8{ "defaults write com.apple.test value 1", "file:///tmp/test", "https://example.com", "x-apple.systempreferences:unknown", "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?value=1" }) |target| {
        try std.testing.expect(!openIfPane(target, Spy.open));
    }
    try std.testing.expectEqual(panes.len, Spy.calls);
}
