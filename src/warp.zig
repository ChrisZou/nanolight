//! Open a native Warp Agent tab with a unique title for the UI handoff.
//! The task stays out of the saved configuration; the main thread pastes it
//! after confirming that the newly opened Agent tab is active.
const std = @import("std");

pub const max_body = 2000;
pub const Edition = struct {
    app: []const u8,
    executable: []const u8,
    bundle_id: []const u8,
    config_dir: []const u8,
    url: []const u8,
};

const scripting: Edition = .{
    .app = "/Applications/Warp Scripting.app",
    .executable = "/Applications/Warp Scripting.app/Contents/MacOS/warp-oss",
    .bundle_id = "dev.warp.WarpOss",
    .config_dir = ".warp-oss/tab_configs",
    .url = "warposs://tab_config/" ++ config_name,
};
const stable: Edition = .{
    .app = "/Applications/Warp.app",
    .executable = "/Applications/Warp.app/Contents/MacOS/stable",
    .bundle_id = "dev.warp.Warp-Stable",
    .config_dir = ".warp/tab_configs",
    .url = "warp://tab_config/" ++ config_name,
};

fn installedEdition(io: std.Io) Error!Edition {
    for ([_]Edition{ scripting, stable }) |edition| {
        std.Io.Dir.accessAbsolute(io, edition.executable, .{}) catch continue;
        return edition;
    }
    return error.WarpNotFound;
}
const config_name = "nanolight_wp";
const workdir = "/code/ai/warp";
pub fn matchesPrompt(value: []const u8, task: []const u8) bool {
    const prefix = "~" ++ workdir ++ " ";
    return task.len > 0 and std.mem.startsWith(u8, value, prefix) and
        std.mem.eql(u8, value[prefix.len..], task);
}

test "only submit the exact prompt in the expected Warp input" {
    try std.testing.expect(matchesPrompt("~/code/ai/warp 只回复 OK", "只回复 OK"));
    try std.testing.expect(!matchesPrompt("~/code/ai/warp earlier OK", "OK"));
    try std.testing.expect(!matchesPrompt("~/code/ai/warp OK?", "OK"));
    try std.testing.expect(!matchesPrompt("~/other OK", "OK"));
    try std.testing.expect(!matchesPrompt("~/code/ai/warp ", ""));
}

var busy: std.atomic.Value(bool) = .init(false);

pub const Error = error{
    BadTask,
    Busy,
    WarpNotFound,
    ConfigurationFailed,
    OpenFailed,
    TimedOut,
    InputRejected,
    OutOfMemory,
};

/// When `query` is `wp …`, the task (may be empty); else null. `wp`
/// needs its space, so typing "wp" still finds apps.
pub fn take(query_in: []const u8) ?[]const u8 {
    const q = std.mem.trimStart(u8, query_in, " \t");
    if (q.len > 2 and std.ascii.eqlIgnoreCase(q[0..2], "wp") and (q[2] == ' ' or q[2] == '\t'))
        return std.mem.trim(u8, q[2..], " \t");
    return null;
}

/// The returned task is owned by the caller. Preserve it as text; line breaks
/// and tabs become spaces, while other control characters are rejected.
pub fn normalizeTask(allocator: std.mem.Allocator, task_in: []const u8) Error![]u8 {
    const task = std.mem.trim(u8, task_in, " \t\r\n");
    if (task.len == 0 or task.len > max_body) return error.BadTask;
    const view = std.unicode.Utf8View.init(task) catch return error.BadTask;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if ((cp < 0x20 and cp != '\n' and cp != '\r' and cp != '\t') or (cp >= 0x7f and cp <= 0x9f))
            return error.InputRejected;
    }
    const out = try allocator.dupe(u8, task);
    for (out) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    return out;
}

/// Called on a worker thread. This only prepares and opens the native agent
/// tab; the main thread verifies `title` before touching the input.
pub fn run(gpa: std.mem.Allocator, io: std.Io, home: []const u8, title: []const u8) Error!Edition {
    if (busy.swap(true, .acq_rel)) return error.Busy;
    defer busy.store(false, .release);
    if (home.len == 0 or !std.fs.path.isAbsolute(home) or title.len == 0 or !std.unicode.utf8ValidateSlice(title))
        return error.ConfigurationFailed;
    const edition = try installedEdition(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try std.fmt.allocPrint(arena, "{s}" ++ workdir, .{home});
    const config_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, edition.config_dir });
    const path = try std.fmt.allocPrint(arena, "{s}/" ++ config_name ++ ".toml", .{config_dir});
    const text = config(arena, dir, title) catch return error.ConfigurationFailed;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch return error.ConfigurationFailed;
    cwd.createDirPath(io, config_dir) catch return error.ConfigurationFailed;
    cwd.writeFile(io, .{ .sub_path = path, .data = text }) catch return error.ConfigurationFailed;
    try openTab(arena, io, edition.app, edition.url);
    return edition;
}

fn openTab(arena: std.mem.Allocator, io: std.Io, app: []const u8, url: []const u8) Error!void {
    const result = std.process.run(arena, io, .{
        .argv = &.{ "/usr/bin/open", "-a", app, url },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(5000), .clock = .awake }) },
    }) catch |err| return if (err == error.Timeout) error.TimedOut else error.OpenFailed;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.OpenFailed,
        else => return error.OpenFailed,
    }
}

/// Run the interactive CLI in a real terminal. Warp sees only the generated
/// script name in its command template; the prompt is a single literal argv.
pub fn openCodex(gpa: std.mem.Allocator, io: std.Io, home: []const u8, question: []const u8) !void {
    if (question.len == 0 or std.mem.indexOfScalar(u8, question, 0) != null) return error.BadTask;
    std.Io.Dir.accessAbsolute(io, scripting.executable, .{}) catch return error.WarpNotFound;
    var codex_buf: [512]u8 = undefined;
    const codex = @import("ai.zig").findCodex(io, &codex_buf, home);
    if (codex.len == 0) return error.CodexNotFound;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const name = try std.fmt.allocPrint(arena, "nanolight_codex_{x}", .{&nonce});
    const script_path = try std.fmt.allocPrint(arena, "/tmp/{s}.sh", .{name});
    const config_dir = try std.fs.path.join(arena, &.{ home, scripting.config_dir });
    const filename = try std.fmt.allocPrint(arena, "{s}.toml", .{name});
    const config_path = try std.fs.path.join(arena, &.{ config_dir, filename });
    const dir = try std.fmt.allocPrint(arena, "{s}" ++ workdir, .{home});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    try cwd.createDirPath(io, config_dir);

    var script: std.Io.Writer.Allocating = .init(arena);
    try script.writer.writeAll("/bin/rm -f -- \"$0\" ");
    try shellArg(&script.writer, config_path);
    try script.writer.writeAll("\nexec ");
    try shellArg(&script.writer, codex);
    try script.writer.writeAll(" -- ");
    try shellArg(&script.writer, question);
    try script.writer.writeByte('\n');

    var config_text: std.Io.Writer.Allocating = .init(arena);
    try config_text.writer.writeAll("name = \"Codex\"\n[[panes]]\nid = \"main\"\ntype = \"terminal\"\ndirectory = ");
    try tomlString(&config_text.writer, dir);
    try config_text.writer.print("\ncommands = [\"/bin/sh {s}\"]\nis_focused = true\n", .{script_path});

    try writePrivate(io, script_path, script.written());
    errdefer cwd.deleteFile(io, script_path) catch {};
    try writePrivate(io, config_path, config_text.written());
    errdefer cwd.deleteFile(io, config_path) catch {};
    const url = try std.fmt.allocPrint(arena, "warposs://tab_config/{s}", .{name});
    try openTab(arena, io, scripting.app, url);
}

fn shellArg(w: *std.Io.Writer, arg: []const u8) !void {
    try w.writeByte('\'');
    for (arg) |byte| {
        if (byte == '\'') try w.writeAll("'\\''") else try w.writeByte(byte);
    }
    try w.writeByte('\'');
}

fn writePrivate(io: std.Io, path: []const u8, text: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    try file.writeStreamingAll(io, text);
}

test "Codex prompt remains a literal shell argument" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try shellArg(&out.writer, "what's \"$HOME\"?\n{{example}}");
    try std.testing.expectEqualStrings("'what'\\''s \"$HOME\"?\n{{example}}'", out.written());
}

/// Only layout metadata goes in the config. All caller-provided strings are
/// TOML strings, never startup commands or executable shell content.
fn config(allocator: std.mem.Allocator, dir: []const u8, title: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    try w.writeAll("# Written by Nanolight for `wp `; replaced on each use.\nname = \"Nanolight\"\ntitle = ");
    try tomlString(w, title);
    try w.writeAll("\n\n[[panes]]\nid = \"main\"\ntype = \"agent\"\ndirectory = ");
    try tomlString(w, dir);
    try w.writeAll("\nis_focused = true\n");
    return out.written();
}

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

test "prompt stays text and control characters cannot submit input" {
    const a = std.testing.allocator;
    const task = try normalizeTask(a, " --help 'test' $(touch /tmp/no)\n下一行\r\t结束 ");
    defer a.free(task);
    try std.testing.expectEqualStrings("--help 'test' $(touch /tmp/no) 下一行  结束", task);
    try std.testing.expectError(error.InputRejected, normalizeTask(a, "bad\x1binput"));
    try std.testing.expectError(error.InputRejected, normalizeTask(a, "bad\xc2\x85input"));
    try std.testing.expectError(error.BadTask, normalizeTask(a, " \n "));
    try std.testing.expectError(error.BadTask, normalizeTask(a, "\xff"));
    const long: [max_body + 1]u8 = @splat('a');
    try std.testing.expectError(error.BadTask, normalizeTask(a, &long));
}

test "native agent config contains the unique title and directory but no commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try config(arena.allocator(), "/Users/chris/code/ai/warp", "Nanolight · 123456abcdef");
    try std.testing.expectEqualStrings(
        "# Written by Nanolight for `wp `; replaced on each use.\nname = \"Nanolight\"\ntitle = \"Nanolight · 123456abcdef\"\n\n[[panes]]\nid = \"main\"\ntype = \"agent\"\ndirectory = \"/Users/chris/code/ai/warp\"\nis_focused = true\n",
        text,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "commands") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "oz agent") == null);
}

test "TOML escaping keeps a title from adding configuration fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try config(arena.allocator(), "/Users/quote\"and\\slash/warp", "Nanolight\"\ncommands = [\"bad\"]\\\t\r\x01");
    try std.testing.expect(std.mem.indexOf(u8, text, "title = \"Nanolight\\\"\\u000acommands = [\\\"bad\\\"]\\\\\\t\\u000d\\u0001\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "directory = \"/Users/quote\\\"and\\\\slash/warp\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\ncommands") == null);
}
