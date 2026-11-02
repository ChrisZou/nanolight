//! Local-only history viewer. Keep a separate field from launcher search:
//! clipboard queries must never reach web suggestions or account sync.
const std = @import("std");
const ui = @import("nanoui").ui;
const history = @import("clipboard_store.zig");

pub const Action = enum { enable, paste, save, accessibility, close };
pub const Hooks = struct { ctx: *anyopaque, func: *const fn (*anyopaque, Action, u64) void };
const row_h: f32 = 48;
const visible_rows = 9;

pub const Panel = struct {
    store: ?*history.Store = null,
    enabled: bool = false,
    hooks: ?Hooks = null,
    query: ui.TextBuffer = .{},
    ids: [200]u64 = undefined,
    n: usize = 0,
    sel: usize = 0,
    built: u64 = 1,
    scroll_selection: bool = true,
    message: []const u8 = "",
    needs_accessibility: bool = false,

    pub fn open(p: *Panel) void {
        p.query.clear();
        p.query.focus();
        p.sel = 0;
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

    pub fn height(p: *const Panel) f32 {
        return 58 + 38 + 2 + if (p.n == 0) @as(f32, 116) else 12 + @as(f32, @floatFromInt(@min(p.n, visible_rows))) * row_h;
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
            p.sel = (p.sel + 1) % p.n;
            p.scroll_selection = true;
        }
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) {
            p.sel = (p.sel + p.n - 1) % p.n;
            p.scroll_selection = true;
        }
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
        p.fill(c.arena.allocator());
        p.keys(c);
        {
            const bar = ui.div(c).row().wFull().h(58).px(18).gap(12).itemsCenter();
            defer bar.end();
            ui.icon(c, "clipboard", .{ .size = 19, .weight = .medium, .color = colors.sub, .frame = 22 });
            const field = ui.textField(c, &p.query, .{ .bare = true, .size = 21, .width = .fill, .placeholder = "Search clipboard…", .placeholder_color = colors.sub.alpha(0.75), .color = colors.text });
            p.fill(c.arena.allocator());
            if (field.submitted) p.activate();
        }
        ui.div(c).wFull().h(1).bg(colors.hair).end();
        {
            const body = ui.div(c).column().wFull().h(@max(0, h - 98)).clip();
            defer body.end();
            if (p.n == 0) {
                const empty = ui.div(c).column().sizeFull().center().gap(12);
                defer empty.end();
                if (!p.enabled) {
                    if (ui.button(c, "Enable Clipboard History", .{}).clicked) p.action(.enable, 0);
                } else ui.text(c, if (p.query.text().len > 0) "No matches" else "No clipboard history", .{ .size = 14, .color = colors.sub });
            } else {
                const list = ui.div(c).column().wFull().hFull().p(6).scrollY();
                defer list.end();
                if (p.scroll_selection) {
                    const offset = c.scroll.get(list.id()) orelse 0;
                    const y = @as(f32, @floatFromInt(p.sel)) * row_h;
                    const room = @max(row_h, h - 110);
                    if (y < offset) c.setScroll(list.id(), .y, y) else if (y + row_h > offset + room) c.setScroll(list.id(), .y, y + row_h - room);
                    p.scroll_selection = false;
                }
                for (p.ids[0..p.n], 0..) |id, i| {
                    const item = p.store.?.get(id) orelse continue;
                    const label = title(c, item);
                    const row = ui.div(c).row().wFull().h(row_h).px(10).gap(12).itemsCenter().rounded(10).bg(if (i == p.sel) colors.sel else ui.Color.transparent).control();
                    defer row.end();
                    c.addA11y(row.index, .button, label, "", i == p.sel, true);
                    if (row.clicked()) {
                        p.sel = i;
                        p.activate();
                    }
                    {
                        const tile = ui.div(c).size(30, 30).rounded(6).bg(colors.tile).center().clip();
                        defer tile.end();
                        if (item.kind == .png or item.kind == .tiff) {
                            _ = ui.image(c, .{ .key = c.print("clip-{d}", .{id}), .bytes = item.data, .max_width = 30, .max_height = 30, .radius = 4, .scale = 1 });
                        } else ui.icon(c, if (item.kind == .file_url) "doc" else "text.alignleft", .{ .size = 15, .color = colors.sub });
                    }
                    ui.text(c, label, .{ .size = 13.5, .weight = .medium, .color = colors.text, .truncate = .ellipsis });
                    ui.spacer(c);
                    if (item.pinned) ui.icon(c, "pin.fill", .{ .size = 11, .color = colors.sub });
                    if (i == p.sel) ui.kbd(c, "↩");
                }
            }
        }
        ui.div(c).wFull().h(1).bg(colors.hair).end();
        const bar = ui.div(c).row().wFull().h(38).px(16).gap(8).itemsCenter();
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
};

fn title(c: *ui.Context, item: history.Item) []const u8 {
    if (item.kind == .png or item.kind == .tiff) return c.print("Image · {d} KB", .{(item.data.len + 1023) / 1024});
    const raw = if (item.kind == .file_url) fileLabel(item.data) else item.data;
    // Bound shaping cost and never split a UTF-8 character. Collapse line
    // breaks so a multiline copy stays a single, consistently sized row.
    var end = @min(raw.len, 512);
    while (end > 0 and end < raw.len and raw[end] & 0xc0 == 0x80) end -= 1;
    const text = c.arena.allocator().dupe(u8, raw[0..end]) catch return "";
    for (text) |*ch| if (ch.* < 32) {
        ch.* = ' ';
    };
    return text;
}

/// Last path segment of a file URL for the row label.
fn fileLabel(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.startsWith(u8, s, "file://")) s = s["file://".len..];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s = s[i + 1 ..];
    return if (s.len > 0) s else url;
}
