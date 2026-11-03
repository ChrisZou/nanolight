//! A search that runs a program (sqlite3 for Picemon, fsearch for files)
//! off the main thread, so typing never waits on it. Throttled: while a
//! search runs, newer words wait, and only the latest is searched next.
//! Hits reach the panel on the main thread, and only for the words they
//! were searched for.
const std = @import("std");
const nanoui = @import("nanoui");

/// How long typing settles before the first search.
pub const settle_ms = 90;
/// How often the main thread looks for a finished search.
const poll_ms = 25;
pub const max_needle = 128;

pub fn Lookup(
    comptime List: type,
    comptime search: fn (gpa: std.mem.Allocator, io: std.Io, home: []const u8, needle: []const u8, out: *List) void,
) type {
    return struct {
        const Self = @This();
        pub const Done = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, needle: []const u8, hits: *const List) void };

        gpa: std.mem.Allocator,
        io: std.Io,
        home: []const u8,
        done: Done,

        // The main thread's: the words last asked for.
        want: [max_needle]u8 = undefined,
        want_len: usize = 0,
        want_gen: u32 = 0,
        ticking: bool = false,

        // The worker's while `busy`; the main thread's otherwise.
        job: [max_needle]u8 = undefined,
        job_len: usize = 0,
        job_gen: u32 = 0,
        started_gen: u32 = 0,
        result: List = .{},
        has_result: bool = false,
        busy: std.atomic.Value(bool) = .init(false),

        /// Asks for `needle`'s hits (main thread). They arrive through
        /// `done`, unless newer words are asked for first.
        pub fn request(l: *Self, needle: []const u8) void {
            const n = @min(needle.len, max_needle);
            @memcpy(l.want[0..n], needle[0..n]);
            l.want_len = n;
            l.want_gen +%= 1;
            if (!l.ticking) {
                l.ticking = true;
                nanoui.App.after(settle_ms, l, tick);
            }
        }

        fn tick(ctx: ?*anyopaque) callconv(.c) void {
            const l: *Self = @ptrCast(@alignCast(ctx.?));
            if (l.busy.load(.acquire)) return nanoui.App.after(poll_ms, l, tick);
            if (l.has_result) {
                l.has_result = false;
                // Stale hits (the words changed since) are dropped.
                if (l.job_gen == l.want_gen) l.done.func(l.done.ctx, l.job[0..l.job_len], &l.result);
            }
            if (l.started_gen != l.want_gen) {
                @memcpy(l.job[0..l.want_len], l.want[0..l.want_len]);
                l.job_len = l.want_len;
                l.job_gen = l.want_gen;
                l.started_gen = l.want_gen;
                l.busy.store(true, .release);
                const t = std.Thread.spawn(.{}, work, .{l}) catch {
                    l.busy.store(false, .release);
                    l.ticking = false;
                    return;
                };
                t.detach();
                return nanoui.App.after(poll_ms, l, tick);
            }
            l.ticking = false;
        }

        fn work(l: *Self) void {
            l.result.clear();
            search(l.gpa, l.io, l.home, l.job[0..l.job_len], &l.result);
            l.has_result = true;
            l.busy.store(false, .release);
        }
    };
}
