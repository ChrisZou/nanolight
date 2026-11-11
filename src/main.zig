//! Nanolight, after Peekalight: a launcher that opens over everything on
//! ⌘Space, or the key picked in its welcome (onboard.zig), or from its
//! menu bar icon; finds apps as you type (initials
//! too: "ss" is System Settings), answers math, and hands anything else to
//! Grok, X or Google, with Google's completions of it (suggest.zig) and its
//! results in the panel (preview.zig). Its panel is the system's vibrancy
//! (NSVisualEffectView, as launchers use), nanoui drawing on it.
//! It lives in the menu bar: no Dock icon, nothing drawn while idle.
//!
//! `zig build run`, or `zig build app` and open zig-out/Nanolight.app
//! (its icon, icon.png, is drawn by tools/icon.py).
//! The walkthrough film, rendered offscreen: `tools/film.sh` (film.zig).
const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const mac = builtin.os.tag == .macos;
const apps = @import("apps.zig");
const Index = apps.Index;
const view = @import("view.zig");
const Nanolight = view.Nanolight;
const hotkey = @import("hotkey.zig");
const shortcut = @import("shortcut.zig");
const Onboard = @import("onboard.zig").Onboard;
const suggest = @import("suggest.zig");
/// The panel's window, the page in it and clicks through it: the Mac's own,
/// or Windows' and Linux's (panel_pc.zig, pc_stubs.zig).
const panel = if (mac) @import("panel_mac.zig") else @import("panel_pc.zig");
const preview_mod = if (mac) @import("preview.zig") else @import("pc_stubs.zig");
const Preview = preview_mod.Preview;
const single = @import("single.zig");
const ClickThrough = if (mac) @import("clickthrough.zig").ClickThrough else @import("pc_stubs.zig").ClickThrough;
const Recorder = if (mac) @import("recorder.zig").Recorder else @import("pc_stubs.zig").Recorder;
const account = @import("account.zig");
const rc = @import("raycast_live.zig");
const Settings = @import("settings.zig").Settings;
const LocalSettings = @import("settings.zig").Local;
const clipboard = @import("clipboard.zig");
const paste = @import("clipboard_paste.zig");
const clip_panel = @import("clipboard_panel.zig");
const PicLookup = @import("lookup.zig").Lookup(@import("pic.zig").List, @import("pic.zig").search);
const FileLookup = @import("lookup.zig").Lookup(@import("file.zig").List, @import("file.zig").search);

const suggest_key = "nanolight.suggest";
/// "1": Return opens searches in the browser (issue #10).
const searches_out_key = "nanolight.searches_out";
/// "0": no menu bar icon (issue #8).
const menu_bar_key = "nanolight.menu_bar";

pub fn applyChoice(ctx: *anyopaque, choice: shortcut.Choice) void {
    Live.apply(ctx, choice);
}

pub fn recordKey(ctx: *anyopaque, on: bool) void {
    Live.record(ctx, on);
}

pub fn loginItem(ctx: *anyopaque, set: ?bool) bool {
    return Live.login(ctx, set);
}
/// The version 0.1.6 and before left when they restarted into an update
/// themselves (nanoui's updater does it now, `autoRestart`).
pub const updated_key = "nanolight.updated";
/// When this Mac last changed its key or suggestions (settings.zig's `at`).
const sync_at_key = "nanolight.sync.at";

/// The app around the panel: its window, shown and hidden (panel_mac.zig,
/// panel_pc.zig), its key, its menu, its updates and its account.
pub const Live = struct {
    app: *nanoui.App,
    s: *Nanolight,
    o: *Onboard,
    kv: nanoui.kv.Store,
    clipboard: *clipboard.Capture,
    choice: shortcut.Choice = .cmd_space,
    window: ?*nanoui.Window = null,
    preview: Preview = .{},
    /// Clicks outside the panel go to what is under it (clickthrough.zig).
    through: ClickThrough = .{},
    /// A key of one's own, being recorded in Settings (recorder.zig).
    recorder: Recorder = .{},
    /// The words Google is to be asked about once typing pauses, and how
    /// many pauses are still being waited out (only the last one asks).
    asking: [suggest.max_len]u8 = undefined,
    asking_len: usize = 0,
    waiting: u32 = 0,
    /// Updates from GitHub's releases (a signed build only), and the menu
    /// bar icon whose menu offers one once it's ready.
    updater: ?*nanoui.Updater = null,
    tray: ?*nanoui.Tray = null,
    update_label: [64]u8 = undefined,
    /// Signed in to Codegraff, settings synced between Macs (account.zig).
    /// Null in headless runs.
    acct: ?account.Account = null,
    account_label: [192]u8 = undefined,
    paste_target: paste.Target = .{},
    paste_waiting: bool = false,
    paste_attempts: u8 = 0,
    paste_count: objc.NSInteger = 0,
    clipboard_hotkey: bool = false,
    home: []const u8 = "",
    ai_job: ?*AiJob = null,
    /// Picemon and FSearch, searched off the main thread (lookup.zig).
    pic_lookup: ?PicLookup = null,
    file_lookup: ?FileLookup = null,

    /// Raycast extensions: the command running in the panel (raycast_live.zig).
    ext_ui: @import("raycast_view.zig").Ext = undefined,
    runner: @import("raycast.zig").Runner = undefined,
    /// Raycast script commands, run by Nanolight itself (script_run.zig).
    scripts: @import("script_run.zig").Runner = undefined,
    env: ?*const std.process.Environ.Map = null,
    /// The next `hide` is skipped: a command just took the panel.
    keep_open: bool = false,

    fn host(l: *Live) view.Host {
        const bind = @import("settings_bind.zig");
        bind.box.ctx = l;
        return .{ .ctx = l, .open = open, .hide = hide, .resize = resize, .suggest = ask, .preview = if (mac) showPage else null, .settings = &bind.box, .pic = picSearch, .file = fileSearch, .ai = aiAsk, .recenter = recenter, .restart = restartSelf, .quit = quitSelf, .pm = pmSend };
    }

    fn open(ctx: *anyopaque, target: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "http://")) {
            _ = nanoui.shell.openUrl(target);
        } else if (rc.isCommand(target)) {
            rc.start(l, target);
        } else if (single.isSelf(target)) {
            // Nanolight is already open: the panel comes back, empty,
            // rather than macOS starting a second copy.
            l.s.query.clear();
            nanoui.App.after(60, l, struct {
                fn f(c: ?*anyopaque) callconv(.c) void {
                    toggle(c.?);
                }
            }.f);
        } else {
            _ = apps.launch(l.app.io, target);
            // Its count went up: the other Macs suggest it too.
            if (l.acct) |*a| a.changed();
        }
    }

    fn restartSelf(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        single.relaunch(l.app.io);
        l.app.quit();
    }

    fn recenter(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.window) |w| panel.recenter(w);
    }

    fn quitSelf(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.app.quit();
    }

    /// Sends the note in the background (NSURLSession, a 10 s timeout):
    /// the panel hides at once, a banner says how it went.
    fn pmSend(ctx: *anyopaque, bot: @import("pm.zig").Bot, body: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const pm = @import("pm.zig");
        var arena: std.heap.ArenaAllocator = .init(l.app.gpa);
        defer arena.deinit();
        const post = pm.prepare(arena.allocator(), l.app.io, l.home, bot, body) orelse {
            std.log.warn("nanolight: {t} webhook not configured or note empty", .{bot});
            return pm.notify(l.app.gpa, l.app.io, bot, false);
        };
        // fetch copies the request: the arena can go when this returns.
        switch (bot) {
            inline else => |b| nanoui.http.fetch(l.app.gpa, .{
                .url = post.url,
                .method = "POST",
                .headers = &.{
                    .{ .name = "Authorization", .value = post.auth },
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = post.json,
                .timeout = pm.timeout_s,
            }, l, struct {
                fn f(live: *Live, r: nanoui.http.Response) void {
                    sent(live, b, r);
                }
            }.f),
        }
    }

    fn sent(l: *Live, bot: @import("pm.zig").Bot, r: nanoui.http.Response) void {
        const ok = r.status >= 200 and r.status < 300;
        if (!ok) std.log.warn("nanolight: {t} webhook failed ({d} {s})", .{ bot, r.status, r.err });
        @import("pm.zig").notify(l.app.gpa, l.app.io, bot, ok);
    }

    // ----- sync (account.zig) -----

    fn accountHooks(l: *Live) account.Hooks {
        return .{ .ctx = l, .snapshot = snapshot, .apply = applySynced, .changed = accountChanged };
    }

    fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator) Settings {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const ix = l.s.index;
        var list: std.ArrayList(@import("settings.zig").Launch) = .empty;
        for (ix.apps.items, ix.launches.items) |a, n| if (n > 0) list.append(arena, .{ .name = a.name, .count = n }) catch break;
        var at: i64 = 0;
        if (l.kv.get(arena, sync_at_key) catch null) |v| at = std.fmt.parseInt(i64, v, 10) catch 0;
        const name = arena.create([32]u8) catch return .{ .hotkey = "cmd_space", .suggest = l.s.suggest_on, .at = at, .launches = list.items };
        return .{ .hotkey = l.choice.name(name), .suggest = l.s.suggest_on, .at = at, .launches = list.items };
    }

    /// The account's settings, merged: the key, the suggestions, the counts.
    fn applySynced(ctx: *anyopaque, st: Settings) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        var at: [24]u8 = undefined;
        l.kv.set(sync_at_key, std.fmt.bufPrint(&at, "{d}", .{st.at}) catch "0") catch {};
        if (shortcut.Choice.parse(st.hotkey)) |c| if (!c.eql(l.choice)) {
            shortcut.save(l.kv, c);
            l.useKey(c);
        };
        if (st.suggest != l.s.suggest_on) {
            l.s.suggest_on = st.suggest;
            l.kv.set(suggest_key, if (st.suggest) "1" else "0") catch {};
        }
        const ix = l.s.index;
        for (st.launches) |la| if (ix.find(la.name)) |i| {
            ix.launches.items[i] = @max(ix.launches.items[i], la.count);
        };
        ix.save(l.kv);
        l.s.built = 1;
        l.menu();
        if (l.window) |w| w.redraw();
    }

    fn accountChanged(ctx: *anyopaque) void {
        menu(@ptrCast(@alignCast(ctx)));
    }

    /// This Mac chose its key or turned suggestions on or off, just now.
    fn touched(l: *Live) void {
        var at: [24]u8 = undefined;
        l.kv.set(sync_at_key, std.fmt.bufPrint(&at, "{d}", .{account.now()}) catch "0") catch {};
        if (l.acct) |*a| a.changed();
    }

    fn accountClick(l: *Live, _: *nanoui.menu.Item) void {
        const a = if (l.acct) |*x| x else return;
        switch (a.state) {
            .signed_out => a.signIn(),
            .starting => {},
            .waiting, .signed_in => a.signOut(),
        }
    }

    fn openTerms(_: *Live, _: *nanoui.menu.Item) void {
        _ = nanoui.shell.openUrl(account.terms_url);
    }

    fn accountItems(l: *Live) [2]nanoui.menu.MenuItem {
        return @import("account_menu.zig").items(if (l.acct) |*x| x else null, &l.account_label, .of(l, Live.accountClick), .of(l, Live.openTerms));
    }

    /// Google is asked once typing pauses (`suggest.pause_ms`).
    fn ask(ctx: *anyopaque, query: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const q = std.mem.trim(u8, query, " ");
        if (q.len > suggest.max_len) return;
        @memcpy(l.asking[0..q.len], q);
        l.asking_len = q.len;
        l.waiting += 1;
        nanoui.App.after(suggest.pause_ms, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(c.?));
                live.waiting -= 1;
                if (live.waiting == 0) live.send();
            }
        }.f);
    }

    fn send(l: *Live) void {
        const q = l.asking[0..l.asking_len];
        // Typed on, or turned off, while it waited.
        if (l.s.clip_mode or !l.s.suggest_on or !suggest.same(q, l.s.query.text())) return;
        const a = l.app.gpa.create(Ask) catch return;
        a.* = .{ .live = l, .len = q.len };
        @memcpy(a.text[0..q.len], q);
        var buf: [512]u8 = undefined;
        nanoui.http.fetch(l.app.gpa, .{
            .url = suggest.url(&buf, q),
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = 4,
        }, a, Ask.done);
    }

    fn picSearch(ctx: *anyopaque, query: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.pic_lookup) |*k| k.request(query);
    }

    fn fileSearch(ctx: *anyopaque, query: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.file_lookup) |*k| k.request(query);
    }

    fn picsFound(ctx: *anyopaque, needle: []const u8, hits: *const @import("pic.zig").List) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.picsArrived(needle, hits);
        if (l.window) |w| w.redraw();
    }

    fn filesFound(ctx: *anyopaque, needle: []const u8, hits: *const @import("file.zig").List) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.filesArrived(needle, hits);
        if (l.window) |w| w.redraw();
    }

    fn aiAsk(ctx: *anyopaque, question: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.ai_job != null) return;
        const job = l.app.gpa.create(AiJob) catch {
            l.s.aiDone(l.s.ai_gen, false, "Couldn't start Codex");
            return;
        };
        job.* = .{ .live = l, .gen = l.s.ai_gen, .qlen = @min(question.len, job.question.len) };
        @memcpy(job.question[0..job.qlen], question[0..job.qlen]);
        l.ai_job = job;
        const thread = std.Thread.spawn(.{}, aiWorker, .{job}) catch {
            l.ai_job = null;
            l.app.gpa.destroy(job);
            l.s.aiDone(l.s.ai_gen, false, "Couldn't start Codex");
            if (l.window) |w| w.redraw();
            return;
        };
        thread.detach();
        nanoui.App.after(200, l, aiPoll);
    }

    /// A search's page in the panel, or (null) not.
    fn showPage(ctx: *anyopaque, url: ?[]const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const w = l.window orelse return;
        if (url) |u| l.preview.show(w, u, l.s.last_h) else l.preview.hide();
    }

    /// Escape or ⌘↩ while the page has the keys.
    fn pageKey(ctx: *anyopaque, key: preview_mod.Key) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        switch (key) {
            .escape => l.s.back(),
            .open_out => {
                var buf: [2048]u8 = undefined;
                open(l, l.preview.current(&buf) orelse l.s.preview_url);
                hide(l);
            },
        }
        if (l.window) |w| w.redraw();
    }

    pub fn toggleSuggest(l: *Live, item: *nanoui.menu.Item) void {
        l.s.suggest_on = item.checked;
        l.kv.set(suggest_key, if (item.checked) "1" else "0") catch {};
        l.touched();
        // The rows again, with or without them.
        l.s.built = 1;
        if (l.window) |w| w.redraw();
    }

    fn toggleClipboard(l: *Live, item: *nanoui.menu.Item) void {
        l.enableClipboard(item.checked);
    }

    fn enableClipboard(l: *Live, on: bool) void {
        if (on) l.clipboard.start() catch |e| {
            std.log.warn("nanolight: couldn't start clipboard history ({s})", .{@errorName(e)});
            l.menu();
            l.s.clip.message = "Couldn't enable clipboard history";
            return;
        } else l.clipboard.stop();
        (LocalSettings{ .clipboard_history = on }).save(l.kv) catch |e| {
            std.log.warn("nanolight: couldn't save clipboard setting ({s})", .{@errorName(e)});
            // Never keep capturing if consent couldn't be persisted.
            if (on) l.clipboard.stop();
        };
        l.s.clip.enabled = l.clipboard.enabled();
        l.s.clip.message = if (l.s.clip.enabled == on) "" else "Couldn't save clipboard setting";
        l.clipboardChanged();
        l.menu();
    }

    fn clipboardChanged(l: *Live) void {
        if (l.s.clip_mode) if (l.window) |w| w.redraw();
    }

    fn clipboardAction(ctx: *anyopaque, action: clip_panel.Action, id: u64) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        switch (action) {
            .enable => l.enableClipboard(true),
            .save => {
                l.clipboard.flush() catch {
                    l.s.clip.message = "Couldn't save clipboard history";
                };
                l.clipboardChanged();
            },
            .accessibility => {
                _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
            },
            .close => hide(l),
            .paste => l.pasteItem(id),
        }
    }

    fn pasteItem(l: *Live, id: u64) void {
        if (!l.clipboard.enabled() or l.paste_waiting) return;
        // Always put the original bytes back first. Auto-paste needs
        // Accessibility; without it the item is still on the pasteboard.
        l.clipboard.restore(id) catch {
            l.s.clip.message = "Couldn't restore clipboard item";
            l.clipboardChanged();
            return;
        };
        if (!paste.trusted(true)) {
            l.s.clip.message = "Copied — allow Accessibility to paste";
            l.s.clip.needs_accessibility = true;
            l.clipboardChanged();
            return;
        }
        l.s.clip.needs_accessibility = false;
        if (!l.paste_target.valid()) {
            l.s.clip.message = "Copied — press ⌘V in your app";
            l.clipboardChanged();
            return;
        }
        l.paste_count = l.clipboard.change_count;
        l.paste_waiting = true;
        l.paste_attempts = 0;
        hide(l);
        if (!l.paste_target.activate()) {
            l.paste_waiting = false;
            // Already restored; stay in the destination app if activate failed partway.
            return;
        }
        nanoui.App.after(40, l, pasteLater);
    }

    fn pasteLater(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Live = @ptrCast(@alignCast(ctx.?));
        if (!l.paste_waiting) return;
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        // Never paste a newer copy, or paste after the user reopened us.
        if (objc.msg(objc.NSInteger, pb, "changeCount", .{}) != l.paste_count or (if (l.window) |w| w.isVisible() else false)) {
            l.paste_waiting = false;
            return;
        }
        if (l.paste_target.ready()) {
            l.paste_waiting = false;
            // Restore already succeeded; a failed keystroke still leaves ⌘V usable.
            l.paste_target.send() catch {};
            return;
        }
        l.paste_attempts += 1;
        if (l.paste_attempts >= 30 or !l.paste_target.valid()) {
            l.paste_waiting = false;
            return;
        }
        nanoui.App.after(40, l, pasteLater);
    }

    fn clearClipboard(l: *Live, _: *nanoui.menu.Item) void {
        l.clipboard.store.clear();
        l.clipboard.flush() catch {
            l.s.clip.message = "Couldn't save clipboard history";
        };
        l.clipboardChanged();
    }

    fn menuClipboard(l: *Live, _: *nanoui.menu.Item) void {
        nanoui.App.after(50, l, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                showClipboard(ctx.?);
            }
        }.f);
    }

    pub fn setSearchesOut(l: *Live, on: bool) void {
        l.s.searches_out = on;
        l.kv.set(searches_out_key, if (on) "1" else "0") catch {};
    }

    /// Whether the menu bar icon shows; `set` shows or hides it. Hidden,
    /// Nanolight is its key alone: Settings stays in the panel (⌘,), and
    /// opening the app again shows the panel. The status item stays, only
    /// unseen (nanoui's App keeps its trays until it quits).
    pub fn menuBar(l: *Live, set: ?bool) bool {
        if (comptime !mac) return false;
        const t = l.tray orelse return false;
        if (set) |on| {
            l.kv.set(menu_bar_key, if (on) "1" else "0") catch {};
            objc.msg(void, t.item, "setVisible:", .{if (on) objc.YES else objc.NO});
        }
        return objc.msg(objc.BOOL, t.item, "isVisible", .{});
    }

    /// The menu bar icon's menu, with the update waiting, if one is.
    fn menu(l: *Live) void {
        // No tray icon in nanoui on Windows and Linux yet: Settings has it all.
        if (comptime !mac) return;
        const t = l.tray orelse return;
        const ready = if (l.updater) |u| u.ready() else null;
        const label = if (ready) |v| std.fmt.bufPrint(&l.update_label, "Restart to Update to {s}", .{v}) catch "Restart to Update" else "Check for Updates";
        const acc = l.accountItems();
        t.setMenu("Nanolight", &.{
            .{ .label = "Settings…", .accelerator = "Cmd+,", .click = .of(l, Live.menuSettings) },
            .{ .label = "Open Nanolight", .click = .of(l, Live.menuShow) },
            .{ .label = "Welcome…", .click = .of(l, Live.welcome) },
            .{ .label = "Google Suggestions", .kind = .checkbox, .checked = l.s.suggest_on, .click = .of(l, Live.toggleSuggest) },
            .{ .label = "Clipboard History", .kind = .checkbox, .checked = l.clipboard.enabled(), .click = .of(l, Live.toggleClipboard) },
            .{ .label = if (l.clipboard_hotkey) "Open Clipboard History (⌘⇧V)" else "Open Clipboard History (clip)", .click = .of(l, Live.menuClipboard) },
            .{ .label = "Clear Clipboard History", .disabled = !l.clipboard.enabled(), .click = .of(l, Live.clearClipboard) },
            .separator,
            acc[0],
            acc[1],
            .separator,
            .{ .label = label, .disabled = l.updater == null, .click = .of(l, Live.updateNow) },
            .{ .label = "Quit Nanolight", .role = .quit },
        }) catch {};
    }

    fn updateNow(l: *Live, _: *nanoui.menu.Item) void {
        const u = l.updater orelse return;
        if (u.ready() != null) {
            if (u.restart()) l.app.quit();
        } else u.checkNow();
    }

    fn updated(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        menu(l);
        if (!mac) @import("update_pc.zig").away(l);
    }

    /// The panel became, or stopped being, the key window (it hides as it
    /// stops): an "Updated" note is done. (An update waiting goes in once
    /// the panel has been away a while: nanoui's `autoRestart`.)
    fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (w.isFocused()) return;
        if (l.recorder.active()) record(l, false);
        l.through.stop();
        l.s.note = "";
        // The Mac's popover hides itself; elsewhere the panel goes as
        // another window takes the keys.
        if (!mac and w.isVisible()) w.hide();
        if (!mac) @import("update_pc.zig").away(l);
    }

    fn hide(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.keep_open) {
            l.keep_open = false;
            return;
        }
        if (l.window) |w| w.hide();
    }

    /// The window (or the Mac's glass under the panel) to its height.
    fn resize(ctx: *anyopaque, h: f32) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.preview.fit(h);
        // The panel grew or shrank under a still pointer.
        l.through.update();
        if (l.window) |w| panel.resize(w, h);
    }

    fn toggle(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const w = l.window orelse return;
        const showing = w.isVisible() and panel.focused(w);
        l.o.pressed(showing);
        if (showing and !l.s.clip_mode) return w.hide();
        l.s.clip_mode = false;
        l.show();
    }

    fn showClipboard(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const w = l.window orelse return;
        if (w.isVisible() and w.isFocused() and l.s.clip_mode) return w.hide();
        l.s.openClipboard();
        l.show();
    }

    fn show(l: *Live) void {
        const w = l.window orelse return;
        l.paste_waiting = false;
        l.paste_target.remember();
        // Freed a key in System Settings, quit a launcher: look again.
        if (l.o.active) l.o.refresh();
        panel.place(w);
        rc.refresh(l);
        l.s.reveal();
        if (l.s.clip_mode) {
            l.s.clip.query.focus();
            // Populate rows before measuring height so glass matches clipboard UI.
            var arena: std.heap.ArenaAllocator = .init(l.app.gpa);
            defer arena.deinit();
            l.s.clip.fill(arena.allocator());
        }
        // Glass matches the panel before the window appears (avoids a mismatched
        // vibrancy flash under the first paint / enter motion).
        const h = if (l.s.clip_mode) l.s.clip.height() else if (l.o.active) l.o.height() else l.s.height();
        Live.resize(l, h);
        l.s.last_h = h;
        w.show();
        panel.shown(w);
        l.through.start();
        if (l.acct) |*a| a.maybePull();
        w.redraw();
    }

    fn hooks(l: *Live) @import("onboard.zig").Hooks {
        return .{ .ctx = l, .apply = apply, .fix = fix, .login = login, .done = done };
    }

    fn useKey(l: *Live, choice: shortcut.Choice) void {
        l.choice = choice;
        hotkey.register(choice, .{ .ctx = l, .func = toggle }) catch |e|
            std.log.warn("nanolight: {f} can't be registered ({s}); open it from the menu bar", .{ choice, @errorName(e) });
    }

    /// Settings records a key: until it has one, keys pressed go to it,
    /// and the current key is let go (pressed, it is recorded too).
    pub fn record(ctx: *anyopaque, on: bool) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (on) {
            hotkey.unregister();
            l.recorder.start(.{ .ctx = l, .func = recorded });
            return;
        }
        l.recorder.stop();
        l.s.settings_ui.recording = false;
        l.useKey(l.choice);
    }

    fn recorded(ctx: *anyopaque, r: shortcut.Recorded) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.settings_ui.took(l.s, r);
        if (l.window) |w| w.redraw();
    }

    pub fn apply(ctx: *anyopaque, choice: shortcut.Choice) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        shortcut.save(l.kv, choice);
        l.useKey(choice);
        l.touched();
    }

    fn fix(ctx: *anyopaque, clash: shortcut.Clash) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (clash.system != null) {
            _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.Keyboard-Settings.extension");
        } else for (clash.launchers) |name| shortcut.quit(name);
        // A launcher takes a moment to quit: then the panel looks again.
        nanoui.App.after(900, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(c.?));
                live.o.refresh();
                if (live.window) |w| w.redraw();
            }
        }.f);
    }

    /// Open at login (login.zig).
    pub fn login(_: *anyopaque, set: ?bool) bool {
        return @import("login.zig").login(set);
    }

    /// `nanolight --toggle`, or a newer copy starting (single.zig).
    fn command(ctx: *anyopaque, cmd: single.Command) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        switch (cmd) {
            .toggle => toggle(l),
            .quit => l.app.quit(),
        }
    }

    fn done(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        shortcut.setOnboarded(l.kv);
    }

    fn welcome(l: *Live, item: *nanoui.menu.Item) void {
        l.o.start(l.choice);
        if (l.window) |w| if (w.isVisible()) w.hide();
        l.menuShow(item);
    }

    /// The menu opens the panel straight into Settings.
    fn menuSettings(l: *Live, _: *nanoui.menu.Item) void {
        nanoui.App.after(50, l, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(ctx.?));
                const w = live.window orelse return;
                if (!(w.isVisible() and w.isFocused())) toggle(live);
                live.o.active = false;
                live.s.openSettings();
                w.redraw();
            }
        }.f);
    }

    fn menuShow(l: *Live, _: *nanoui.menu.Item) void {
        // The menu closes first; then the panel takes the keys.
        nanoui.App.after(50, l, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                toggle(ctx.?);
            }
        }.f);
    }
};

/// A Codex one-shot in flight.
const AiJob = struct {
    live: *Live,
    gen: u32,
    question: [@import("ai.zig").max_question]u8 = undefined,
    qlen: usize = 0,
    answer: [@import("ai.zig").max_answer]u8 = undefined,
    alen: usize = 0,
    ok: bool = false,
    done: std.atomic.Value(bool) = .init(false),
};

fn aiWorker(job: *AiJob) void {
    const ai = @import("ai.zig");
    var codex_buf: [512]u8 = undefined;
    const codex = ai.findCodex(job.live.app.io, &codex_buf, job.live.home);
    var temp: ai.Temp = .{};
    ai.nextTemp(&temp);
    defer {
        std.Io.Dir.deleteFileAbsolute(job.live.app.io, temp.outPath()) catch {};
    }
    if (codex.len == 0) {
        const msg = "Codex not found";
        @memcpy(job.answer[0..msg.len], msg);
        job.alen = msg.len;
        job.ok = false;
        job.done.store(true, .release);
        return;
    }
    const text_ans = ai.run(job.live.app.io, codex, job.question[0..job.qlen], temp.outPath(), &job.answer) catch |e| {
        const msg: []const u8 = switch (e) {
            error.BadQuestion => "Empty question",
            error.TempFile => "Couldn't create temp file",
            error.SpawnFailed => "Couldn't run Codex",
            error.NoAnswer => "No answer",
            error.CodexFailed => "Codex failed",
            error.TimedOut => "Codex took too long",
        };
        @memcpy(job.answer[0..msg.len], msg);
        job.alen = msg.len;
        job.ok = false;
        job.done.store(true, .release);
        return;
    };
    job.alen = text_ans.len;
    job.ok = true;
    job.done.store(true, .release);
}

fn aiPoll(ctx: ?*anyopaque) callconv(.c) void {
    const l: *Live = @ptrCast(@alignCast(ctx.?));
    const job = l.ai_job orelse return;
    if (!job.done.load(.acquire)) {
        nanoui.App.after(200, l, aiPoll);
        if (l.window) |w| w.redraw();
        return;
    }
    l.s.aiDone(job.gen, job.ok, job.answer[0..job.alen]);
    l.ai_job = null;
    l.app.gpa.destroy(job);
    if (l.window) |w| w.redraw();
}

/// A question to Google on its way: the words it is about.
const Ask = struct {
    live: *Live,
    text: [suggest.max_len]u8 = undefined,
    len: usize,

    fn done(a: *Ask, r: nanoui.http.Response) void {
        const l = a.live;
        defer l.app.gpa.destroy(a);
        if (r.status != 200) return;
        var arena: std.heap.ArenaAllocator = .init(l.app.gpa);
        defer arena.deinit();
        var list: suggest.List = .{};
        if (!suggest.decode(arena.allocator(), r.body, a.text[0..a.len], &list)) return;
        l.s.answered(a.text[0..a.len], &list);
        if (l.window) |w| w.redraw();
    }
};

/// This platform's archive in each release (macos/package.sh, pc/package.sh).
const asset = switch (builtin.os.tag) {
    .macos => "nanolight-macos-arm64.zip",
    .windows => "nanolight-windows-x86_64.zip",
    else => "nanolight-linux-" ++ @tagName(builtin.cpu.arch) ++ ".tar.gz",
};
const version = @import("build_options").version;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    // `nanolight --toggle`: the running copy's panel (Wayland's shortcut);
    // `--version`: what the updater asks a downloaded copy.
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    for (try init.minimal.args.toSlice(arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var out: [64]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &out);
            try w.interface.print("nanolight {s}\n", .{version});
            return w.interface.flush();
        }
        if (std.mem.eql(u8, arg, "--toggle")) {
            if (single.send(.toggle)) return;
            break;
        }
    }
    // Linux: GTK 3, where a window can be put somewhere (GTK 4 lets only
    // the compositor place one), unless the user asked for another.
    if (builtin.os.tag == .linux and std.c.getenv("NANOUI_GTK") == null) _ = setenv("NANOUI_GTK", "3", 0);
    const app = try nanoui.App.create(init, .{ .name = "Nanolight", .quit_on_last_window_closed = false });
    defer app.destroy();
    var index: Index = .init(init.gpa);
    defer index.deinit();
    apps.scanSystem(&index, init.io, init.environ_map);
    const kv = nanoui.kv.standard();
    index.load(kv);
    var o: Onboard = .{};
    var s: Nanolight = .{ .index = &index, .kv = kv, .onboard = &o };
    defer s.query.deinit();
    var clips: clipboard.Capture = .{ .store = .init(init.gpa), .io = init.io, .home = init.environ_map.get("HOME") };
    defer clips.deinit();
    var live: Live = .{ .app = app, .s = &s, .o = &o, .kv = kv, .clipboard = &clips, .choice = shortcut.load(kv, init.gpa), .home = init.environ_map.get("HOME") orelse "" };
    defer live.paste_target.deinit();
    defer s.clip.query.deinit();
    s.clip.store = &clips.store;
    s.clip.hooks = .{ .ctx = &live, .func = Live.clipboardAction };
    clips.changed = .{ .ctx = &live, .func = struct {
        fn f(ctx: *anyopaque) void {
            const l: *Live = @ptrCast(@alignCast(ctx));
            l.clipboardChanged();
        }
    }.f };
    live.pic_lookup = .{ .gpa = init.gpa, .io = init.io, .home = live.home, .done = .{ .ctx = &live, .func = Live.picsFound } };
    live.file_lookup = .{ .gpa = init.gpa, .io = init.io, .home = live.home, .done = .{ .ctx = &live, .func = Live.filesFound } };
    s.host = live.host();
    // Google's completions are on unless turned off in Settings.
    if (kv.get(init.gpa, suggest_key) catch null) |v| {
        defer init.gpa.free(v);
        s.suggest_on = !std.mem.eql(u8, v, "0");
    }
    if (kv.get(init.gpa, searches_out_key) catch null) |v| {
        defer init.gpa.free(v);
        s.searches_out = std.mem.eql(u8, v, "1");
    }
    s.reveal();
    // The rows first, so a snapshot is as tall as the panel.
    s.rebuild();
    var options: nanoui.WindowOptions = .{
        .title = "Nanolight",
        .resizable = false,
        .visible = false,
        .on_key = .{ .ctx = &live, .func = Live.keyChanged },
        .content = .{ .view = .init(&s, Nanolight.view) },
    };
    panel.adjust(&options, app.flags.hidden, s.height());
    live.window = try app.newWindow(options);
    if (app.flags.hidden) return app.run();
    // Raycast extensions' commands among the apps (never in headless runs:
    // they're this machine's).
    rc.init(&live, init.environ_map);
    defer rc.deinit(&live);
    rc.rescan(&live);
    // The newest launch is the one that stays; it hears `--toggle` (single.zig).
    if (single.claim(.{ .ctx = &live, .func = Live.command }) > 0) std.log.info("nanolight: asked an older copy to quit", .{});
    panel.setup(app, live.window.?, &s, if (o.active) o.height() else s.height());
    live.useKey(live.choice);
    live.clipboard_hotkey = registered: {
        hotkey.registerClipboard(.{ .ctx = &live, .func = Live.showClipboard }) catch |e| {
            std.log.warn("nanolight: ⌘⇧V unavailable ({s}); use clip in the launcher", .{@errorName(e)});
            break :registered false;
        };
        break :registered true;
    };
    live.through = .{ .window = live.window, .height = &s.last_h };
    live.preview.watch(.{ .ctx = &live, .func = Live.pageKey });
    o.hooks = live.hooks();
    // The first run: the welcome, in the panel.
    if (!shortcut.onboarded(kv)) o.start(live.choice);
    if (mac) live.tray = try app.newTray(.{ .symbol = "magnifyingglass", .tooltip = "Nanolight" });
    // The menu bar icon, unless Settings took it away.
    if (kv.get(init.gpa, menu_bar_key) catch null) |v| {
        defer init.gpa.free(v);
        if (std.mem.eql(u8, v, "0")) _ = live.menuBar(false);
    }
    // A release build checks its GitHub releases; one run from zig-out
    // can't replace itself, and leaves the item off.
    const updater = nanoui.Updater.start(init, .{
        // This fork's releases: upstream's would replace it without its features.
        .repo = "ChrisZou/nanolight",
        .asset = asset,
        .version = version,
        .name = "Nanolight",
        .changed = .{ .ctx = &live, .func = Live.updated },
    }) catch null;
    defer if (updater) |u| u.deinit();
    if (updater) |u| if (u.phase.load(.acquire) != .off) {
        live.updater = u;
        // A launcher almost never quits, so installing at quit would mean
        // never: it restarts into an update once the panel has been away
        // 10 s, unseen, and comes back as it was (update_pc.zig off the Mac).
        u.autoRestart(app, .{ .idle_ms = 10 * 1000 });
    };
    // Signed in before: synced now. Signing in is from the menu.
    live.acct = .{ .gpa = init.gpa, .kv = kv, .hooks = live.accountHooks() };
    live.acct.?.load();
    if (LocalSettings.load(kv, init.gpa).clipboard_history) clips.start() catch |e|
        std.log.warn("nanolight: couldn't start clipboard history ({s})", .{@errorName(e)});
    s.clip.enabled = clips.enabled();
    live.menu();
    // Restarted by an automatic update: quietly, the panel saying so the
    // next time it opens. Otherwise launching shows the panel.
    var note_buf: [64]u8 = undefined;
    const old = kv.get(init.gpa, updated_key) catch null;
    defer if (old) |v| init.gpa.free(v);
    if (old != null) kv.remove(updated_key);
    const restarted = if (live.updater) |u| u.updatedFrom() != null else false;
    if (restarted or old != null) {
        const now = if (live.updater) |u| u.current else old.?;
        s.note = std.fmt.bufPrint(&note_buf, "Updated to {s} ({d})", .{ now, build_options.build }) catch "Updated";
    } else Live.toggle(&live);
    try app.run();
}
