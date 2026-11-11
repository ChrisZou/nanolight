//! Local-only history viewer, laid out like Alfred's: the copies down the
//! left, one line each with the app they were copied in, and the selected
//! one shown whole on the right with when it was copied. Keep a separate
//! field from launcher search: clipboard queries must never reach web
//! suggestions or account sync.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const motion = ui.motion;
const history = @import("clipboard_store.zig");

pub const Action = enum { enable, paste, save, accessibility, close };
pub const Hooks = struct { ctx: *anyopaque, func: *const fn (*anyopaque, Action, u64) void };
pub const row_h: f32 = 36;
pub const visible_rows = 11;
pub const list_pad: f32 = 6;
/// The list's share of the panel; the preview takes the rest.
pub const list_w: f32 = 300;
/// Match `view.width` without importing view (avoids a cycle).
const panel_w: f32 = 680;
const preview_w: f32 = panel_w - list_w - 1;
const body_h: f32 = list_pad * 2 + visible_rows * row_h;
const field_h: f32 = 58;
const footer_h: f32 = 38;

pub const Panel = struct {
    store: ?*history.Store = null,
    enabled: bool = false,
    hooks: ?Hooks = null,
    query: ui.TextBuffer = .{},
    ids: [200]u64 = undefined,
    n: usize = 0,
    sel: usize = 0,
    /// The first row scrolled into view: ⌘1 is it.
    first: usize = 0,
    built: u64 = 1,
    scroll_selection: bool = true,
    message: []const u8 = "",
    needs_accessibility: bool = false,
    /// Source apps' and files' icons as PNG, by path hash; kept for the
    /// process.
    icons: std.AutoHashMapUnmanaged(u64, ?[]u8) = .empty,

    pub fn open(p: *Panel) void {
        p.query.clear();
        p.query.focus();
        p.sel = 0;
        p.first = 0;
        p.built = 1;
        p.scroll_selection = true;
        p.message = "";
        p.needs_accessibility = false;
    }

    pub fn action(p: *Panel, a: Action, id: u64) void {
        if (p.hooks) |h| h.func(h.ctx, a, id);
        if (a == .enable) p.query.focus();
    }

    pub fn fill(p: *Panel, arena: std.mem.Allocator) void {
        const hash = std.hash.Wyhash.hash(0, p.query.text());
        const changed = hash != p.built;
        const selected: ?u64 = if (!changed and p.sel < p.n) p.ids[p.sel] else null;
        const old_sel = p.sel;
        p.built = hash;
        p.n = 0;
        if (p.enabled) if (p.store) |s| {
            const found = s.filter(arena, p.query.text(), null) catch return;
            p.n = @min(found.len, p.ids.len);
            for (found[0..p.n], 0..) |item, i| p.ids[i] = item.id;
        };
        p.sel = if (changed) 0 else @min(p.sel, p.n -| 1);
        if (selected) |id| for (p.ids[0..p.n], 0..) |now, i| {
            if (now == id) {
                p.sel = i;
                break;
            }
        };
        if (changed or old_sel != p.sel) p.scroll_selection = true;
    }

    /// One height whenever there is history, so the preview never jumps.
    pub fn height(p: *const Panel) f32 {
        return field_h + footer_h + 2 + if (p.n == 0) @as(f32, 116) else body_h;
    }

    fn activate(p: *Panel) void {
        if (!p.enabled) return p.action(.enable, 0);
        if (p.sel < p.n) p.action(.paste, p.ids[p.sel]);
    }

    fn keys(p: *Panel, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) {
            if (p.query.text().len > 0) p.query.clear() else p.action(.close, 0);
        }
        if (p.n == 0) return;
        const store = p.store orelse return;
        if (c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true })) {
            if (p.sel + 1 < p.n) p.sel += 1;
            p.scroll_selection = true;
        }
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) {
            if (p.sel > 0) p.sel -= 1;
            p.scroll_selection = true;
        }
        // ⌘1…⌘9: the rows in view, from the top, as their hints say.
        for (1..10) |k| if (c.shortcut(.{ .key = @intCast('0' + k), .cmd = true })) {
            const i = p.first + k - 1;
            if (i < p.n) {
                p.sel = i;
                p.activate();
            }
        };
        if (c.shortcut(.{ .key = 0x7f, .alt = true })) {
            _ = store.delete(p.ids[p.sel]);
            p.action(.save, 0);
            p.fill(c.arena.allocator());
            p.scroll_selection = true;
        }
        if (p.n > 0 and c.shortcut(.{ .key = 'p', .cmd = true })) {
            const item = store.get(p.ids[p.sel]) orelse return;
            _ = store.setPinned(item.id, !item.pinned);
            p.action(.save, 0);
            p.fill(c.arena.allocator());
            p.scroll_selection = true;
        }
    }

    /// Draws inside the launcher's shell; same neutral glass and spacing.
    pub fn draw(p: *Panel, c: *ui.Context, colors: anytype, h: f32) void {
        const q0 = std.hash.Wyhash.hash(0, p.query.text());
        p.fill(c.arena.allocator());
        p.keys(c);
        {
            const bar = ui.div(c).row().wFull().h(field_h).px(18).gap(12).itemsCenter();
            defer bar.end();
            ui.icon(c, "clipboard", .{ .size = 19, .weight = .medium, .color = colors.sub, .frame = 22 });
            const field = ui.textField(c, &p.query, .{ .bare = true, .size = 21, .width = .fill, .placeholder = "Search clipboard…", .placeholder_color = colors.sub.alpha(0.75), .color = colors.text });
            // Refill only when typing changed the query — avoids a second fill
            // remapping selection / scroll on every arrow key.
            if (std.hash.Wyhash.hash(0, p.query.text()) != q0) p.fill(c.arena.allocator());
            if (field.submitted) p.activate();
        }
        ui.div(c).wFull().h(1).bg(colors.hair).end();
        {
            const body = ui.div(c).row().wFull().h(@max(0, h - field_h - footer_h - 2)).clip();
            defer body.end();
            if (p.n == 0) {
                const empty = ui.div(c).column().sizeFull().center().gap(12);
                defer empty.end();
                if (!p.enabled) {
                    if (ui.button(c, "Enable Clipboard History", .{}).clicked) p.action(.enable, 0);
                } else ui.text(c, if (p.query.text().len > 0) "No matches" else "No clipboard history", .{ .size = 14, .color = colors.sub });
            } else {
                p.list(c, colors);
                ui.div(c).w(1).hFull().bg(colors.hair).end();
                if (p.store.?.get(p.ids[p.sel])) |item| p.preview(c, colors, item);
            }
        }
        ui.div(c).wFull().h(1).bg(colors.hair).end();
        const bar = ui.div(c).row().wFull().h(footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        ui.text(c, if (p.message.len > 0) p.message else c.print("{d} items", .{p.n}), .{ .size = 12, .color = colors.sub });
        ui.spacer(c);
        if (p.needs_accessibility) {
            if (ui.button(c, "Accessibility…", .{ .size = 11 }).clicked) p.action(.accessibility, 0);
        } else if (p.n > 0) {
            ui.kbd(c, "⌥⌫");
            ui.kbd(c, "⌘P");
            ui.kbd(c, "↩");
        }
    }

    fn list(p: *Panel, c: *ui.Context, colors: anytype) void {
        const box = ui.div(c).column().w(list_w).hFull().p(list_pad).scrollY();
        defer box.end();
        const room = body_h - list_pad * 2;
        // Scroll against the panel's fixed height, not a springing frame h.
        if (p.scroll_selection) {
            const offset = c.scroll.get(box.id()) orelse 0;
            const y = @as(f32, @floatFromInt(p.sel)) * row_h;
            if (y < offset) c.setScroll(box.id(), .y, y) else if (y + row_h > offset + room) c.setScroll(box.id(), .y, y + row_h - room);
            p.scroll_selection = false;
        }
        const offset = c.scroll.get(box.id()) orelse 0;
        p.first = @intFromFloat(@max(0, @ceil(offset / row_h - 0.25)));
        // One absolute highlight bar, instant — matches main list, no spring overshoot.
        const sel_y = @as(f32, @floatFromInt(p.sel)) * row_h;
        const hy = motion.number(c, "clip-sel-y", sel_y, .instant);
        ui.div(c).absolute().offset(0, hy).w(list_w - list_pad * 2).h(row_h).rounded(8).bg(colors.sel).border(colors.rim).end();
        for (p.ids[0..p.n], 0..) |id, i| {
            const item = p.store.?.get(id) orelse continue;
            const label = title(c, item);
            ui.key(c, c.print("clip-row-{d}", .{id}));
            const row = ui.div(c).row().wFull().h(row_h).px(8).gap(10).itemsCenter().rounded(8).control();
            defer row.end();
            c.addA11y(row.index, .button, label, "", i == p.sel, true);
            if (row.clicked()) {
                p.sel = i;
                p.activate();
            }
            p.mark(c, colors, item);
            ui.text(c, label, .{ .size = 13.5, .weight = .medium, .color = colors.text, .truncate = .ellipsis });
            ui.spacer(c);
            if (item.pinned) ui.icon(c, "pin.fill", .{ .size = 10, .color = colors.sub });
            if (i == p.sel) {
                ui.kbd(c, "↩");
            } else if (i >= p.first and i - p.first < 9) {
                ui.textf(c, .{ .size = 12, .weight = .medium, .color = colors.sub.alpha(0.5), .tabular = true }, "⌘{d}", .{i - p.first + 1});
            }
        }
    }

    /// The app it was copied in, else what kind of copy it is.
    fn mark(p: *Panel, c: *ui.Context, colors: anytype, item: history.Item) void {
        if (p.icon(item.source)) |png| {
            if (ui.image(c, .{ .key = c.print("app-{s}", .{item.source}), .bytes = png, .max_width = 22, .max_height = 22, .radius = 0, .scale = 2 })) return;
        }
        const tile = ui.div(c).size(22, 22).rounded(5).bg(colors.tile).center();
        defer tile.end();
        ui.icon(c, switch (item.kind) {
            .png, .tiff => "photo",
            .file_url => "doc",
            .text => "text.alignleft",
        }, .{ .size = 12, .color = colors.sub });
    }

    fn icon(p: *Panel, path: []const u8) ?[]const u8 {
        if (path.len == 0 or builtin.os.tag != .macos) return null;
        const k = std.hash.Wyhash.hash(0, path);
        if (p.icons.get(k)) |png| return png;
        const png = @import("apps.zig").iconPng(std.heap.smp_allocator, path);
        p.icons.put(std.heap.smp_allocator, k, png) catch {};
        return png;
    }

    /// One file: its icon, name and folder. Several: the first's icon, how
    /// many, and their names, as many as fit.
    fn files(p: *Panel, c: *ui.Context, colors: anytype, item: history.Item, room_h: f32) void {
        const n = std.mem.count(u8, item.data, "\n") + 1;
        var lines = std.mem.splitScalar(u8, item.data, '\n');
        const first = filePath(c, lines.first());
        const box = ui.div(c).column().sizeFull().center().gap(10);
        defer box.end();
        if (p.icon(first)) |png| {
            _ = ui.image(c, .{ .key = c.print("file-{s}", .{first}), .bytes = png, .max_width = 64, .max_height = 64, .radius = 0, .scale = 1 });
        }
        if (n == 1) {
            ui.text(c, std.fs.path.basename(first), .{ .size = 14, .weight = .medium, .color = colors.text, .truncate = .middle });
            ui.text(c, std.fs.path.dirname(first) orelse "", .{ .size = 12, .color = colors.sub, .truncate = .middle });
            return;
        }
        ui.text(c, c.print("{d} Files", .{n}), .{ .size = 14, .weight = .medium, .color = colors.text });
        const fit: usize = @intFromFloat(@max(1, @floor((room_h - 64 - 20 - 30) / 18)));
        lines.reset();
        var shown: usize = 0;
        while (lines.next()) |url| : (shown += 1) {
            if (shown + 1 == fit and n > fit) {
                ui.text(c, c.print("and {d} more", .{n - shown}), .{ .size = 12, .color = colors.sub });
                break;
            }
            ui.text(c, std.fs.path.basename(filePath(c, url)), .{ .size = 12, .color = colors.sub, .truncate = .middle });
        }
    }

    /// The selected copy, whole: a picture fitted, text from its start, a
    /// file by its icon and path; when it was copied underneath.
    fn preview(p: *Panel, c: *ui.Context, colors: anytype, item: history.Item) void {
        const pane = ui.div(c).column().w(preview_w).hFull().px(18).pt(16).pb(12).gap(10);
        defer pane.end();
        const room_h = body_h - 16 - 12 - 10 - 18;
        {
            const content = ui.div(c).column().wFull().h(room_h).clip();
            defer content.end();
            switch (item.kind) {
                .png, .tiff => {
                    const box = ui.div(c).column().sizeFull().center();
                    defer box.end();
                    _ = ui.image(c, .{ .key = c.print("clip-{d}", .{item.id}), .bytes = item.data, .max_width = preview_w - 36, .max_height = room_h, .radius = 6, .scale = 2 });
                },
                .text => ui.text(c, whole(c, item.data), .{ .size = 13, .color = colors.text, .wrap = true, .line_height = 19, .max_lines = @intFromFloat(@floor(room_h / 19)) }),
                .file_url => p.files(c, colors, item, room_h),
            }
        }
        const foot = ui.div(c).row().wFull().h(18).justifyCenter().itemsCenter();
        defer foot.end();
        // The frame keeps the words until it is drawn: the arena's, not the stack's.
        const buf = c.arena.allocator().alloc(u8, 48) catch return;
        ui.text(c, copiedLabel(buf, item.copied_at, time(null)), .{ .size = 12, .color = colors.sub });
    }
};

/// A copy's one line in the list: text with its breaks flattened, an
/// image by its size ("Image: 2126×1448 (11.7 MB)"), a file by its name.
fn title(c: *ui.Context, item: history.Item) []const u8 {
    if (item.kind == .png or item.kind == .tiff) {
        var size: [24]u8 = undefined;
        const bytes = byteSize(&size, item.data.len);
        return if (imageSize(item.data)) |d| c.print("Image: {d}×{d} ({s})", .{ d[0], d[1], bytes }) else c.print("Image ({s})", .{bytes});
    }
    if (item.kind == .file_url) {
        const n = std.mem.count(u8, item.data, "\n") + 1;
        var lines = std.mem.splitScalar(u8, item.data, '\n');
        if (n == 1) return std.fs.path.basename(filePath(c, item.data));
        // "3 Files: a.txt, b.png, c.pdf", as an image is titled by what it is.
        var out: std.ArrayList(u8) = .empty;
        const a = c.arena.allocator();
        out.print(a, "{d} Files: ", .{n}) catch return "";
        var i: usize = 0;
        while (lines.next()) |url| : (i += 1) {
            if (i > 0) out.appendSlice(a, ", ") catch break;
            out.appendSlice(a, std.fs.path.basename(filePath(c, url))) catch break;
            if (out.items.len > 300) break;
        }
        return out.items;
    }
    const text = c.arena.allocator().dupe(u8, clip(std.mem.trimStart(u8, item.data, " \t\r\n"), 512)) catch return "";
    for (text) |*ch| if (ch.* < 32) {
        ch.* = ' ';
    };
    return text;
}

/// Text as the preview shows it: its lines kept, bounded for shaping.
fn whole(c: *ui.Context, data: []const u8) []const u8 {
    const text = c.arena.allocator().dupe(u8, clip(data, 4000)) catch return "";
    for (text) |*ch| if (ch.* < 32 and ch.* != '\n') {
        ch.* = ' ';
    };
    return text;
}

/// At most `max` bytes, never splitting a UTF-8 character.
fn clip(s: []const u8, max: usize) []const u8 {
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

/// A file URL's path, its %-escapes decoded ("Design notes.pdf"). A
/// reference URL Finder gave before copies were kept by path
/// ("/.file/id=…") is looked up.
fn filePath(c: *ui.Context, url: []const u8) []const u8 {
    if (builtin.os.tag == .macos and std.mem.startsWith(u8, url, "file:///.file/id=")) {
        const objc = @import("nanoui").objc;
        const ref = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)});
        const file = if (ref) |r| objc.msg(?objc.Object, r, "filePathURL", .{}) else null;
        if (file) |f| return c.arena.allocator().dupe(u8, objc.fromNSString(objc.msg(?objc.Object, f, "path", .{}))) catch url;
        return url;
    }
    const buf = c.arena.allocator().alloc(u8, url.len) catch return url;
    return history.urlPath(buf, url);
}

/// A picture's pixel size, from a PNG's or a TIFF's header.
pub fn imageSize(b: []const u8) ?[2]u32 {
    if (b.len >= 24 and std.mem.eql(u8, b[0..8], "\x89PNG\r\n\x1a\n"))
        return .{ std.mem.readInt(u32, b[16..20], .big), std.mem.readInt(u32, b[20..24], .big) };
    if (b.len < 8) return null;
    const e: std.builtin.Endian = if (std.mem.eql(u8, b[0..2], "II")) .little else if (std.mem.eql(u8, b[0..2], "MM")) .big else return null;
    const ifd: usize = std.mem.readInt(u32, b[4..8], e);
    if (ifd + 2 > b.len) return null;
    const count = std.mem.readInt(u16, b[ifd..][0..2], e);
    var w: ?u32 = null;
    var h: ?u32 = null;
    for (0..count) |i| {
        const at = ifd + 2 + i * 12;
        if (at + 12 > b.len) break;
        const tag = std.mem.readInt(u16, b[at..][0..2], e);
        // SHORT (3) or LONG (4), held in the entry's last four bytes.
        const v: u32 = switch (std.mem.readInt(u16, b[at + 2 ..][0..2], e)) {
            3 => std.mem.readInt(u16, b[at + 8 ..][0..2], e),
            4 => std.mem.readInt(u32, b[at + 8 ..][0..4], e),
            else => continue,
        };
        if (tag == 256) w = v else if (tag == 257) h = v;
    }
    return if (w != null and h != null) .{ w.?, h.? } else null;
}

/// "820 KB", "11.7 MB".
fn byteSize(buf: []u8, n: usize) []const u8 {
    if (n < 1000 * 1024) return std.fmt.bufPrint(buf, "{d} KB", .{(n + 1023) / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(n)) / (1024 * 1024)}) catch "";
}

const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;

/// Seconds east of UTC at `t`, where the Mac is.
fn utcOffset(t: i64) i64 {
    var tm: Tm = undefined;
    const v: c_long = @intCast(t);
    return if (localtime_r(&v, &tm) != null) tm.gmtoff else 0;
}

/// "Copied Today 13:09", "Copied Yesterday 18:02", "Copied Monday 09:15",
/// "Copied Oct 28 09:15": `then` and `now` in Unix seconds.
fn copiedLabel(buf: []u8, then: i64, now: i64) []const u8 {
    return labelLocal(buf, then + utcOffset(then), now + utcOffset(now));
}

fn labelLocal(buf: []u8, then: i64, now: i64) []const u8 {
    const day = @divFloor(then, 86400);
    const secs = @mod(then, 86400);
    const ago = @divFloor(now, 86400) - day;
    const hm = .{ @as(u32, @intCast(@divFloor(secs, 3600))), @as(u32, @intCast(@divFloor(@mod(secs, 3600), 60))) };
    const days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (ago == 0) return std.fmt.bufPrint(buf, "Copied Today {d:0>2}:{d:0>2}", hm) catch "";
    if (ago == 1) return std.fmt.bufPrint(buf, "Copied Yesterday {d:0>2}:{d:0>2}", hm) catch "";
    // 1970-01-01 was a Thursday.
    if (ago > 1 and ago < 7) return std.fmt.bufPrint(buf, "Copied {s} {d:0>2}:{d:0>2}", .{ days[@intCast(@mod(day + 4, 7))], hm[0], hm[1] }) catch "";
    const md = (std.time.epoch.EpochDay{ .day = @intCast(@max(0, day)) }).calculateYearDay().calculateMonthDay();
    return std.fmt.bufPrint(buf, "Copied {s} {d} {d:0>2}:{d:0>2}", .{ months[md.month.numeric() - 1], md.day_index + 1, hm[0], hm[1] }) catch "";
}

test "a copy's time reads as Alfred's does" {
    const t = std.testing;
    var buf: [48]u8 = undefined;
    // 2026-11-04 13:09 and earlier, all local.
    const now: i64 = 1793797740;
    try t.expectEqualStrings("Copied Today 13:09", labelLocal(&buf, now, now));
    try t.expectEqualStrings("Copied Yesterday 18:02", labelLocal(&buf, now - 86400 + 4 * 3600 + 53 * 60, now));
    try t.expectEqualStrings("Copied Monday 09:15", labelLocal(&buf, now - 2 * 86400 - 3 * 3600 - 54 * 60, now));
    try t.expectEqualStrings("Copied Oct 28 13:09", labelLocal(&buf, now - 7 * 86400, now));
}

test "pictures are titled by their pixel size" {
    const t = std.testing;
    var png: [24]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[16..20], 2126, .big);
    std.mem.writeInt(u32, png[20..24], 1448, .big);
    try t.expectEqual([2]u32{ 2126, 1448 }, imageSize(&png).?);
    // A little-endian TIFF: one IFD at 8 with a SHORT width and a LONG height.
    var tiff: [40]u8 = @splat(0);
    @memcpy(tiff[0..4], "II*\x00");
    std.mem.writeInt(u32, tiff[4..8], 8, .little);
    std.mem.writeInt(u16, tiff[8..10], 2, .little);
    for ([_][3]u32{ .{ 256, 3, 754 }, .{ 257, 4, 460 } }, 0..) |f, i| {
        const at = 10 + i * 12;
        std.mem.writeInt(u16, tiff[at..][0..2], @intCast(f[0]), .little);
        std.mem.writeInt(u16, tiff[at + 2 ..][0..2], @intCast(f[1]), .little);
        std.mem.writeInt(u32, tiff[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, tiff[at + 8 ..][0..4], f[2], .little);
    }
    try t.expectEqual([2]u32{ 754, 460 }, imageSize(&tiff).?);
    try t.expect(imageSize("not a picture") == null);
    var buf: [24]u8 = undefined;
    try t.expectEqualStrings("11.7 MB", byteSize(&buf, 12268339));
    try t.expectEqualStrings("820 KB", byteSize(&buf, 820 * 1024));
}
