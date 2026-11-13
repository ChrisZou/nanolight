//! Connect to the managed Codex daemon while the launcher is in use.
//! Each submitted question gets its own ephemeral thread.
const std = @import("std");
const nanoui = @import("nanoui");
const Live = @import("main.zig").Live;
const ai = @import("ai.zig");
const idle_seconds = 60;
const setup_seconds = 12;

pub const Session = struct {
    socket: ?@import("codex_socket.zig").Client = null,
    retry_after: i64 = 0,
    watch: ?nanoui.fdwatch.Watch = null,
    turn: [128]u8 = undefined,
    turn_len: usize = 0,
    thread: [128]u8 = undefined,
    thread_len: usize = 0,
    between_questions: bool = false,
    question: [ai.max_question]u8 = undefined,
    question_len: usize = 0,
    gen: u32 = 0,
    submitted: bool = false,
    answer: [ai.max_answer]u8 = undefined,
    answer_len: usize = 0,
    deadline: i64 = 0,
    timer: bool = false,

    fn live(s: *Session) *Live {
        return @fieldParentPtr("inline_codex", s);
    }

    fn now(s: *Session) i64 {
        return std.Io.Clock.awake.now(s.live().app.io).toSeconds();
    }

    pub fn warm(s: *Session) void {
        if (s.socket != null) {
            if (s.between_questions) s.prepare() catch return s.stop();
            if (s.thread_len > 0 and !s.submitted) s.deadline = s.now() + idle_seconds;
            return;
        }
        const l = s.live();
        if (s.now() < s.retry_after) return;
        var buf: [1024]u8 = undefined;
        const suffix = "/app-server-control/app-server-control.sock";
        const home = if (l.env) |env| env.get("CODEX_HOME") else null;
        const path = if (home) |dir|
            std.fmt.bufPrint(&buf, "{s}" ++ suffix, .{dir}) catch return
        else
            std.fmt.bufPrint(&buf, "{s}/.codex" ++ suffix, .{l.home}) catch return;
        s.socket = @import("codex_socket.zig").Client.connect(l.app.io, path) catch {
            s.retry_after = s.now() + 2;
            return;
        };
        s.watch = nanoui.fdwatch.readable(s.socket.?.stream.socket.handle, s, readable) catch return s.stop();
        s.deadline = s.now() + setup_seconds;
        if (!s.timer) {
            s.timer = true;
            nanoui.App.after(1000, s, tick);
        }
    }

    pub fn initialize(s: *Session) !void {
        try s.send(.{ .id = 1, .method = "initialize", .params = .{ .clientInfo = .{ .name = "nanolight", .version = @import("build_options").version } } });
    }

    pub fn ask(s: *Session, question: []const u8, gen: u32) bool {
        s.warm();
        if (s.socket == null or question.len == 0 or question.len > s.question.len) return false;
        @memcpy(s.question[0..question.len], question);
        s.question_len = question.len;
        s.gen = gen;
        if (s.thread_len > 0) s.submit() catch s.failed("Couldn't start Codex");
        return true;
    }

    fn prepare(s: *Session) !void {
        s.between_questions = false;
        s.thread_len = 0;
        s.deadline = s.now() + setup_seconds;
        try s.send(.{ .id = 2, .method = "thread/start", .params = .{ .cwd = "/", .ephemeral = true, .approvalPolicy = "never", .sandbox = "read-only" } });
    }

    fn submit(s: *Session) !void {
        s.answer_len = 0;
        s.submitted = true;
        s.deadline = s.now() + ai.timeout_s;
        try s.send(.{ .id = 3, .method = "turn/start", .params = .{ .threadId = s.thread[0..s.thread_len], .input = .{.{ .type = "text", .text = s.question[0..s.question_len] }} } });
    }

    fn send(s: *Session, msg: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(s.live().app.gpa);
        defer out.deinit();
        try std.json.Stringify.value(msg, .{}, &out.writer);
        try s.socket.?.send(s.live().app.io, s.live().app.gpa, .text, out.written());
    }

    pub fn stop(s: *Session) void {
        if (s.watch) |w| w.cancel();
        s.watch = null;
        if (s.socket) |*socket| {
            if (s.submitted and s.turn_len > 0) {
                s.send(.{ .id = 5, .method = "turn/interrupt", .params = .{ .threadId = s.thread[0..s.thread_len], .turnId = s.turn[0..s.turn_len] } }) catch {};
            }
            socket.close(s.live().app.io, s.live().app.gpa);
        }
        s.socket = null;
        s.turn_len = 0;
        s.between_questions = false;
        s.thread_len = 0;
    }

    fn failed(s: *Session, message: []const u8) void {
        s.stop();
        const n = s.question_len;
        s.question_len = 0;
        const submitted = s.submitted;
        s.submitted = false;
        if (n == 0) return;
        // Only fall back before submitting a prompt. Never replay a turn.
        if (!submitted) return s.live().aiAskExec(s.question[0..n]);
        s.finish(false, message);
    }

    fn finish(s: *Session, ok: bool, text: []const u8) void {
        s.live().s.aiDone(s.gen, ok, text);
        if (s.live().window) |w| w.redraw();
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        if (s.socket != null and s.now() >= s.deadline) s.failed("Codex took too long");
        s.timer = s.socket != null;
        if (s.timer) nanoui.App.after(1000, s, tick);
    }

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        const socket = if (s.socket) |*socket| socket else return;
        var buf: [32 * 1024]u8 = undefined;
        const n = std.c.read(socket.stream.socket.handle, &buf, buf.len);
        if (n <= 0) return s.failed("Codex disconnected");
        socket.feed(s.live().app.io, s.live().app.gpa, buf[0..@intCast(n)], s) catch s.failed("Codex disconnected");
    }

    pub fn handle(s: *Session, line: []const u8) !void {
        const json = try std.json.parseFromSlice(std.json.Value, s.live().app.gpa, line, .{});
        defer json.deinit();
        const msg = json.value;
        const method = string(msg, "method");
        const id = field(msg, "id");
        if (method.len > 0 and id != .null) {
            return s.send(.{ .id = id, .@"error" = .{ .code = -32601, .message = "Unsupported request" } });
        }
        if (id == .integer) {
            if (id.integer == 4) return; // Unsubscribing the preceding thread.
            if (field(msg, "error") != .null) return error.CodexFailed;
            switch (id.integer) {
                1 => {
                    try s.send(.{ .method = "initialized", .params = .{} });
                    try s.prepare();
                },
                2 => {
                    const thread = string(field(field(msg, "result"), "thread"), "id");
                    if (thread.len == 0 or thread.len > s.thread.len) return error.BadThread;
                    @memcpy(s.thread[0..thread.len], thread);
                    s.thread_len = thread.len;
                    s.deadline = s.now() + idle_seconds;
                    if (s.question_len > 0) try s.submit();
                },
                3 => {
                    const turn = string(field(field(msg, "result"), "turn"), "id");
                    if (turn.len > s.turn.len) return error.BadTurn;
                    @memcpy(s.turn[0..turn.len], turn);
                    s.turn_len = turn.len;
                },
                else => {},
            }
            return;
        }
        const params = field(msg, "params");
        if (!s.submitted or !std.mem.eql(u8, s.thread[0..s.thread_len], string(params, "threadId"))) return;
        if (std.mem.eql(u8, method, "item/completed")) {
            const item = field(params, "item");
            if (!std.mem.eql(u8, string(item, "type"), "agentMessage")) return;
            const phase = string(item, "phase");
            if (phase.len != 0 and !std.mem.eql(u8, phase, "final_answer")) return;
            const text = std.mem.trim(u8, string(item, "text"), " \t\n\r");
            var n = @min(text.len, s.answer.len);
            while (n < text.len and n > 0 and (text[n] & 0xc0) == 0x80) n -= 1;
            @memcpy(s.answer[0..n], text[0..n]);
            s.answer_len = n;
        } else if (std.mem.eql(u8, method, "turn/completed")) {
            s.submitted = false;
            s.turn_len = 0;
            s.question_len = 0;
            const turn = field(params, "turn");
            if (!std.mem.eql(u8, string(turn, "status"), "completed")) {
                const reason = string(field(turn, "error"), "message");
                s.finish(false, if (reason.len > 0) reason else "Codex failed");
            } else if (s.answer_len == 0) {
                s.finish(false, "No answer");
            } else s.finish(true, s.answer[0..s.answer_len]);
            try s.send(.{ .id = 4, .method = "thread/unsubscribe", .params = .{ .threadId = s.thread[0..s.thread_len] } });
            s.thread_len = 0;
            s.between_questions = true;
            s.deadline = s.now() + idle_seconds;
        }
    }
};

fn field(v: std.json.Value, name: []const u8) std.json.Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}

fn string(v: std.json.Value, name: []const u8) []const u8 {
    const f = field(v, name);
    return if (f == .string) f.string else "";
}
