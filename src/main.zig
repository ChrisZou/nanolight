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
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const Nanolight = view.Nanolight;
const hotkey = @import("hotkey.zig");
const shortcut = @import("shortcut.zig");
const Onboard = @import("onboard.zig").Onboard;
const suggest = @import("suggest.zig");
const Preview = @import("preview.zig").Preview;
const single = @import("single.zig");
const ClickThrough = @import("clickthrough.zig").ClickThrough;
const account = @import("account.zig");
const Settings = @import("settings.zig").Settings;
const LocalSettings = @import("settings.zig").Local;
const clipboard = @import("clipboard.zig");
const paste = @import("clipboard_paste.zig");
const clip_panel = @import("clipboard_panel.zig");

const suggest_key = "nanolight.suggest";
/// The version an automatic update restarted into, for the new copy to say.
const updated_key = "nanolight.updated";
/// How long the panel must have been away before an update restarts it.
const auto_update_after_ms = 10 * 1000;
/// When this Mac last changed its key or suggestions (settings.zig's `at`).
const sync_at_key = "nanolight.sync.at";

/// The window around the panel: shown and hidden. It is never resized: it
/// is as tall as the panel can be, and clear below it; only the system
/// glass behind the panel follows its height. (A window resized on every
/// frame of the height's spring shook as it searched: AppKit's new frame
/// and Metal's next drawable don't land together.)
const Live = struct {
    app: *nanoui.App,
    s: *Nanolight,
    o: *Onboard,
    kv: nanoui.kv.Store,
    clipboard: *clipboard.Capture,
    choice: shortcut.Choice = .cmd_space,
    window: ?*nanoui.Window = null,
    /// The system's glass under the panel, which the window's views keep.
    glass: ?objc.Object = null,
    preview: Preview = .{},
    /// Clicks outside the panel go to what is under it (clickthrough.zig).
    through: ClickThrough = .{},
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

    fn host(l: *Live) view.Host {
        return .{ .ctx = l, .open = open, .hide = hide, .resize = resize, .suggest = ask, .preview = showPage, .pic = picSearch, .file = fileSearch, .ai = aiAsk };
    }

    fn open(ctx: *anyopaque, target: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "http://")) {
            _ = nanoui.shell.openUrl(target);
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
            _ = nanoui.shell.openPath(target);
            // Its count went up: the other Macs suggest it too.
            if (l.acct) |*a| a.changed();
        }
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
        return .{ .hotkey = @tagName(l.choice), .suggest = l.s.suggest_on, .at = at, .launches = list.items };
    }

    /// The account's settings, merged: the key, the suggestions, the counts.
    fn applySynced(ctx: *anyopaque, st: Settings) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        var at: [24]u8 = undefined;
        l.kv.set(sync_at_key, std.fmt.bufPrint(&at, "{d}", .{st.at}) catch "0") catch {};
        if (std.meta.stringToEnum(shortcut.Choice, st.hotkey)) |c| if (c != l.choice) {
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

    /// The menu's account row: what signing in does, or who is synced.
    fn accountItems(l: *Live) [2]nanoui.menu.MenuItem {
        const a = if (l.acct) |*x| x else return .{ .{ .label = "Sync Across Macs…", .disabled = true }, .separator };
        const who: []const u8 = if (a.email().len > 0) a.email() else "your Codegraff account";
        return switch (a.state) {
            .signed_out => .{ .{ .label = "Sign In with Codegraff to Sync Across Macs…", .click = .of(l, Live.accountClick) }, .{ .label = "Codegraff Terms & Privacy", .click = .of(l, Live.openTerms) } },
            .starting => .{ .{ .label = "Signing In…", .disabled = true }, .{ .label = "Codegraff Terms & Privacy", .click = .of(l, Live.openTerms) } },
            .waiting => .{ .{ .label = "Approve in Your Browser… (Click to Cancel)", .click = .of(l, Live.accountClick) }, .{ .label = "Codegraff Terms & Privacy", .click = .of(l, Live.openTerms) } },
            .signed_in => .{
                .{ .label = std.fmt.bufPrint(&l.account_label, "Synced as {s}", .{who}) catch "Synced", .disabled = true },
                .{ .label = "Sign Out of Codegraff", .click = .of(l, Live.accountClick) },
            },
        };
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


    fn picSearch(ctx: *anyopaque, query: []const u8, out: *@import("pic.zig").List) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        @import("pic.zig").search(l.app.gpa, l.app.io, l.home, query, out);
    }

    fn fileSearch(ctx: *anyopaque, query: []const u8, out: *@import("file.zig").List) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        @import("file.zig").search(l.app.gpa, l.app.io, l.home, query, out);
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
    fn pageKey(ctx: *anyopaque, key: @import("preview.zig").Key) void {
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

    fn toggleSuggest(l: *Live, item: *nanoui.menu.Item) void {
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

    /// The menu bar icon's menu, with the update waiting, if one is.
    fn menu(l: *Live) void {
        const t = l.tray orelse return;
        const ready = if (l.updater) |u| u.ready() else null;
        const label = if (ready) |v| std.fmt.bufPrint(&l.update_label, "Restart to Update to {s}", .{v}) catch "Restart to Update" else "Check for Updates";
        const acc = l.accountItems();
        t.setMenu("Nanolight", &.{
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
        l.autoUpdate();
    }

    /// A newer version is downloaded and checked: Nanolight restarts into it
    /// on its own once the panel has been away a while. (A menu bar app
    /// almost never quits, so installing at quit, as nanoui's updater
    /// otherwise does, would mean never.) Called as one is ready and each
    /// time the panel goes away.
    fn autoUpdate(l: *Live) void {
        const u = l.updater orelse return;
        if (u.ready() == null) return;
        nanoui.App.after(auto_update_after_ms, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(c.?));
                live.restartIfAway();
            }
        }.f);
    }

    fn restartIfAway(l: *Live) void {
        const u = l.updater orelse return;
        const v = u.ready() orelse return;
        // In use: the next time it goes away (`keyChanged`) asks again.
        if (l.window) |w| if (w.isVisible()) return;
        // The new copy starts quietly and says it was updated (main).
        l.kv.set(updated_key, v) catch {};
        if (u.restart()) l.app.quit() else l.kv.remove(updated_key);
    }

    /// The panel became, or stopped being, the key window (it hides as it
    /// stops): an update waiting may go in, and an "Updated" note is done.
    fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (w.isFocused()) return;
        l.through.stop();
        l.s.note = "";
        l.autoUpdate();
    }

    fn hide(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.window) |w| w.hide();
    }

    /// The glass to the panel's height, in the frame that draws it (a
    /// view's frame, not the window's: nothing is laid out again).
    fn resize(ctx: *anyopaque, h: f32) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.preview.fit(h);
        // The panel grew or shrank under a still pointer.
        l.through.update();
        const g = l.glass orelse return;
        objc.msg(void, g, "setFrame:", .{glassFrame(h)});
    }

    fn toggle(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const w = l.window orelse return;
        const showing = w.isVisible() and w.isFocused();
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
        // A fifth of the way down the main screen, centered.
        const screen = objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return;
        const f = objc.msg(objc.CGRect, screen, "frame", .{});
        const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
        const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        const ph = objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
        const top = ph - (f.origin.y + f.size.height);
        // The panel there; the window is the shadow's margin bigger.
        w.setPosition(f.origin.x + (f.size.width - view.width) / 2 - view.shadow_margin, top + f.size.height * 0.2 - view.shadow_margin);
        l.s.reveal();
        if (l.s.clip_mode) l.s.clip.query.focus();
        w.show();
        l.through.start();
        if (l.acct) |*a| a.maybePull();
        w.redraw();
    }

    fn hooks(l: *Live) @import("onboard.zig").Hooks {
        return .{ .ctx = l, .apply = apply, .fix = fix, .login = login, .done = done };
    }

    fn useKey(l: *Live, choice: shortcut.Choice) void {
        l.choice = choice;
        hotkey.register(hotkey.space, choice.carbon(), .{ .ctx = l, .func = toggle }) catch |e|
            std.log.warn("nanolight: {s} can't be registered ({s}); open it from the menu bar", .{ choice.label(), @errorName(e) });
    }

    fn apply(ctx: *anyopaque, choice: shortcut.Choice) void {
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

    /// Open at login: the system's login items (SMAppService, macOS 13 and
    /// later), which need the app to run from its bundle.
    fn login(_: *anyopaque, set: ?bool) bool {
        const cls = objc_getClass("SMAppService") orelse return false;
        const svc = objc.msg(objc.Object, cls, "mainAppService", .{});
        if (set) |on| _ = objc.msg(objc.BOOL, svc, if (on) "registerAndReturnError:" else "unregisterAndReturnError:", .{@as(?*anyopaque, null)});
        return objc.msg(objc.NSInteger, svc, "status", .{}) == 1; // enabled
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
    var codex_buf: [128]u8 = undefined;
    const codex = ai.findCodex(job.live.app.io, &codex_buf);
    var temp: ai.Temp = .{};
    ai.nextTemp(&temp);
    defer {
        std.Io.Dir.deleteFileAbsolute(job.live.app.io, temp.outPath()) catch {};
        std.Io.Dir.deleteFileAbsolute(job.live.app.io, temp.logPath()) catch {};
    }
    if (codex.len == 0) {
        const msg = "Codex not found";
        @memcpy(job.answer[0..msg.len], msg);
        job.alen = msg.len;
        job.ok = false;
        job.done.store(true, .release);
        return;
    }
    const text_ans = ai.run(job.live.app.gpa, job.live.app.io, codex, job.question[0..job.qlen], temp.outPath(), temp.logPath(), &job.answer) catch |e| {
        const msg: []const u8 = switch (e) {
            error.BadQuestion => "Empty question",
            error.TempFile => "Couldn't create temp file",
            error.SpawnFailed => "Couldn't run Codex",
            error.NoAnswer => "No answer",
            error.CodexFailed => "Codex failed",
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

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

/// Puts the system's vibrancy under the panel (NSVisualEffectView, as
/// launchers use), `height` tall, the shadow's margin in. Returns it, for
/// `Live.resize`. Not NSGlassEffectView: on macOS 27 it draws an opaque
/// 1-pixel black line just outside its sides, which read as black edges
/// round the panel.
fn backdrop(w: *nanoui.Window, radius: f64, height: f32) ?objc.Object {
    const surface = w.surface orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const b = objc.msg(objc.CGRect, surface.nsview, "bounds", .{});
    const v = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{b});
    // Popover: light or dark with the system, as the panel's colors are.
    objc.msg(void, v, "setMaterial:", .{@as(objc.NSInteger, 6)});
    objc.msg(void, v, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behind the window
    objc.msg(void, v, "setState:", .{@as(objc.NSInteger, 1)}); // always active
    // Rounded as the panel is.
    objc.msg(void, v, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, v, "layer", .{})) |layer| {
        objc.msg(void, layer, "setCornerRadius:", .{radius});
        objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    }
    surface.attachBackdrop(v);
    objc.release(v);
    // In a flipped host view, from the top; the window never resizes.
    objc.msg(void, v, "setAutoresizingMask:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, v, "setFrame:", .{glassFrame(height)});
    return v;
}

/// Where the glass goes: under the panel, the shadow's margin in.
fn glassFrame(h: f32) objc.CGRect {
    const m = view.shadow_margin;
    return .{ .origin = .{ .x = m, .y = m }, .size = .{ .width = view.width, .height = h } };
}

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Nanolight", .quit_on_last_window_closed = false });
    defer app.destroy();
    var index: Index = .init(init.gpa);
    defer index.deinit();
    index.scan(init.io, init.environ_map.get("HOME"));
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
    s.host = live.host();
    // Google's completions are on unless turned off from the menu bar.
    if (kv.get(init.gpa, suggest_key) catch null) |v| {
        defer init.gpa.free(v);
        s.suggest_on = !std.mem.eql(u8, v, "0");
    }
    s.reveal();
    // The rows first, so a snapshot is as tall as the panel.
    s.rebuild();
    live.window = try app.newWindow(.{
        .title = "Nanolight",
        .width = if (app.flags.hidden) view.width else view.width + 2 * view.shadow_margin,
        .height = if (app.flags.hidden) s.height() else view.max_height + 2 * view.shadow_margin,
        .resizable = false,
        .title_bar = .popover,
        .visible = false,
        .on_key = .{ .ctx = &live, .func = Live.keyChanged },
        .content = .{ .view = .init(&s, Nanolight.view) },
    });
    if (app.flags.hidden) return app.run();
    // The newest launch is the one that stays (single.zig).
    if (single.quitOthers() > 0) std.log.info("nanolight: asked an older copy to quit", .{});
    // A menu bar app: no Dock icon, no menu bar of its own.
    _ = objc.msg(objc.BOOL, app.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
    // The panel's own shadow, not the system's: a shadowed window in dark
    // mode gets a hard black outline round its pixels.
    s.margin = view.shadow_margin;
    objc.msg(void, live.window.?.nswindow, "setHasShadow:", .{objc.NO});
    live.glass = backdrop(live.window.?, 18, if (o.active) o.height() else s.height());
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
    live.tray = try app.newTray(.{ .symbol = "magnifyingglass", .tooltip = "Nanolight" });
    // A release build (macos/package.sh) checks its GitHub releases; one
    // run from zig-out can't replace itself, and leaves the item off.
    const updater = nanoui.Updater.start(init, .{
        .repo = "justrach/nanolight",
        .asset = "nanolight-macos-arm64.zip",
        .name = "Nanolight",
        .changed = .{ .ctx = &live, .func = Live.updated },
    }) catch null;
    defer if (updater) |u| u.deinit();
    if (updater) |u| if (u.phase.load(.acquire) != .off) {
        live.updater = u;
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
    if (kv.get(init.gpa, updated_key) catch null) |v| {
        defer init.gpa.free(v);
        kv.remove(updated_key);
        s.note = std.fmt.bufPrint(&note_buf, "Updated to {s}", .{v}) catch "Updated";
    } else Live.toggle(&live);
    try app.run();
}
