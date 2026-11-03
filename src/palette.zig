//! The panel's colors, light and dark: text, rows, hairlines, tiles.
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct { text: ui.Color, sub: ui.Color, hair: ui.Color, sel: ui.Color, rim: ui.Color, tile: ui.Color, fill: ui.Color };

const pc = @import("builtin").os.tag != .macos;

pub fn palette(dark: bool) Palette {
    return if (dark) .{
        .text = .hex(0xeeeeee),
        .sub = .hex(0xb5b5b5),
        .hair = ui.Color.white.alpha(0.12),
        .sel = ui.Color.white.alpha(0.16),
        .rim = ui.Color.white.alpha(0.1),
        .tile = ui.Color.white.alpha(0.09),
        // Over the Mac's vibrancy; solid on a PC, whose window is clear.
        .fill = if (pc) ui.Color.hex(0x1b1b1c) else ui.Color.hex(0x1a1a1a).alpha(0.5),
    } else .{
        .text = .hex(0x292929),
        .sub = .hex(0x6f6f6f),
        .hair = ui.Color.black.alpha(0.09),
        .sel = ui.Color.black.alpha(0.08),
        .rim = ui.Color.black.alpha(0.05),
        .tile = ui.Color.black.alpha(0.05),
        .fill = if (pc) ui.Color.hex(0xf9f9fa) else ui.Color.white.alpha(0.45),
    };
}
