//! The launcher panel: the query, then what it finds in sections, then a
//! footer naming what Return does. Neutral glass, a hairline rim, 40-point
//! rows, the selection a grey step that slides between them. Nothing moves
//! while nothing happens: frames come from keys, and from height settling.
const std = @import("std");
const build_options = @import("build_options");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const Index = @import("apps.zig").Index;
const results = @import("results.zig");
const suggest = @import("suggest.zig");
const settings_view = @import("settings_view.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Row = results.Row;

/// What the panel asks of whatever shows it (the window, or the film).
pub const Host = struct {
    ctx: *anyopaque,
    /// Opens an app's path or a URL.
    open: *const fn (ctx: *anyopaque, target: []const u8) void,
    hide: *const fn (ctx: *anyopaque) void,
    /// The panel's height changed: a window follows it.
    resize: ?*const fn (ctx: *anyopaque, h: f32) void = null,
    /// Google's completions of a query aren't known: ask for them, and
    /// answer with `Nanolight.answered`. Without it, none are listed.
    suggest: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    /// Shows a search's page in the panel, over `webArea`; null takes it
    /// away. Without it, searches open in the browser.
    preview: ?*const fn (ctx: *anyopaque, url: ?[]const u8) void = null,
    /// Starts a Picemon search (`img ` / `pic `), off the main thread; the
    /// hits arrive in `Nanolight.picsArrived`.
    pic: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    /// Starts an FSearch file search (`f ` / `find ` / `file `); the hits
    /// arrive in `Nanolight.filesArrived`.
    file: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    /// Start a Codex one-shot; the answer lands in `Nanolight.aiDone`.
    ai: ?*const fn (ctx: *anyopaque, question: []const u8) void = null,
    /// Puts the panel back where it first opened (a double click on its
    /// background), forgetting where it was dragged.
    recenter: ?*const fn (ctx: *anyopaque) void = null,
    /// Relaunch this bundle then quit (`reload` / `restart`).
    restart: ?*const fn (ctx: *anyopaque) void = null,
    /// Quit Nanolight (`quit`).
    quit: ?*const fn (ctx: *anyopaque) void = null,
    /// POST a note to a Grok Bot's webhook (`pm ` 项目经理, `af ` Alfred).
    pm: ?*const fn (ctx: *anyopaque, bot: @import("pm.zig").Bot, body: []const u8) void = null,
    /// Settings (the shortcut, login, sync, updates). Without it the
    /// screen still draws, and changes nothing the app keeps.
    settings: ?*const SettingsHost = null,
};

pub const width: f32 = 680;

/// The app's icon (icon.png, made smaller), for the panel and the film.
pub const icon_png = @embedFile("icon-256.png");

/// The app's icon, `size` points square.
pub fn appIcon(c: *ui.Context, size: f32) void {
    _ = ui.image(c, .{ .key = "nanolight-icon", .bytes = icon_png, .max_width = size, .max_height = size, .radius = 0, .scale = 2 });
}
pub const header_h = 58;
pub const row_h = 40;
const calc_h = 92;
const ai_h = 120;
pub const section_h = 28;
pub const footer_h = 38;
pub const list_pad = 6;
/// The room a window leaves round the panel for its shadow (`Nanolight.margin`).
pub const shadow_margin: f32 = 40;
/// The tallest the panel gets: every app row and Ask Codex (or a pic/file
/// list), under two section heads, a search's page, or Settings (taller
/// than this fork's eight rows). The window is this tall.
pub const max_height: f32 = @max(
    header_h + footer_h + 2 + list_pad * 2 + results.max_rows * row_h + 2 * section_h,
    @import("settings_view.zig").height,
);

/// Where a search's page goes in a panel `h` tall: from `y` down from its
/// top, `h` tall, between the header and the footer, the panel's width.
pub fn webArea(h: f32) struct { y: f32, h: f32 } {
    return .{ .y = header_h + 1, .h = @max(0, h - header_h - footer_h - 2) };
}
/// Opening and growing: snappy, a touch under critical damping.
pub const spring: motion.Spring = .{ .stiffness = 320, .damping = 32 };
const slide: motion.Spring = .{ .stiffness = 700, .damping = 52 };

pub const Palette = @import("palette.zig").Palette;
pub const palette = @import("palette.zig").palette;

pub const Nanolight = struct {
    index: *Index,
    clip: @import("clipboard_panel.zig").Panel = .{},
    clip_mode: bool = false,
    query: ui.TextBuffer = .{},
    res: results.Results = .{},
    sel: usize = 0,
    /// The query the rows were built for.
    built: u64 = 1,
    /// `built` as of the last highlight sample: a new list jumps the highlight;
    /// the same list slides it when the selection moves.
    sel_built: u64 = 0,
    host: ?Host = null,
    /// Draws its own Liquid Glass (over a desktop nanoui painted, as the
    /// film does); otherwise the window's system glass is under it.
    own_glass: bool = false,
    /// Clear room round the panel in its window, for its shadow.
    margin: f32 = 0,
    /// The window fades in as it shows, the system's glass with it
    /// (panel_mac.zig): the panel has no entrance of its own (issue #9).
    window_fades: bool = false,
    /// Return sends a Google search to the browser and ⌘↩ shows it in
    /// the panel, the other way round from the default (issue #10).
    searches_out: bool = false,
    /// Each showing gets a new one: the panel comes in again.
    shown: u32 = 0,
    copied_at: f64 = -10,
    kv: ?nanoui.kv.Store = null,
    spans: [results.max_rows][16]ui.Span = undefined,
    url_buf: [1024]u8 = undefined,
    last_h: f32 = 0,
    /// The query as it was shown: selected, so no completion after it yet.
    revealed: u64 = 0,
    /// Said in the footer in place of the name ("Updated to 0.1.3"), if set.
    note: []const u8 = "",
    /// The first-run welcome, drawn while it is active.
    onboard: ?*@import("onboard.zig").Onboard = null,
    /// Google's completions: whether to ask, those listed, the answers.
    suggest_on: bool = true,
    web: suggest.List = .{},
    cache: suggest.Cache = .{},
    /// A search's page is in the panel, for the query as it was then.
    previewing: bool = false,
    preview_q: u64 = 0,
    preview_buf: [1024]u8 = undefined,
    preview_url: []const u8 = "",
    /// Picemon hits for the current `img `/`pic ` query.
    pics: @import("pic.zig").List = .{},
    /// FSearch hits for the current `f `/`find `/`file ` query.
    files: @import("file.zig").List = .{},
    /// The words last searched for (their hash): a search runs once per
    /// change, and only its own words' hits are taken.
    pics_asked: u64 = 0,
    files_asked: u64 = 0,
    /// Codex Q&A (plain query default, or `ai `/`ask `).
    ai_status: @import("ai.zig").Status = .ready,
    ai_question: [@import("ai.zig").max_question]u8 = undefined,
    ai_question_len: usize = 0,
    ai_buf: [@import("ai.zig").max_answer]u8 = undefined,
    ai_text: []const u8 = "",
    /// Bumped each ask so a late answer is ignored.
    ai_gen: u32 = 0,
    /// Body for the current `pm ` / `af ` row.
    pm_body: [@import("pm.zig").max_body]u8 = undefined,
    pm_body_len: usize = 0,
    /// Settings, drawn in the panel in place of the rows.
    settings_ui: settings_view.Settings = .{},
    ext: ?*@import("raycast_view.zig").Ext = null,

    /// Called as it is shown: the query selected, the keys its own.
    pub fn reveal(s: *Nanolight) void {
        s.back();
        s.settings_ui.hide();
        s.shown +%= 1;
        // Suggestions follow what was opened since.
        s.built = 1;
        s.revealed = std.hash.Wyhash.hash(0, s.query.text());
        s.query.want_selection = .{ 0, s.query.text().len };
        s.query.focus();
    }

    /// The panel's height for the rows it lists.
    pub fn height(s: *const Nanolight) f32 {
        if (s.clip_mode) return s.clip.height();
        if (s.settings_ui.open) return settings_view.height;
        if (s.ext) |e| if (e.open) return e.height();
        if (s.previewing) return max_height;
        // Nothing typed: the field alone.
        if (s.res.n == 0) return header_h;
        var h: f32 = header_h + footer_h + 1;
        h += 1 + list_pad * 2;
        for (s.res.slice(), 0..) |r, i| {
            h += switch (r.kind) {
                .calc => calc_h,
                .ai_answer => ai_h,
                else => row_h,
            };
            if (s.res.section(i) != null) h += section_h;
        }
        return h;
    }

    /// The window's view: the panel, `margin` in from the window's edges.
    pub fn view(s: *Nanolight, c: *ui.Context) void {
        ui.key(c, c.print("panel-{d}", .{s.shown}));
        // Opaque from the first frame: fading in from 0 flashed the glass behind it.
        const entrance: motion.Target = .{ .opacity = 1, .y = -6, .scale = 0.985 };
        const f = motion.frame(c, .{ .initial = if (s.window_fades) null else entrance, .transition = .{ .spring = spring } });
        const root = ui.div(c).wFull().p(s.margin).motion(f);
        defer root.end();
        s.panel(c);
    }

    pub fn panel(s: *Nanolight, c: *ui.Context) void {
        const p = palette(c.theme.dark);
        const shell = ui.div(c).column().w(width).rounded(18).border(p.hair).clip();
        if (s.own_glass) {
            _ = shell.glass(.{ .tint = if (c.theme.dark) ui.Color.black.alpha(0.42) else ui.Color.white.alpha(0.5) })
                .shadows(&.{ .{ .color = .{ .a = 0.22 }, .blur = 4, .y = 1 }, .{ .color = .{ .a = 0.28 }, .blur = 40, .y = 18 } });
        } else {
            // The system's shadow is off (its outline drew a black ring
            // round the panel): this one is soft, and outside the panel
            // only, so the glass under it stays clear.
            _ = shell.bg(p.fill).shadows(&.{
                .{ .color = .{ .a = 0.16 }, .blur = 3, .y = 1, .knockout = true },
                .{ .color = .{ .a = 0.24 }, .blur = 28, .y = 12, .knockout = true },
            });
        }
        defer shell.end();
        // As Alfred's: anywhere that isn't a field, a row or a button moves
        // the panel, and it opens there next time.
        c.node(shell.index).style.window_drag = true;
        if (c.interact(shell.index, .{}).double_clicked) if (s.host) |host| if (host.recenter) |f| f(host.ctx);
        if (!s.clip_mode) if (s.onboard) |o| if (o.active) {
            const h = s.follow(c, o.height());
            const body = ui.div(c).column().wFull().h(h).clip();
            defer body.end();
            o.view(c, s, p);
            return;
        };
        if (s.settings_ui.open) return s.settings_ui.inPanel(c, s, p);
        // A Raycast extension's command, while it runs (raycast_view.zig).
        if (s.ext) |e| if (e.open) return e.panel(c, s, p);

        if (s.clip_mode) {
            s.clipFillDraw(c, p);
            return;
        }

        // Rows before keys so Enter / ⌘1… open the right item — and so
        // openClipboard can run before any main chrome is drawn this frame.
        s.rebuild();
        s.keys(c);
        if (s.clip_mode) {
            s.clipFillDraw(c, p);
            return;
        }

        const submitted = s.header(c, p);
        s.rebuild();
        // Typing takes the page away: the rows are for the new words.
        if (s.previewing and std.hash.Wyhash.hash(0, s.query.text()) != s.preview_q) s.back();
        if (submitted) s.activate(c);
        if (s.clip_mode) {
            s.clipFillDraw(c, p);
            return;
        }
        const h = s.follow(c, s.height());
        {
            const body = ui.div(c).column().wFull().h(h - header_h).clip();
            defer body.end();
            if (s.previewing) {
                // Under the page, until it draws.
                ui.div(c).wFull().h(1).bg(p.hair).end();
                const wait = ui.div(c).wFull().h(webArea(h).h).center();
                defer wait.end();
                ui.text(c, "Searching Google…", .{ .size = 13, .color = p.sub.alpha(0.8) });
            } else if (s.res.n > 0) {
                ui.div(c).wFull().h(1).bg(p.hair).end();
                s.list(c, p);
            } else return;
            ui.spacer(c);
            s.footer(c, p);
        }
    }

    /// The panel's height, springing to `target`; a window follows it.
    /// Large jumps (enter/leave clipboard) snap so glass never grows empty.
    pub fn follow(s: *Nanolight, c: *ui.Context, target: f32) f32 {
        const capped = @min(target, max_height);
        const snap = s.last_h <= 0 or @abs(capped - s.last_h) > 24;
        const tr: motion.Transition = if (snap) .instant else .{ .spring = spring };
        const h = motion.number(c, "panel-h", capped, tr);
        if (snap) {
            if (s.host) |host| if (host.resize) |f| if (s.last_h != capped) f(host.ctx, capped);
            s.last_h = capped;
            return capped;
        }
        if (s.host) |host| if (host.resize) |f| {
            // Near-target snap: vibrancy setFrame spam strobes NSVisualEffectView.
            if (@abs(h - capped) < 0.75) {
                if (s.last_h != capped) {
                    s.last_h = capped;
                    f(host.ctx, capped);
                }
            } else if (@abs(h - s.last_h) > 1.5) {
                s.last_h = h;
                f(host.ctx, h);
            }
        };
        return h;
    }

    fn clipFillDraw(s: *Nanolight, c: *ui.Context, p: Palette) void {
        s.clip.fill(c.arena.allocator());
        s.clip.draw(c, p, s.follow(c, s.clip.height()));
    }

    /// Arrows, ^N/^P, Enter and Escape, before the field sees them.
    fn keys(s: *Nanolight, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (s.previewing) {
            if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.go(s.preview_url);
            if (c.shortcut(.{ .key = S.escape })) s.back();
            return;
        }
        // ⌘,: Settings, as on the Mac. The comma never reaches the field.
        if (c.shortcut(.{ .key = ',', .cmd = true })) return s.openSettings();
        // ⌘↩: a search in the browser rather than in the panel.
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.activateOut(c);
        // Enter / insertNewline activates before the header draws, so
        // clipboard can replace the whole shell this frame.
        var enter = c.input.key == .enter and !c.input.cmd;
        if (!enter and !c.input.shift) {
            for (c.input.ops) |op| {
                switch (op) {
                    .command => |cmd| {
                        if (cmd == .insert_newline) enter = true;
                    },
                    else => {},
                }
                if (enter) break;
            }
        }
        if (enter) {
            c.input.key = null;
            c.input.ops = &.{};
            s.activate(c);
            return;
        }
        // Tab takes the faint completion, as → does.
        const more = s.completion();
        if (more.len > 0 and c.shortcut(.{ .key = S.tab })) s.take(more);
        const n = s.res.n;
        if (c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true })) {
            if (n > 0) s.sel = (s.sel + 1) % n;
        }
        if (c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true })) {
            if (n > 0) s.sel = (s.sel + n - 1) % n;
        }
        // ⌘1…⌘9: the row of that number, at once.
        for (0..@min(n, 9)) |k| if (c.shortcut(.{ .key = @intCast('1' + k), .cmd = true })) {
            s.sel = k;
            s.activate(c);
        };
        if (c.shortcut(.{ .key = S.escape })) {
            if (s.query.text().len > 0) s.query.clear() else if (s.host) |h| h.hide(h.ctx);
        }
    }

    fn header(s: *Nanolight, c: *ui.Context, p: Palette) bool {
        const bar = ui.div(c).row().wFull().h(header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        ui.icon(c, "magnifyingglass", .{ .size = 19, .weight = .medium, .color = p.sub, .frame = 22 });
        s.rebuild();
        const r = ui.textField(c, &s.query, .{
            .suggestion = s.completion(),
            .bare = true,
            .size = 21,
            .width = .fill,
            .placeholder = "How can I help you?",
            .placeholder_color = p.sub.alpha(0.75),
            .color = p.text,
        });
        return r.submitted;
    }

    /// What the query is the start of, drawn faintly after the caret; →
    /// or Tab takes it. The top app's name when one is listed first ("saf"
    /// → "ari"), else Google's first completion that goes on from the
    /// words ("liquid gl" → "ass"), so it is one key away, not a walk
    /// down the rows — even when the default row is Ask Codex. Return
    /// never takes it: Return is the selected row.
    fn completion(s: *const Nanolight) []const u8 {
        const q = s.query.text();
        if (q.len == 0 or s.res.n == 0 or std.hash.Wyhash.hash(0, q) == s.revealed) return "";
        const r = s.res.rows[0];
        if (r.kind == .app) {
            const name = s.index.apps.items[r.app].name;
            if (name.len <= q.len or !std.ascii.startsWithIgnoreCase(name, q)) return "";
            return name[q.len..];
        }
        if (r.kind != .search_web and r.kind != .ai_ask) return "";
        for (0..s.web.n) |i| {
            const w = s.web.get(i);
            if (w.len > q.len and std.ascii.startsWithIgnoreCase(w, q)) return w[q.len..];
        }
        return "";
    }

    /// The completion `more` added to the query, the caret after it.
    fn take(s: *Nanolight, more: []const u8) void {
        var buf: [suggest.max_len * 2]u8 = undefined;
        const q = s.query.text();
        if (q.len + more.len > buf.len) return;
        @memcpy(buf[0..q.len], q);
        @memcpy(buf[q.len..][0..more.len], more);
        const len = q.len + more.len;
        s.query.set(buf[0..len]);
        s.query.want_selection = .{ len, len };
    }

    /// The rows for the query, if it changed since they were built: with
    /// what is known of Google's completions of it, asked for if not all.
    pub fn rebuild(s: *Nanolight) void {
        const q = s.query.text();
        const h = std.hash.Wyhash.hash(0, q);
        if (h == s.built) return;
        s.built = h;
        s.web.n = 0;
        if (@import("pm.zig").take(q)) |note| {
            const body = note.body;
            if (body.len <= s.pm_body.len) {
                @memcpy(s.pm_body[0..body.len], body);
                s.pm_body_len = body.len;
            } else s.pm_body_len = 0;
            s.res.buildPm(note.bot);
            s.sel = 0;
            return;
        }
        if (@import("pic.zig").take(q)) |needle| {
            if (needle.len == 0) {
                s.pics.clear();
                s.pics_asked = 0;
            } else if (s.host) |host| {
                // The last words' hits stay until these words' arrive.
                if (host.pic) |ask| if (std.hash.Wyhash.hash(0, needle) != s.pics_asked) {
                    s.pics_asked = std.hash.Wyhash.hash(0, needle);
                    ask(host.ctx, needle);
                };
                // No pic hook (tests): keep whatever hits were already set.
            }
            s.res.buildPic(s.pics.n);
            s.sel = 0;
            return;
        }
        if (@import("file.zig").take(q)) |needle| {
            if (needle.len == 0) {
                s.files.clear();
                s.files_asked = 0;
            } else if (s.host) |host| {
                if (host.file) |ask| if (std.hash.Wyhash.hash(0, needle) != s.files_asked) {
                    s.files_asked = std.hash.Wyhash.hash(0, needle);
                    ask(host.ctx, needle);
                };
                // No file hook (tests): keep whatever hits were already set.
            }
            s.res.buildFile(s.files.n);
            s.sel = 0;
            return;
        }
        if (@import("ai.zig").take(q)) |question| {
            const same = question.len == s.ai_question_len and std.mem.eql(u8, question, s.ai_question[0..s.ai_question_len]);
            if (!same) {
                if (question.len <= s.ai_question.len) {
                    @memcpy(s.ai_question[0..question.len], question);
                    s.ai_question_len = question.len;
                } else s.ai_question_len = 0;
                if (s.ai_status != .waiting) {
                    s.ai_status = .ready;
                    s.ai_text = "";
                }
            }
            const show_answer = (s.ai_status == .done or s.ai_status == .failed) and same;
            s.res.buildAi(show_answer);
            s.sel = 0;
            return;
        }
        // Plain query: keep the Codex question in sync so the default AI
        // row can run, and stay on the AI UI while that ask is in flight
        // or answered (same as the `ai ` / `ask ` prefix).
        {
            const question = std.mem.trim(u8, q, " \t");
            // Nothing typed: the field alone, never the last answer.
            if (question.len == 0) {
                s.ai_question_len = 0;
                if (s.ai_status != .waiting) {
                    s.ai_status = .ready;
                    s.ai_text = "";
                }
                s.fill();
                s.sel = 0;
                return;
            }
            const same = question.len == s.ai_question_len and std.mem.eql(u8, question, s.ai_question[0..s.ai_question_len]);
            if (!same) {
                if (question.len <= s.ai_question.len) {
                    @memcpy(s.ai_question[0..question.len], question);
                    s.ai_question_len = question.len;
                } else s.ai_question_len = 0;
                if (s.ai_status != .waiting) {
                    s.ai_status = .ready;
                    s.ai_text = "";
                }
            } else if (s.ai_status == .waiting or s.ai_status == .done or s.ai_status == .failed) {
                const show_answer = s.ai_status == .done or s.ai_status == .failed;
                s.res.buildAi(show_answer);
                s.sel = 0;
                return;
            }
        }
        // Default list is apps + Ask Codex only (no Google / Grok / X).
        s.fill();
        // The first row: an app, the answer, or Ask Codex for what was
        // typed; never a completion nobody picked (they come after it).
        s.sel = 0;
    }

    fn fill(s: *Nanolight) void {
        var sug: [results.max_apps]u32 = undefined;
        const ns = s.index.suggestions(&sug);
        var web: [suggest.max_rows][]const u8 = undefined;
        s.res.build(s.query.text(), s.index.names.items, s.index.aliases.items, s.index.launches.items, sug[0..ns], s.web.slices(&web));
    }

    /// Google's completions of `typed` (what `Host.suggest` asked): kept,
    /// and listed if it is still what is typed. The selection stays on the
    /// row it was on, wherever that row now is: Return a moment after
    /// typing does what the panel showed, not a completion that just came.
    pub fn answered(s: *Nanolight, typed: []const u8, said: *const suggest.List) void {
        if (s.clip_mode) return;
        s.cache.put(typed, said);
        if (!suggest.same(typed, s.query.text())) return;
        const was: ?Row = if (s.sel < s.res.n) s.res.rows[s.sel] else null;
        var was_text: [suggest.max_len]u8 = undefined;
        var was_len: usize = 0;
        if (was) |r| if (r.kind == .suggest) {
            const w = s.web.get(r.web);
            @memcpy(was_text[0..w.len], w);
            was_len = w.len;
        };
        s.web = said.*;
        s.fill();
        s.sel = 0;
        const r = was orelse return;
        for (s.res.slice(), 0..) |now, i| {
            const same_row = now.kind == r.kind and switch (r.kind) {
                .app => now.app == r.app,
                .pic => now.pic == r.pic,
                .file => now.file == r.file,
                .suggest => suggest.same(s.web.get(now.web), was_text[0..was_len]),
                else => true,
            };
            if (same_row) {
                s.sel = i;
                return;
            }
        }
    }

    fn list(s: *Nanolight, c: *ui.Context, p: Palette) void {
        const box = ui.div(c).column().wFull().p(list_pad);
        defer box.end();
        // Where the selected row is, so the highlight can slide to it.
        var y: f32 = 0;
        var sel_y: f32 = 0;
        var sel_h: f32 = row_h;
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i) != null) y += section_h;
            const rh: f32 = switch (r.kind) {
                .calc => calc_h,
                .ai_answer => ai_h,
                else => row_h,
            };
            if (i == s.sel) {
                sel_y = y;
                sel_h = rh;
            }
            y += rh;
        }
        // A new list: jump the highlight; within the same list, slide to sel.
        const fresh_list = s.sel_built != s.built;
        s.sel_built = s.built;
        const tr: motion.Transition = if (fresh_list) .instant else .{ .spring = slide };
        const hy = motion.number(c, "sel-y", sel_y, tr);
        const hh = motion.number(c, "sel-h", sel_h, tr);
        ui.div(c).absolute().offset(0, hy).w(width - list_pad * 2).h(hh).rounded(10).bg(p.sel).border(p.rim).end();
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i)) |name| {
                const head = ui.div(c).row().wFull().h(section_h).px(12).pb(6).itemsEnd();
                defer head.end();
                ui.text(c, name, .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
            }
            s.row(c, p, i, r);
        }
    }

    fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
        const rh: f32 = switch (r.kind) {
            .calc => calc_h,
            .ai_answer => ai_h,
            else => row_h,
        };
        const d = ui.div(c).row().wFull().h(rh).px(10).gap(12).itemsCenter().control();
        defer d.end();
        if (d.clicked()) {
            s.sel = i;
            s.activate(c);
        }
        if (r.kind == .calc) return s.calcCard(c, p);
        if (r.kind == .ai_answer) return s.aiCard(c, p);
        s.tile(c, p, r);
        const q = s.query.text();
        switch (r.kind) {
            .clipboard => ui.text(c, "Clipboard History", .{ .size = 13.5, .weight = .medium, .color = p.text }),
            .restart => ui.text(c, "Restart Nanolight", .{ .size = 13.5, .weight = .medium, .color = p.text }),
            .quit => ui.text(c, "Quit Nanolight", .{ .size = 13.5, .weight = .medium, .color = p.text }),
            .pm, .af => ui.text(c, @import("pm.zig").Bot.title(if (r.kind == .af) .af else .pm), .{ .size = 13.5, .weight = .medium, .color = p.text }),
            .calc, .ai_answer => unreachable,
            .app => {
                const a = s.index.apps.items[r.app];
                ui.richText(c, a.name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, a.folder, .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .pic => {
                const hit = s.pics.get(r.pic);
                ui.text(c, hit.name(), .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis });
                ui.text(c, hit.folder(), .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis });
            },
            .file => {
                const hit = s.files.get(r.file);
                ui.text(c, hit.name(), .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis });
                ui.text(c, hit.folder(), .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis });
            },
            .ai_ask => {
                if (s.ai_status == .waiting) {
                    ui.text(c, "Thinking…", .{ .size = 13.5, .weight = .medium, .color = p.text });
                } else if (s.ai_question_len == 0) {
                    ui.text(c, "Type a question", .{ .size = 13.5, .weight = .medium, .color = p.sub });
                } else {
                    ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis }, "Ask Codex “{s}”", .{s.ai_question[0..s.ai_question_len]});
                }
            },
            .settings => {
                ui.text(c, "Nanolight Settings", .{ .size = 13.5, .weight = .medium, .color = p.text });
                ui.text(c, "Shortcut, sync, updates", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .suggest => {
                const w = s.web.get(r.web);
                ui.richText(c, w, s.added(i, w, p), .{ .size = 13.5, .color = p.text.alpha(0.72), .truncate = .ellipsis });
            },
            .ask_grok, .search_x, .search_web => {
                const verb = switch (r.kind) {
                    .ask_grok => "Ask Grok",
                    .search_x => "Search X for",
                    else => "Search Google for",
                };
                ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis }, "{s} “{s}”", .{ verb, std.mem.trim(u8, q, " ") });
                ui.text(c, switch (r.kind) {
                    .ask_grok => "grok.com",
                    .search_x => "x.com · Latest",
                    else => "google.com",
                }, .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
        }
        ui.spacer(c);
        if (i == s.sel) {
            ui.text(c, if (r.kind == .app or r.kind == .settings or r.kind == .pic or r.kind == .file) "Open" else if (r.kind == .ai_answer) "Copy" else if (r.kind == .ai_ask) "Ask" else if (r.kind == .restart) "Restart" else if (r.kind == .quit) "Quit" else if (r.kind == .pm or r.kind == .af) "Send" else "Go", .{ .size = 12, .weight = .medium, .color = p.sub });
            ui.kbd(c, "↩");
        } else if (i < 9) ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.5), .tabular = true }, "{s}{d}", .{ results.mod, i + 1 });
    }

    fn calcCard(s: *Nanolight, c: *ui.Context, p: Palette) void {
        @import("calc_card.zig").draw(c, p, s.query.text(), s.res.answer, s.res.hex, c.time - s.copied_at < 1.4);
    }

    fn aiCard(s: *Nanolight, c: *ui.Context, p: Palette) void {
        const box = ui.div(c).column().wFull().gap(8).px(4);
        defer box.end();
        const label: []const u8 = if (s.ai_status == .failed) "Failed" else if (c.time - s.copied_at < 1.4) "Copied" else "Answer";
        if (c.time - s.copied_at < 1.4) c.animationFrame();
        ui.text(c, label, .{ .size = 11, .weight = .medium, .color = p.sub });
        ui.text(c, if (s.ai_text.len > 0) s.ai_text else "No answer", .{ .size = 14, .color = p.text, .truncate = .ellipsis });
    }

    /// Codex finished (or failed) for generation `gen`.
    pub fn aiDone(s: *Nanolight, gen: u32, ok: bool, text: []const u8) void {
        if (gen != s.ai_gen) return;
        const n = @min(text.len, s.ai_buf.len);
        if (n > 0) @memcpy(s.ai_buf[0..n], text[0..n]);
        s.ai_text = s.ai_buf[0..n];
        s.ai_status = if (ok) .done else .failed;
        s.built = 1;
    }

    /// The row's picture: the app's icon, or a symbol on a quiet tile.
    fn tile(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
        if (r.kind == .app) if (s.index.icon(r.app)) |png| {
            const box = ui.div(c).size(26, 26).center();
            defer box.end();
            _ = ui.image(c, .{ .key = s.index.apps.items[r.app].path, .bytes = png, .max_width = 26, .max_height = 26, .radius = 0, .scale = 1 });
            return;
        };
        const big = r.kind == .calc;
        const side: f32 = if (big) 34 else 26;
        const box = ui.div(c).size(side, side).rounded(if (big) 9 else 7).bg(p.tile).center();
        defer box.end();
        if (r.kind == .search_x) {
            ui.text(c, "𝕏", .{ .size = 15, .weight = .bold, .color = p.text });
            return;
        }
        ui.icon(c, switch (r.kind) {
            .clipboard => "clipboard",
            .restart => "arrow.clockwise",
            .quit => "power",
            .pm, .af => "paperplane",
            .calc => "plus.forwardslash.minus",
            .pic => "photo",
            .file => "doc",
            .ai_ask, .ai_answer => "sparkles",
            .ask_grok => "sparkles",
            .search_web => "globe",
            .suggest => "magnifyingglass",
            .settings => "gearshape",
            else => "app.dashed",
        }, .{ .size = if (big) 16 else 13, .weight = .medium, .color = p.text });
    }

    /// The matched letters, full strength and heavier.
    fn highlight(s: *Nanolight, i: usize, r: Row, p: Palette) []const ui.Span {
        const hits = r.match.matched();
        var n: usize = 0;
        var k: usize = 0;
        while (k < hits.len and n < s.spans[i].len) {
            var end = k + 1;
            while (end < hits.len and hits[end] == hits[end - 1] + 1) end += 1;
            s.spans[i][n] = .{ .start = hits[k], .end = @as(u32, hits[end - 1]) + 1, .color = p.text, .weight = .semibold };
            n += 1;
            k = end;
        }
        return s.spans[i][0..n];
    }

    /// A completion as a search box shows it: the words typed plain, what
    /// it adds stronger.
    fn added(s: *Nanolight, i: usize, w: []const u8, p: Palette) []const ui.Span {
        const q = std.mem.trim(u8, s.query.text(), " ");
        if (q.len == 0 or w.len <= q.len or !std.ascii.startsWithIgnoreCase(w, q)) return &.{};
        s.spans[i][0] = .{ .start = @intCast(q.len), .end = @intCast(w.len), .color = p.text, .weight = .semibold };
        return s.spans[i][0..1];
    }

    fn footer(s: *Nanolight, c: *ui.Context, p: Palette) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        appIcon(c, 16);
        // One quiet line: name + version/build, or an update note; always keep the apps count.
        if (s.note.len > 0) {
            ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8) }, "{s} · {d} apps", .{ s.note, s.index.apps.items.len });
        } else {
            ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8) }, "Nanolight {s} ({d}) · {d} apps", .{ build_options.version, build_options.build, s.index.apps.items.len });
        }
        ui.spacer(c);
        {
            ui.key(c, "settings-gear");
            const g = ui.div(c).size(26, 26).rounded(7).center().control().hover(p.sel);
            defer g.end();
            if (g.clicked()) s.openSettings();
            ui.icon(c, "gearshape", .{ .size = 13, .weight = .medium, .color = p.sub });
            ui.text(c, "Settings", .{ .size = 1, .color = p.sub.alpha(0) });
        }
        if (s.previewing) {
            ui.text(c, "Open in Browser", .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
            ui.kbd(c, results.mod ++ "↩");
            ui.div(c).w(1).h(14).bg(p.hair).end();
            ui.text(c, "Back", .{ .size = 12, .color = p.sub.alpha(0.8) });
            ui.kbd(c, "esc");
            return;
        }
        if (s.res.n == 0) return;
        ui.text(c, s.res.rows[@min(s.sel, s.res.n - 1)].kind.action(), .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
        ui.kbd(c, "↩");
        ui.div(c).w(1).h(14).bg(p.hair).end();
        ui.text(c, "Close", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }

    /// Return on the selected row.
    pub fn activate(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[@min(s.sel, s.res.n - 1)];
        switch (r.kind) {
            .clipboard => s.openClipboard(),
            .restart => {
                if (s.host) |h| if (h.restart) |f| f(h.ctx);
            },
            .quit => {
                if (s.host) |h| if (h.quit) |f| f(h.ctx);
            },
            .pm, .af => {
                if (s.pm_body_len == 0) return;
                const h = s.host orelse return;
                const f = h.pm orelse return;
                f(h.ctx, if (r.kind == .af) .af else .pm, s.pm_body[0..s.pm_body_len]);
                s.query.clear();
                h.hide(h.ctx);
            },
            .calc => {
                var buf: [64]u8 = undefined;
                const v = @import("calc.zig").eval(s.query.text()) orelse return;
                c.clipboard.write(c.clipboard.ctx, @import("calc.zig").format(&buf, v, false));
                s.copied_at = c.time;
                return;
            },
            .app => {
                s.index.opened(r.app, s.kv);
                s.go(s.index.apps.items[r.app].path);
            },
            .pic => s.go(s.pics.get(r.pic).slice()),
            .file => s.go(s.files.get(r.file).slice()),
            .ai_ask => {
                if (s.ai_status == .waiting or s.ai_question_len == 0) return;
                if (s.host) |host| {
                    const ask = host.ai orelse return;
                    s.ai_status = .waiting;
                    s.ai_text = "";
                    s.ai_gen +%= 1;
                    s.built = 1;
                    s.res.buildAi(false);
                    ask(host.ctx, s.ai_question[0..s.ai_question_len]);
                }
            },
            .ai_answer => {
                if (s.ai_text.len == 0) return;
                c.clipboard.write(c.clipboard.ctx, s.ai_text);
                s.copied_at = c.time;
                return;
            },
            .ask_grok, .search_x => s.go(results.url(&s.url_buf, r.kind, s.query.text())),
            .search_web => s.search(s.query.text(), !s.searches_out),
            .settings => s.openSettings(),
            .suggest => {
                // Its words fill the field, as a search box's would.
                s.query.set(s.web.get(r.web));
                s.search(s.query.text(), !s.searches_out);
            },
        }
    }

    /// Picemon's hits for `needle`, if those are still the words asked for.
    pub fn picsArrived(s: *Nanolight, needle: []const u8, hits: *const @import("pic.zig").List) void {
        if (std.hash.Wyhash.hash(0, needle) != s.pics_asked) return;
        s.pics = hits.*;
        s.built = 1;
    }

    /// FSearch's hits for `needle`, if those are still the words asked for.
    pub fn filesArrived(s: *Nanolight, needle: []const u8, hits: *const @import("file.zig").List) void {
        if (std.hash.Wyhash.hash(0, needle) != s.files_asked) return;
        s.files = hits.*;
        s.built = 1;
    }

    pub fn openClipboard(s: *Nanolight) void {
        s.back();
        s.clip_mode = true;
        s.clip.open();
        // Resize glass immediately so the next paint is not a tall empty shell.
        // n may still be stale until fill; follow snaps again after fill.
        if (s.host) |host| if (host.resize) |f| {
            const h = s.clip.height();
            s.last_h = h;
            f(host.ctx, h);
        } else {
            s.last_h = -1;
        };
    }

    /// ⌘↩ on the selected row: a search goes where Return doesn't send it.
    fn activateOut(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[@min(s.sel, s.res.n - 1)];
        switch (r.kind) {
            .search_web => s.search(s.query.text(), s.searches_out),
            .suggest => s.search(s.web.get(r.web), s.searches_out),
            else => s.activate(c),
        }
    }

    /// Google's page for `words`: in the panel when `in_panel` and the host
    /// can show it there, else in the browser.
    fn search(s: *Nanolight, words: []const u8, in_panel: bool) void {
        const h = s.host orelse return;
        const u = results.url(&s.preview_buf, .search_web, words);
        const show = (if (in_panel) h.preview else null) orelse return s.go(u);
        s.preview_url = u;
        s.previewing = true;
        s.preview_q = std.hash.Wyhash.hash(0, s.query.text());
        show(h.ctx, u);
    }

    pub fn openSettings(s: *Nanolight) void {
        s.back();
        s.settings_ui.show();
    }

    /// The rows again, the page gone.
    pub fn back(s: *Nanolight) void {
        if (!s.previewing) return;
        s.previewing = false;
        if (s.host) |h| if (h.preview) |f| f(h.ctx, null);
    }

    fn go(s: *Nanolight, target: []const u8) void {
        const h = s.host orelse return;
        h.open(h.ctx, target);
        h.hide(h.ctx);
    }
};
