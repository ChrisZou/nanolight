//! Temporary AI Q&A through the Mac's installed Codex CLI (`codex exec`).
//! Keyword: `ai ` / `ask `. Spawns a non-interactive one-shot; the launcher
//! never uses Codex to edit Nanolight itself.
const std = @import("std");

pub const max_question = 500;
pub const max_answer = 8 * 1024;

pub const prefixes = [_][]const u8{ "ai ", "ask " };

/// When `query` is an AI command, the question (may be empty); else null.
pub fn take(query_in: []const u8) ?[]const u8 {
    const q = std.mem.trim(u8, query_in, " \t");
    for (prefixes) |p| {
        if (startsIgnoreCase(q, p)) return std.mem.trim(u8, q[p.len..], " \t");
    }
    if (eqlIgnoreCase(q, "ai") or eqlIgnoreCase(q, "ask")) return "";
    return null;
}

pub const Status = enum {
    ready,
    waiting,
    done,
    failed,
};

pub const Temp = struct {
    out: [128]u8 = undefined,
    out_len: usize = 0,

    pub fn outPath(t: *const Temp) []const u8 {
        return t.out[0..t.out_len];
    }
};

var temp_seq: std.atomic.Value(u64) = .init(1);

/// Unique paths under /tmp for this ask.
pub fn tempPaths(t: *Temp, seq: u64, pid: u32) void {
    const o = std.fmt.bufPrint(&t.out, "/tmp/nanolight-ai-{d}-{d}.txt", .{ pid, seq }) catch {
        t.out_len = 0;
        return;
    };
    t.out_len = o.len;
}

pub fn nextTemp(t: *Temp) void {
    const seq = temp_seq.fetchAdd(1, .monotonic);
    tempPaths(t, seq, @intCast(std.c.getpid()));
}

pub const codex_candidates = [_][]const u8{
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
};
/// Under $HOME: where npm, bun and pipx-style installs put it.
pub const codex_home_candidates = [_][]const u8{
    "/.local/bin/codex",
    "/.npm-global/bin/codex",
    "/.bun/bin/codex",
    "/.volta/bin/codex",
};

/// The first Codex CLI found, into `buf` ("" when none).
pub fn findCodex(io: std.Io, buf: []u8, home: []const u8) []const u8 {
    for (codex_candidates) |c| {
        std.Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        if (c.len <= buf.len) {
            @memcpy(buf[0..c.len], c);
            return buf[0..c.len];
        }
    }
    if (home.len > 0) for (codex_home_candidates) |suffix| {
        const p = std.fmt.bufPrint(buf, "{s}{s}", .{ home, suffix }) catch continue;
        std.Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return p;
    };
    return "";
}

pub fn buildArgv(
    argv: *[12][]const u8,
    codex: []const u8,
    out_path: []const u8,
    question: []const u8,
) []const []const u8 {
    argv.* = .{
        codex,
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "-s",
        "read-only",
        "--color",
        "never",
        "-o",
        out_path,
        question,
        "",
    };
    return argv.*[0..11];
}

/// Seconds Codex gets before its whole process group is killed.
pub const timeout_s = 120;

/// Runs Codex and returns its last message, in `answer_buf`. Killed
/// (with anything it started) after `timeout_s`, so one hung ask never
/// blocks the next.
pub fn run(
    io: std.Io,
    codex: []const u8,
    question: []const u8,
    out_path: []const u8,
    answer_buf: []u8,
) ![]const u8 {
    if (codex.len == 0 or question.len == 0 or question.len > max_question) return error.BadQuestion;
    var argv_store: [12][]const u8 = undefined;
    const argv = buildArgv(&argv_store, codex, out_path, question);

    {
        var f = std.Io.Dir.createFileAbsolute(io, out_path, .{}) catch return error.TempFile;
        f.close(io);
    }

    // Its own process group, so the watchdog can take its children too.
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return error.SpawnFailed;
    var watch: Watchdog = .{ .pid = child.id.?, .io = io };
    const dog = std.Thread.spawn(.{}, Watchdog.run, .{&watch}) catch null;
    const term = child.wait(io) catch null;
    watch.done.store(true, .release);
    if (dog) |t| t.join();
    if (watch.fired.load(.acquire)) return error.TimedOut;

    const raw = std.Io.Dir.cwd().readFile(io, out_path, answer_buf) catch return error.NoAnswer;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        const ok = if (term) |t| t.success() else false;
        return if (ok) error.NoAnswer else error.CodexFailed;
    }
    if (trimmed.ptr != answer_buf.ptr) std.mem.copyForwards(u8, answer_buf, trimmed);
    return answer_buf[0..trimmed.len];
}

/// Kills Codex's process group once `timeout_s` pass without it exiting.
const Watchdog = struct {
    pid: std.posix.pid_t,
    io: std.Io,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    fn run(w: *Watchdog) void {
        // Wakes every 250 ms, so a finished ask isn't held up joining it.
        var waited_ms: i64 = 0;
        while (waited_ms < timeout_s * 1000) : (waited_ms += 250) {
            if (w.done.load(.acquire)) return;
            w.io.sleep(.fromMilliseconds(250), .awake) catch return;
        }
        if (w.done.load(.acquire)) return;
        w.fired.store(true, .release);
        _ = std.c.kill(-w.pid, std.posix.SIG.KILL);
    }
};

fn startsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "ai/ask prefixes" {
    const t = std.testing;
    try t.expectEqualStrings("what is zig", take("ai what is zig").?);
    try t.expectEqualStrings("hello", take("ASK hello").?);
    try t.expectEqualStrings("", take("ai").?);
    try t.expect(take("aide") == null);
}

test "temp paths are unique-shaped" {
    var tmp: Temp = .{};
    tempPaths(&tmp, 99, 123);
    try std.testing.expectEqualStrings("/tmp/nanolight-ai-123-99.txt", tmp.outPath());
}

test "argv is a non-interactive exec" {
    var store: [12][]const u8 = undefined;
    const argv = buildArgv(&store, "/opt/homebrew/bin/codex", "/tmp/out.txt", "ping");
    try std.testing.expectEqualStrings("exec", argv[1]);
    try std.testing.expectEqualStrings("--ephemeral", argv[2]);
    try std.testing.expectEqualStrings("-o", argv[8]);
    try std.testing.expectEqualStrings("/tmp/out.txt", argv[9]);
    try std.testing.expectEqualStrings("ping", argv[10]);
}
