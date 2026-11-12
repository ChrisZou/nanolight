//! Hand a task to Warp's agent (`wp `): Return writes a Warp tab config
//! whose pane runs `oz agent run -p '<task>'`, then opens it with
//! `warp://tab_config/nanolight_wp`, so the agent works in a Warp tab
//! you can watch. (Warp's URIs can't run a command themselves.)
const std = @import("std");

pub const max_body = 2000;
pub const config_name = "nanolight_wp";
pub const url = "warp://tab_config/" ++ config_name;
const oz = "/Applications/Warp.app/Contents/Resources/bin/oz";

/// When `query` is `wp …`, the task (may be empty); else null. `wp`
/// needs its space, so typing "wp" still finds apps.
pub fn take(query_in: []const u8) ?[]const u8 {
    const q = std.mem.trimStart(u8, query_in, " \t");
    if (q.len > 2 and std.ascii.eqlIgnoreCase(q[0..2], "wp") and (q[2] == ' ' or q[2] == '\t'))
        return std.mem.trim(u8, q[2..], " \t");
    return null;
}

/// The tab config's path under `home` into `buf`.
pub fn configPath(buf: []u8, home: []const u8) []const u8 {
    if (home.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.warp/tab_configs/" ++ config_name ++ ".toml", .{home}) catch "";
}

/// The tab config (TOML) that runs the agent on `task` in `home`.
pub fn config(arena: std.mem.Allocator, home: []const u8, task: []const u8) ![]const u8 {
    // The shell command: the task single-quoted, ' as '\''.
    var cmd: std.Io.Writer.Allocating = .init(arena);
    try cmd.writer.writeAll(oz ++ " agent run -p '");
    for (task) |ch| {
        if (ch == '\'') try cmd.writer.writeAll("'\\''") else try cmd.writer.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
    }
    try cmd.writer.writeByte('\'');

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("# Written by Nanolight for `wp `; replaced on each use.\nname = \"Nanolight\"\n\n[[panes]]\nid = \"main\"\ntype = \"terminal\"\ndirectory = ");
    try tomlString(w, home);
    try w.writeAll("\ncommands = [");
    try tomlString(w, cmd.written());
    try w.writeAll("]\n");
    return out.written();
}

/// Writes the tab config for `task`; false if it couldn't.
pub fn prepare(arena: std.mem.Allocator, io: std.Io, home: []const u8, task_in: []const u8) bool {
    const task = std.mem.trim(u8, task_in, " \t\r\n");
    if (home.len == 0 or task.len == 0 or task.len > max_body) return false;
    var buf: [512]u8 = undefined;
    const path = configPath(&buf, home);
    if (path.len == 0) return false;
    const text = config(arena, home, task) catch return false;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
    cwd.writeFile(io, .{ .sub_path = path, .data = text }) catch return false;
    return true;
}

/// A TOML basic string.
fn tomlString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        0...8, 10...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

test "wp prefixes; wp alone still finds apps" {
    const t = std.testing;
    try t.expectEqualStrings("整理 Downloads", take("wp 整理 Downloads").?);
    try t.expectEqualStrings("hi", take("WP hi").?);
    try t.expectEqualStrings("", take("wp ").?);
    try t.expect(take("wp") == null);
    try t.expect(take("wps") == null);
}

test "the tab config runs oz on the task, quoted for the shell and for TOML" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try config(arena.allocator(), "/Users/chris", "say \"it's\" a\\b");
    try std.testing.expectEqualStrings(
        "# Written by Nanolight for `wp `; replaced on each use.\nname = \"Nanolight\"\n\n[[panes]]\nid = \"main\"\ntype = \"terminal\"\ndirectory = \"/Users/chris\"\n" ++
            "commands = [\"/Applications/Warp.app/Contents/Resources/bin/oz agent run -p 'say \\\"it'\\\\''s\\\" a\\\\b'\"]\n",
        text,
    );
}
