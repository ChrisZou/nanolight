//! Nanolight: a ⌘Space launcher for the Mac, drawn by nanoui.
//!
//!   zig build run            build and open it
//!   zig build app            zig-out/Nanolight.app, for /Applications
//!   zig build test           its search, math, suggestions and panel
//!   zig build film           the walkthrough's renderer (tools/film.sh)
//!   zig build promo          the promo's renderer (tools/promo.sh)
//!
//! Release packages (the signed app, its disk image and the update feed)
//! are macos/package.sh's.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .macos) {
        std.log.err("Nanolight is a Mac app: build it on macOS, or with -Dtarget=aarch64-macos", .{});
        return;
    }
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const version = b.option([]const u8, "version", "Nanolight's version, as the app shows it (release builds)") orelse "0.1.0";

    const exe = b.addExecutable(.{ .name = "nanolight", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    // Its hot key (⌘Space from any app, or the key its welcome picks) is Carbon's.
    exe.root_module.linkFramework("Carbon", .{});
    // Opening at login, from its welcome (SMAppService).
    exe.root_module.linkFramework("ServiceManagement", .{});
    // The Codegraff key, kept in the Keychain (src/keychain.zig).
    exe.root_module.linkFramework("Security", .{});
    // AX trust for clipboard paste (CGEvent is supplied by nanoui).
    exe.root_module.linkFramework("ApplicationServices", .{});
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Nanolight (⌘Space)").dependOn(&run.step);

    // zig-out/Nanolight.app: the program with its icon, for /Applications.
    const app = b.addInstallDirectory(.{ .source_dir = bundle(b, exe, version), .install_dir = .prefix, .install_subdir = "Nanolight.app" });
    b.getInstallStep().dependOn(&app.step);
    b.step("app", "Build zig-out/Nanolight.app").dependOn(&app.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("test", "Test Nanolight's search, math, suggestions and panel").dependOn(&b.addRunArtifact(tests).step);

    // The walkthrough, rendered offscreen (src/film.zig, tools/film.sh).
    const film = b.addExecutable(.{ .name = "nanolight-film", .root_module = b.createModule(.{
        .root_source_file = b.path("src/film.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("film", "Build the walkthrough's renderer (zig-out/bin/nanolight-film)").dependOn(&b.addInstallArtifact(film, .{}).step);

    // The promo's shots, rendered offscreen (src/promo.zig, tools/promo.sh).
    const promo = b.addExecutable(.{ .name = "nanolight-promo", .root_module = b.createModule(.{
        .root_source_file = b.path("src/promo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("promo", "Build the promo's renderer (zig-out/bin/nanolight-promo)").dependOn(&b.addInstallArtifact(promo, .{}).step);
}

/// Nanolight as a Mac app: its program, its icon, and an Info.plist that
/// keeps it out of the Dock (a menu bar app).
fn bundle(b: *std.Build, exe: *std.Build.Step.Compile, version: []const u8) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    _ = wf.add("Contents/Info.plist", infoPlist(b, version));
    _ = wf.addCopyFile(exe.getEmittedBin(), "Contents/MacOS/nanolight");
    _ = wf.addCopyFile(b.path("macos/AppIcon.icns"), "Contents/Resources/AppIcon.icns");
    return wf.getDirectory();
}

/// The bundle's Info.plist (macos/package.sh writes the same one).
pub fn infoPlist(b: *std.Build, version: []const u8) []const u8 {
    return b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key><string>nanolight</string>
        \\  <key>CFBundleIdentifier</key><string>dev.nanoui.nanolight</string>
        \\  <key>CFBundleName</key><string>Nanolight</string>
        \\  <key>CFBundleDisplayName</key><string>Nanolight</string>
        \\  <key>CFBundleIconFile</key><string>AppIcon</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>{s}</string>
        \\  <key>CFBundleVersion</key><string>{s}</string>
        \\  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
        \\  <key>LSMinimumSystemVersion</key><string>14.0</string>
        \\  <key>LSUIElement</key><true/>
        \\  <key>NSPrincipalClass</key><string>NSApplication</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\</dict>
        \\</plist>
        \\
    , .{ version, version });
}
