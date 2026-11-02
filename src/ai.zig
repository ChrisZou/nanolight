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
    log: [128]u8 = undefined,
    log_len: usize = 0,

    pub fn outPath(t: *const Temp) []const u8 {
        return t.out[0..t.out_len];
    }
    pub fn logPath(t: *const Temp) []const u8 {
        return t.log[0..t.log_len];
    }
};

var temp_seq: std.atomic.Value(u64) = .init(1);

/// Unique paths under /tmp for this ask.
pub fn tempPaths(t: *Temp, seq: u64, pid: u32) void {
    const o = std.fmt.bufPrint(&t.out, "/tmp/nanolight-ai-{d}-{d}.txt", .{ pid, seq }) catch {
        t.out_len = 0;
        t.log_len = 0;
        return;
    };
    t.out_len = o.len;
    const l = std.fmt.bufPrint(&t.log, "/tmp/nanolight-ai-{d}-{d}.log", .{ pid, seq }) catch {
        t.log_len = 0;
        return;
    };
    t.log_len = l.len;
}

pub fn nextTemp(t: *Temp) void {
    const seq = temp_seq.fetchAdd(1, .monotonic);
    tempPaths(t, seq, @intCast(std.c.getpid()));
}

pub const codex_candidates = [_][]const u8{
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
};

pub fn findCodex(io: std.Io, buf: []u8) []const u8 {
    for (codex_candidates) |c| {
        std.Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        if (c.len <= buf.len) {
            @memcpy(buf[0..c.len], c);
            return buf[0..c.len];
        }
    }
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

/// Runs Codex; writes stderr to `log_path`; returns the last message into
/// `answer_buf` (slice into that buffer). stdin is ignored by `process.run`.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    codex: []const u8,
    question: []const u8,
    out_path: []const u8,
    log_path: []const u8,
    answer_buf: []u8,
) ![]const u8 {
    if (codex.len == 0 or question.len == 0 or question.len > max_question) return error.BadQuestion;
    var argv_store: [12][]const u8 = undefined;
    const argv = buildArgv(&argv_store, codex, out_path, question);

    {
        var f = std.Io.Dir.createFileAbsolute(io, out_path, .{}) catch return error.TempFile;
        f.close(io);
    }

    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .create_no_window = true,
    }) catch return error.SpawnFailed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (log_path.len > 0) {
        if (std.Io.Dir.createFileAbsolute(io, log_path, .{})) |f_val| {
            var f = f_val;
            defer f.close(io);
            f.writeStreamingAll(io, result.stderr) catch {};
        } else |_| {}
    }

    const raw = std.Io.Dir.cwd().readFile(io, out_path, answer_buf) catch return error.NoAnswer;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        if (!result.term.success()) return error.CodexFailed;
        return error.NoAnswer;
    }
    if (trimmed.ptr != answer_buf.ptr) std.mem.copyForwards(u8, answer_buf, trimmed);
    return answer_buf[0..trimmed.len];
}

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
    try std.testing.expectEqualStrings("/tmp/nanolight-ai-123-99.log", tmp.logPath());
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
