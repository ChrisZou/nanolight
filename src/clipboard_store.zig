//! Local clipboard history. No account or sync dependencies; payloads stay
//! in one private, atomically replaced file. Newest first; filtering puts
//! pins first. Pinning changes order, not the retention policy.
const std = @import("std");

pub const Kind = enum(u8) { text, png, tiff, file_url };
pub const Item = struct {
    id: u64,
    copied_at: i64,
    kind: Kind,
    pinned: bool = false,
    data: []const u8,
    /// The app it was copied in: its bundle's path, "" when unknown (a
    /// copy kept before apps were recorded).
    source: []const u8 = "",

    /// Substring search with ASCII case folding, like search.zig. Other
    /// UTF-8 bytes match exactly; binary image payloads aren't searched.
    pub fn matches(item: Item, query: []const u8) bool {
        if (query.len == 0) return true;
        if (item.kind != .text and item.kind != .file_url) return false;
        if (query.len > item.data.len) return false;
        for (0..item.data.len - query.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(item.data[i..][0..query.len], query)) return true;
        }
        return false;
    }
};

pub const Limits = struct {
    max_items: usize = 200,
    max_age_s: i64 = 7 * 24 * 60 * 60,
    max_item_bytes: usize = 16 << 20,
    max_bytes: usize = 32 << 20,
};

/// Version 2 adds each item's source app; version 1 files still load.
const magic = "NANOCLIP\x02";
const magic_v1 = "NANOCLIP\x01";
/// The longest source path kept.
pub const max_source = 1024;
pub const filename = "history.bin";

pub const Store = struct {
    gpa: std.mem.Allocator,
    limits: Limits = .{},
    items: std.ArrayList(Item) = .empty,
    next_id: u64 = 1,
    dirty: bool = false,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Store) void {
        for (s.items.items) |item| free(s.gpa, item);
        s.items.deinit(s.gpa);
    }

    /// Owns a copy. Consecutive identical copies refresh the existing item;
    /// nonconsecutive copies get new ids, even when an older item is pinned.
    /// Empty/oversize payloads are ignored, without evicting valid history.
    pub fn add(s: *Store, kind: Kind, data: []const u8, now: i64) !?u64 {
        return s.addFrom(kind, data, "", now);
    }

    /// As `add`, the copy made in the app at `source` (a bundle path).
    pub fn addFrom(s: *Store, kind: Kind, data: []const u8, source: []const u8, now: i64) !?u64 {
        if (data.len == 0 or data.len > s.limits.max_item_bytes or data.len > s.limits.max_bytes or s.limits.max_items == 0) return null;
        _ = s.prune(now);
        if (s.items.items.len > 0) {
            const last = &s.items.items[0];
            if (last.kind == kind and std.mem.eql(u8, last.data, data)) {
                last.copied_at = now;
                s.dirty = true;
                return last.id;
            }
        }
        if (s.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        const owned = try s.gpa.dupe(u8, data);
        errdefer s.gpa.free(owned);
        const from = try s.gpa.dupe(u8, if (source.len <= max_source) source else "");
        errdefer s.gpa.free(from);
        const id = s.next_id;
        try s.items.insert(s.gpa, 0, .{ .id = id, .copied_at = now, .kind = kind, .data = owned, .source = from });
        s.next_id += 1;
        s.dirty = true;
        _ = s.prune(now);
        return id;
    }

    pub fn get(s: *const Store, id: u64) ?Item {
        for (s.items.items) |item| if (item.id == id) return item;
        return null;
    }

    pub fn delete(s: *Store, id: u64) bool {
        for (s.items.items, 0..) |item, i| if (item.id == id) {
            s.remove(i);
            return true;
        };
        return false;
    }

    /// Clear history only; never modifies the system pasteboard. Ids aren't
    /// reused, so a stale selection cannot delete a later copy.
    pub fn clear(s: *Store) void {
        while (s.items.items.len > 0) s.remove(s.items.items.len - 1);
        s.dirty = true;
    }

    pub fn setPinned(s: *Store, id: u64, pinned: bool) bool {
        for (s.items.items) |*item| if (item.id == id) {
            item.pinned = pinned;
            s.dirty = true;
            return true;
        };
        return false;
    }

    /// Borrowed items in display order. The caller owns only the result slice;
    /// payloads remain valid until the store changes. Null kind means all types.
    pub fn filter(s: *const Store, gpa: std.mem.Allocator, query: []const u8, kind: ?Kind) ![]Item {
        var out: std.ArrayList(Item) = .empty;
        errdefer out.deinit(gpa);
        for ([_]bool{ true, false }) |pinned| for (s.items.items) |item| {
            if (item.pinned != pinned or (kind != null and item.kind != kind.?)) continue;
            if (item.matches(query)) try out.append(gpa, item);
        };
        return out.toOwnedSlice(gpa);
    }

    /// Age, count and byte bounds apply to every item, including pins.
    pub fn prune(s: *Store, now: i64) bool {
        const before = s.items.items.len;
        var i: usize = 0;
        var bytes: usize = 0;
        while (i < s.items.items.len) {
            const item = s.items.items[i];
            const expired = @as(i128, now) - item.copied_at >= s.limits.max_age_s;
            if (expired or i >= s.limits.max_items or item.data.len > s.limits.max_item_bytes or item.data.len > s.limits.max_bytes -| bytes) {
                s.remove(i);
            } else {
                bytes += item.data.len;
                i += 1;
            }
        }
        return before != s.items.items.len;
    }

    fn remove(s: *Store, i: usize) void {
        free(s.gpa, s.items.orderedRemove(i));
        s.dirty = true;
    }

    fn free(gpa: std.mem.Allocator, item: Item) void {
        gpa.free(item.data);
        gpa.free(item.source);
    }

    // Binary framing keeps image bytes intact without JSON's expansion.
    // All integers are little endian: magic, next id, count; then each
    // item's id, timestamp, kind, pin, length and payload, then its source
    // app's path and that path's length (u16) before it.
    pub fn encode(s: *const Store, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, magic);
        try put(&out, gpa, u64, s.next_id);
        try put(&out, gpa, u32, @intCast(s.items.items.len));
        for (s.items.items) |item| {
            try put(&out, gpa, u64, item.id);
            try put(&out, gpa, i64, item.copied_at);
            try out.append(gpa, @backingInt(item.kind));
            try out.append(gpa, @intFromBool(item.pinned));
            try put(&out, gpa, u32, @intCast(item.data.len));
            try out.appendSlice(gpa, item.data);
            try put(&out, gpa, u16, @intCast(item.source.len));
            try out.appendSlice(gpa, item.source);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Validate into a temporary store: malformed/truncated files leave the
    /// existing history intact. Loading also enforces retention immediately.
    pub fn decode(s: *Store, body: []const u8, now: i64) !void {
        var input: Input = .{ .bytes = body };
        const head = try input.take(magic.len);
        const v1 = std.mem.eql(u8, head, magic_v1);
        if (!v1 and !std.mem.eql(u8, head, magic)) return error.InvalidHistory;
        var next: Store = .{ .gpa = s.gpa, .limits = s.limits };
        errdefer next.deinit();
        next.next_id = try input.int(u64);
        if (next.next_id == 0) return error.InvalidHistory;
        const count = try input.int(u32);
        if (count > s.limits.max_items) return error.InvalidHistory;
        var previous = next.next_id;
        var bytes: usize = 0;
        for (0..count) |_| {
            const id = try input.int(u64);
            const copied_at = try input.int(i64);
            const kind = std.enums.fromInt(Kind, try input.int(u8)) orelse return error.InvalidHistory;
            const pin = try input.int(u8);
            const len = try input.int(u32);
            if (id == 0 or id >= previous or pin > 1 or len == 0 or len > s.limits.max_item_bytes or len > s.limits.max_bytes -| bytes) return error.InvalidHistory;
            const payload = try input.take(len);
            const source = if (v1) "" else try input.take(try input.int(u16));
            if (source.len > max_source) return error.InvalidHistory;
            const owned = try s.gpa.dupe(u8, payload);
            errdefer s.gpa.free(owned);
            const from = try s.gpa.dupe(u8, source);
            errdefer s.gpa.free(from);
            try next.items.append(s.gpa, .{ .id = id, .copied_at = copied_at, .kind = kind, .pinned = pin == 1, .data = owned, .source = from });
            previous = id;
            bytes += len;
        }
        if (input.bytes.len != 0) return error.InvalidHistory;
        _ = next.prune(now);
        s.deinit();
        s.* = next;
    }

    pub fn load(s: *Store, io: std.Io, dir: std.Io.Dir, now: i64) !void {
        const body = dir.readFileAlloc(io, filename, s.gpa, .limited(s.limits.max_bytes + s.limits.max_items * (24 + max_source) + 21)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer s.gpa.free(body);
        try s.decode(body, now);
    }

    pub fn save(s: *Store, io: std.Io, dir: std.Io.Dir) !void {
        if (!s.dirty) return;
        const body = try s.encode(s.gpa);
        defer s.gpa.free(body);
        var file = try dir.createFileAtomic(io, filename, .{ .replace = true, .permissions = .fromMode(0o600) });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, body);
        try file.file.sync(io);
        try file.replace(io);
        s.dirty = false;
    }
};

fn put(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(gpa, &buf);
}

const Input = struct {
    bytes: []const u8,

    fn take(in: *Input, len: usize) ![]const u8 {
        if (len > in.bytes.len) return error.InvalidHistory;
        const value = in.bytes[0..len];
        in.bytes = in.bytes[len..];
        return value;
    }

    fn int(in: *Input, comptime T: type) !T {
        return std.mem.readInt(T, (try in.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

test "clipboard owns payloads, deduplicates only consecutive copies and never reuses ids" {
    const t = std.testing;
    var s: Store = .init(t.allocator);
    defer s.deinit();
    var text = [_]u8{ 'h', 'i' };
    const first = (try s.add(.text, &text, 100)).?;
    text[0] = 'x';
    try t.expectEqualStrings("hi", s.get(first).?.data);
    try t.expectEqual(first, (try s.add(.text, "hi", 101)).?);
    try t.expectEqual(@as(usize, 1), s.items.items.len);
    try t.expectEqual(@as(i64, 101), s.get(first).?.copied_at);
    const image = (try s.add(.png, "hi", 102)).?;
    try t.expect(image != first);
    const third = (try s.add(.text, "hi", 103)).?;
    try t.expect(third != first);
    try t.expectEqual(@as(usize, 3), s.items.items.len);
    try t.expect(s.delete(image));
    try t.expect(s.get(image) == null);
    try t.expect(!s.delete(image));
    s.clear();
    try t.expectEqual(@as(usize, 0), s.items.items.len);
    try t.expect((try s.add(.text, "hi", 104)).? > third);
}

test "clipboard filters substrings and types, pins first without changing dedup order" {
    const t = std.testing;
    const a = t.allocator;
    var s: Store = .init(a);
    defer s.deinit();
    const first = (try s.add(.text, "Hello WORLD — 你好", 100)).?;
    const file = (try s.add(.file_url, "file:///Users/me/Hello.txt", 101)).?;
    const png = (try s.add(.png, "WORLD", 102)).?;
    const last = (try s.add(.text, "a world apart", 103)).?;
    try t.expect(s.setPinned(first, true));
    try t.expect(!s.setPinned(999, true));
    const all = try s.filter(a, "", null);
    defer a.free(all);
    try t.expectEqual(@as(usize, 4), all.len);
    try t.expectEqual(first, all[0].id);
    try t.expectEqual(last, all[1].id);
    try t.expectEqual(png, all[2].id);
    const words = try s.filter(a, "WoRlD", null);
    defer a.free(words);
    try t.expectEqual(@as(usize, 2), words.len);
    try t.expectEqual(first, words[0].id);
    try t.expectEqual(last, words[1].id);
    const files = try s.filter(a, "HELLO", .file_url);
    defer a.free(files);
    try t.expectEqual(file, files[0].id);
    const chinese = try s.filter(a, "你好", .text);
    defer a.free(chinese);
    try t.expectEqual(@as(usize, 1), chinese.len);
    try t.expectEqual(last, (try s.add(.text, "a world apart", 104)).?);
    try t.expect(s.setPinned(first, false));
    const unpinned = try s.filter(a, "", .text);
    defer a.free(unpinned);
    try t.expectEqual(last, unpinned[0].id);
    const none = try s.filter(a, "longer than any of the stored text payloads here", null);
    defer a.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
}

test "clipboard bounds count, age and bytes, including pins; ignores empty and oversize" {
    const t = std.testing;
    var s: Store = .{ .gpa = t.allocator, .limits = .{ .max_items = 2, .max_age_s = 10, .max_item_bytes = 4, .max_bytes = 6 } };
    defer s.deinit();
    const first = (try s.add(.text, "one", 100)).?;
    _ = try s.add(.text, "two", 101);
    try t.expect(s.setPinned(first, true));
    _ = try s.add(.text, "tri", 102);
    try t.expect(s.get(first) == null);
    try t.expectEqual(@as(usize, 2), s.items.items.len);
    const next = s.next_id;
    try t.expect(try s.add(.text, "", 103) == null);
    try t.expect(try s.add(.png, "12345", 103) == null);
    try t.expectEqual(next, s.next_id);
    _ = try s.add(.png, "1234", 104);
    try t.expectEqual(@as(usize, 1), s.items.items.len);
    try t.expect(!s.prune(113));
    try t.expect(s.prune(114));
    try t.expectEqual(@as(usize, 0), s.items.items.len);
    // Wall clock moving backwards doesn't overflow or expire recent copies.
    const future = (try s.add(.text, "now", 200)).?;
    try t.expect(!s.prune(std.math.minInt(i64)));
    try t.expect(s.setPinned(future, true));
    try t.expect(s.prune(210));
}

test "clipboard binary round-trip preserves image bytes, pins, ids and deletion" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var s: Store = .init(t.allocator);
    defer s.deinit();
    try s.load(t.io, tmp.dir, 100); // A missing file is an empty history.
    const png = (try s.add(.png, "\x89PNG\x00\xff\x80", 100)).?;
    const tiff = (try s.add(.tiff, "II\x2a\x00\xff", 101)).?;
    const text = (try s.add(.text, "two\nlines\x00tail", 102)).?;
    try t.expect(s.setPinned(png, true));
    try s.save(t.io, tmp.dir);
    try t.expect(!s.dirty);
    const stat = try tmp.dir.statFile(t.io, filename, .{});
    try t.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    var back: Store = .init(t.allocator);
    defer back.deinit();
    try back.load(t.io, tmp.dir, 103);
    try t.expectEqual(s.next_id, back.next_id);
    try t.expectEqualStrings(s.get(png).?.data, back.get(png).?.data);
    try t.expectEqualStrings(s.get(tiff).?.data, back.get(tiff).?.data);
    try t.expectEqualStrings(s.get(text).?.data, back.get(text).?.data);
    try t.expect(back.get(png).?.pinned);
    try t.expect(back.delete(tiff));
    try back.save(t.io, tmp.dir);
    try s.load(t.io, tmp.dir, 104);
    try t.expect(s.get(tiff) == null);
    back.clear();
    try back.save(t.io, tmp.dir);
    try s.load(t.io, tmp.dir, 105);
    try t.expectEqual(@as(usize, 0), s.items.items.len);
    try t.expect((try s.add(.text, "new", 106)).? > text);
}

test "clipboard loading prunes expired records and rejects corrupt input without replacing history" {
    const t = std.testing;
    const a = t.allocator;
    var s: Store = .init(a);
    defer s.deinit();
    _ = try s.add(.text, "old", 100);
    const recent = (try s.add(.text, "new", 200)).?;
    const body = try s.encode(a);
    defer a.free(body);
    var back: Store = .{ .gpa = a, .limits = .{ .max_age_s = 50 } };
    defer back.deinit();
    try back.decode(body, 210);
    try t.expect(back.dirty);
    try t.expectEqual(@as(usize, 1), back.items.items.len);
    try t.expectEqual(recent, back.items.items[0].id);
    // Every possible truncation, including in the second payload.
    for (0..body.len) |len| {
        try t.expectError(error.InvalidHistory, back.decode(body[0..len], 210));
        try t.expectEqual(recent, back.items.items[0].id);
    }
    const bad = try a.dupe(u8, body);
    defer a.free(bad);
    bad[0] = 'X';
    try t.expectError(error.InvalidHistory, back.decode(bad, 210));
    @memcpy(bad, body);
    bad[magic.len + 8 + 4 + 8 + 8] = 255; // Invalid kind.
    try t.expectError(error.InvalidHistory, back.decode(bad, 210));
    @memcpy(bad, body);
    bad[magic.len + 8 + 4 + 8 + 8 + 1] = 2; // Invalid pin.
    try t.expectError(error.InvalidHistory, back.decode(bad, 210));
    @memset(bad[magic.len..][0..8], 0); // Invalid next id.
    try t.expectError(error.InvalidHistory, back.decode(bad, 210));
    const extra = try std.mem.concat(a, u8, &.{ body, "extra" });
    defer a.free(extra);
    try t.expectError(error.InvalidHistory, back.decode(extra, 210));
}

test "clipboard keeps each copy's source app, and reads histories kept before it" {
    const t = std.testing;
    var s: Store = .init(t.allocator);
    defer s.deinit();
    _ = try s.addFrom(.text, "from Notes", "/System/Applications/Notes.app", 100);
    _ = try s.add(.text, "unknown", 101);
    const body = try s.encode(t.allocator);
    defer t.allocator.free(body);
    var back: Store = .init(t.allocator);
    defer back.deinit();
    try back.decode(body, 102);
    try t.expectEqualStrings("", back.items.items[0].source);
    try t.expectEqualStrings("/System/Applications/Notes.app", back.items.items[1].source);
    // A version 1 file: no source after each payload.
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(t.allocator);
    try old.appendSlice(t.allocator, magic_v1);
    try put(&old, t.allocator, u64, 2);
    try put(&old, t.allocator, u32, 1);
    try put(&old, t.allocator, u64, 1);
    try put(&old, t.allocator, i64, 100);
    try old.appendSlice(t.allocator, &.{ 0, 0 });
    try put(&old, t.allocator, u32, 2);
    try old.appendSlice(t.allocator, "hi");
    var legacy: Store = .init(t.allocator);
    defer legacy.deinit();
    try legacy.decode(old.items, 101);
    try t.expectEqualStrings("hi", legacy.items.items[0].data);
    try t.expectEqualStrings("", legacy.items.items[0].source);
}
