//! Hand `wp ` tasks to Warp's native Agent Mode through Warp Control.
//! The create response supplies the exact new tab ID; only that tab receives
//! the prompt. The user presses Enter in Warp to submit it.
const std = @import("std");

pub const max_body = 2000;
const warp_bin = "/Applications/Warp.app/Contents/MacOS/stable";
var busy: std.atomic.Value(bool) = .init(false);

pub const Error = error{
    BadTask,
    Busy,
    WarpNotFound,
    ScriptingDisabled,
    AmbiguousInstance,
    AmbiguousTarget,
    MissingTarget,
    TargetChanged,
    OpenFailed,
    ControlFailed,
    ProtocolError,
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

/// Runs on a worker thread. A disabled or ambiguous Warp instance is rejected
/// before creating a tab. The returned tab ID remains the target even when
/// the user changes focus or opens another tab during this handoff.
pub fn run(gpa: std.mem.Allocator, io: std.Io, task_in: []const u8) Error!void {
    if (busy.swap(true, .acq_rel)) return error.Busy;
    defer busy.store(false, .release);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const task = try normalizeTask(arena, task_in);
    std.Io.Dir.accessAbsolute(io, warp_bin, .{}) catch return error.WarpNotFound;
    const launch = std.process.run(arena, io, .{
        .argv = &.{ "/usr/bin/open", "-a", "/Applications/Warp.app" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = timeout(io) },
    }) catch return error.OpenFailed;
    if (!succeeded(launch.term)) return error.OpenFailed;
    const launch_deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromMilliseconds(3000), .clock = .awake });
    const instance = instance: while (true) {
        const instances = try control(arena, io, &.{ "instance", "list" }, launch_deadline);
        const id = uniqueInstance(instances) catch |err| {
            if (err != error.ScriptingDisabled) return err;
            if (launch_deadline.durationFromNow(io).raw.toMilliseconds() <= 100) return error.ScriptingDisabled;
            io.sleep(.fromMilliseconds(100), .awake) catch return error.ControlFailed;
            continue;
        };
        break :instance id;
    };
    const active = try control(arena, io, &.{ "app", "active", "--instance", instance }, timeout(io));
    const window = try activeWindow(active, instance);
    const created = try control(arena, io, &.{ "tab", "create", "--type", "agent", "--instance", instance, "--window", window }, timeout(io));
    const target = try createdTab(created, instance, window);
    const input_args = inputArgs(instance, target, task);
    const result = try control(arena, io, &input_args, timeout(io));
    try checkInputAck(result, instance);
    // This Warp version exposes no input.inspect/readback or submit action.
}

fn timeout(io: std.Io) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromMilliseconds(5000), .clock = .awake });
}

fn normalizeTask(arena: std.mem.Allocator, task_in: []const u8) Error![]const u8 {
    const task = std.mem.trim(u8, task_in, " \t\r\n");
    if (task.len == 0 or task.len > max_body) return error.BadTask;
    const view = std.unicode.Utf8View.init(task) catch return error.BadTask;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if ((cp < 0x20 and cp != '\n' and cp != '\r' and cp != '\t') or (cp >= 0x7f and cp <= 0x9f))
            return error.InputRejected;
    }
    const out = try arena.dupe(u8, task);
    for (out) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
        ch.* = ' ';
    };
    return out;
}

fn control(arena: std.mem.Allocator, io: std.Io, args: []const []const u8, deadline: std.Io.Clock.Timestamp) Error!std.json.Value {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ warp_bin, "--warpctrl", "--output-format", "json" });
    try argv.appendSlice(arena, args);
    const result = std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = deadline },
    }) catch |err| return if (err == error.Timeout) error.TimedOut else error.ControlFailed;
    const value = try parse(arena, result.stdout);
    try checkError(value);
    if (!succeeded(result.term)) return error.ControlFailed;
    return value;
}

fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn parse(arena: std.mem.Allocator, text: []const u8) Error!std.json.Value {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always }) catch return error.ProtocolError;
    if (value != .object) return error.ProtocolError;
    return value;
}

fn field(object: std.json.Value, key: []const u8) Error!std.json.Value {
    if (object != .object) return error.ProtocolError;
    return object.object.get(key) orelse error.ProtocolError;
}

fn string(object: std.json.Value, key: []const u8) Error![]const u8 {
    const value = try field(object, key);
    if (value != .string or value.string.len == 0) return error.ProtocolError;
    return value.string;
}

fn checkError(value: std.json.Value) Error!void {
    const ok = value.object.get("ok") orelse return;
    if (ok != .bool) return error.ProtocolError;
    if (ok.bool) return;
    const code = try string(try field(value, "error"), "code");
    if (std.mem.eql(u8, code, "no_instance") or std.mem.eql(u8, code, "local_control_disabled")) return error.ScriptingDisabled;
    if (std.mem.eql(u8, code, "ambiguous_instance")) return error.AmbiguousInstance;
    if (std.mem.eql(u8, code, "ambiguous_target")) return error.AmbiguousTarget;
    if (std.mem.eql(u8, code, "missing_target")) return error.MissingTarget;
    if (std.mem.eql(u8, code, "stale_target") or std.mem.eql(u8, code, "target_state_conflict")) return error.TargetChanged;
    if (std.mem.eql(u8, code, "invalid_params")) return error.InputRejected;
    return error.ControlFailed;
}

fn uniqueInstance(value: std.json.Value) Error![]const u8 {
    const list = try field(value, "instances");
    if (list != .array) return error.ProtocolError;
    if (list.array.items.len == 0) return error.ScriptingDisabled;
    if (list.array.items.len != 1) return error.AmbiguousInstance;
    return string(list.array.items[0], "instance_id");
}

fn checkAction(value: std.json.Value, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, try string(value, "action"), expected)) return error.ProtocolError;
}

fn activeWindow(value: std.json.Value, instance: []const u8) Error![]const u8 {
    try checkAction(value, "app.active");
    const active = try field(value, "active");
    if (!std.mem.eql(u8, try string(active, "instance_id"), instance)) return error.TargetChanged;
    const window = try field(active, "window_id");
    if (window == .null) return error.MissingTarget;
    return string(active, "window_id");
}

const Target = struct { tab: []const u8, window: []const u8 };

fn createdTab(value: std.json.Value, instance: []const u8, window: []const u8) Error!Target {
    try checkAction(value, "tab.create");
    const created = try field(value, "created");
    if (created != .bool or !created.bool) return error.ProtocolError;
    if (!std.mem.eql(u8, try string(value, "instance_id"), instance)) return error.TargetChanged;
    const returned_window = try string(try field(value, "window"), "id");
    if (!std.mem.eql(u8, returned_window, window)) return error.TargetChanged;
    return .{ .tab = try string(try field(value, "tab"), "id"), .window = returned_window };
}

fn inputArgs(instance: []const u8, target: Target, task: []const u8) [10][]const u8 {
    return .{ "input", "replace", "--instance", instance, "--window", target.window, "--tab", target.tab, "--", task };
}

fn checkInputAck(value: std.json.Value, instance: []const u8) Error!void {
    try checkAction(value, "input.replace");
    const ok = try field(value, "ok");
    if (ok != .bool or !ok.bool) return error.ProtocolError;
    if (!std.mem.eql(u8, try string(value, "instance_id"), instance)) return error.TargetChanged;
}

test "wp prefixes; wp alone still finds apps" {
    const t = std.testing;
    try t.expectEqualStrings("整理 Downloads", take("wp 整理 Downloads").?);
    try t.expectEqualStrings("hi", take("WP hi").?);
    try t.expectEqualStrings("", take("wp ").?);
    try t.expect(take("wp") == null);
    try t.expect(take("wps") == null);
}

test "prompt stays data and control characters cannot submit input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("--help 'test' $(touch /tmp/no) 下一行  结束", try normalizeTask(a, " --help 'test' $(touch /tmp/no)\n下一行\r\t结束 "));
    try std.testing.expectError(error.InputRejected, normalizeTask(a, "bad\x1binput"));
    try std.testing.expectError(error.InputRejected, normalizeTask(a, "bad\xc2\x85input"));
    try std.testing.expectError(error.BadTask, normalizeTask(a, " \n "));
}

test "real Warp JSON and errors are decoded without assuming envelope fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("instance-1", try uniqueInstance(try parse(a, "{\"instances\":[{\"instance_id\":\"instance-1\",\"pid\":123}]}")));
    try std.testing.expectError(error.ScriptingDisabled, uniqueInstance(try parse(a, "{\"instances\":[]}")));
    try std.testing.expectError(error.AmbiguousInstance, uniqueInstance(try parse(a, "{\"instances\":[{\"instance_id\":\"one\"},{\"instance_id\":\"two\"}]}")));
    try std.testing.expectError(error.ScriptingDisabled, checkError(try parse(a, "{\"ok\":false,\"error\":{\"code\":\"no_instance\",\"message\":\"disabled\"}}")));
    try checkInputAck(try parse(a, "{\"action\":\"input.replace\",\"ok\":true,\"instance_id\":\"instance-1\"}"), "instance-1");
    try std.testing.expectError(error.TargetChanged, checkInputAck(try parse(a, "{\"action\":\"input.replace\",\"ok\":true,\"instance_id\":\"other\"}"), "instance-1"));
}

test "create response must identify the requested instance and window and a real tab ID" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try parse(a,
        \\{"action":"tab.create","created":true,"instance_id":"i1","window":{"selector":"target","id":"w1"},"tab":{"id":"new-tab","previous_count":2,"count":3,"active_index":2}}
    );
    const target = try createdTab(good, "i1", "w1");
    try std.testing.expectEqualStrings("new-tab", target.tab);
    try std.testing.expectEqualStrings("w1", target.window);
    try std.testing.expectError(error.TargetChanged, createdTab(good, "i2", "w1"));
    try std.testing.expectError(error.TargetChanged, createdTab(good, "i1", "w2"));
    const missing = try parse(a,
        \\{"action":"tab.create","created":true,"instance_id":"i1","window":{"id":"w1"},"tab":{}}
    );
    try std.testing.expectError(error.ProtocolError, createdTab(missing, "i1", "w1"));
    const false_create = try parse(a,
        \\{"action":"tab.create","created":false,"instance_id":"i1","window":{"id":"w1"},"tab":{"id":"old-tab"}}
    );
    try std.testing.expectError(error.ProtocolError, createdTab(false_create, "i1", "w1"));
    const wrong_action = try parse(a,
        \\{"action":"tab.inspect","created":true,"instance_id":"i1","window":{"id":"w1"},"tab":{"id":"old-tab"}}
    );
    try std.testing.expectError(error.ProtocolError, createdTab(wrong_action, "i1", "w1"));
    const wrong_type = try parse(a,
        \\{"action":"tab.create","created":true,"instance_id":"i1","window":{"id":"w1"},"tab":{"id":123}}
    );
    try std.testing.expectError(error.ProtocolError, createdTab(wrong_type, "i1", "w1"));
    const empty_id = try parse(a,
        \\{"action":"tab.create","created":true,"instance_id":"i1","window":{"id":"w1"},"tab":{"id":""}}
    );
    try std.testing.expectError(error.ProtocolError, createdTab(empty_id, "i1", "w1"));
}

test "prompt remains one positional argument after options and exact target IDs" {
    const prompt = "--instance other 'quoted' $(touch /tmp/no)";
    const args = inputArgs("i1", .{ .tab = "created-tab", .window = "w1" }, prompt);
    try std.testing.expectEqualStrings("--instance", args[2]);
    try std.testing.expectEqualStrings("i1", args[3]);
    try std.testing.expectEqualStrings("--tab", args[6]);
    try std.testing.expectEqualStrings("created-tab", args[7]);
    try std.testing.expectEqualStrings("--", args[8]);
    try std.testing.expectEqualStrings(prompt, args[9]);
}
