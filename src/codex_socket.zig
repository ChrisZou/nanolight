//! WebSocket client for Codex's local app-server control socket.
const std = @import("std");
const Opcode = std.http.Server.WebSocket.Opcode;
const limit = 16 * 1024 * 1024;

pub const Client = struct {
    stream: std.Io.net.Stream,
    expected: [28]u8,
    upgraded: bool = false,
    bytes: std.ArrayList(u8) = .empty,
    fragments: std.ArrayList(u8) = .empty,
    fragmented: bool = false,

    pub fn connect(io: std.Io, path: []const u8) !Client {
        if (path.len >= @sizeOf(@FieldType(std.c.sockaddr.un, "path"))) return error.PathTooLong;
        const address = try std.Io.net.UnixAddress.init(path);
        const stream = try address.connect(io);
        errdefer stream.close(io);
        const yes: c_int = 1;
        if (std.c.setsockopt(stream.socket.handle, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &yes, @sizeOf(c_int)) != 0) return error.SocketOption;
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);
        var hash = std.crypto.hash.Sha1.init(.{});
        hash.update(&key);
        hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        hash.final(&digest);
        var client: Client = .{ .stream = stream, .expected = undefined };
        _ = std.base64.standard.Encoder.encode(&client.expected, &digest);
        var buf: [256]u8 = undefined;
        try client.write(io, try std.fmt.bufPrint(&buf, "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{key}));
        return client;
    }

    pub fn close(c: *Client, io: std.Io, gpa: std.mem.Allocator) void {
        c.stream.close(io);
        c.bytes.deinit(gpa);
        c.fragments.deinit(gpa);
    }

    fn write(c: *Client, io: std.Io, data: []const u8) !void {
        var writer = c.stream.writer(io, &.{});
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    pub fn send(c: *Client, io: std.Io, gpa: std.mem.Allocator, op: Opcode, data: []const u8) !void {
        var frame: std.Io.Writer.Allocating = .init(gpa);
        defer frame.deinit();
        const w = &frame.writer;
        try w.writeByte(0x80 | @as(u8, @backingInt(op)));
        if (data.len < 126) {
            try w.writeByte(0x80 | @as(u8, @intCast(data.len)));
        } else if (data.len <= 65535) {
            try w.writeByte(0xfe);
            try w.writeInt(u16, @intCast(data.len), .big);
        } else {
            try w.writeByte(0xff);
            try w.writeInt(u64, data.len, .big);
        }
        var mask: [4]u8 = undefined;
        io.random(&mask);
        try w.writeAll(&mask);
        for (data, 0..) |byte, i| try w.writeByte(byte ^ mask[i % 4]);
        try c.write(io, frame.written());
    }

    /// Called on the main queue with bytes from a readable socket. Keep
    /// partial HTTP headers, frames and fragmented messages across callbacks.
    pub fn feed(c: *Client, io: std.Io, gpa: std.mem.Allocator, data: []const u8, session: anytype) !void {
        try c.bytes.appendSlice(gpa, data);
        if (!c.upgraded) {
            const end = std.mem.indexOf(u8, c.bytes.items, "\r\n\r\n") orelse {
                if (c.bytes.items.len > 8192) return error.BadUpgrade;
                return;
            };
            try checkUpgrade(c.bytes.items[0 .. end + 4], &c.expected);
            c.bytes.replaceRangeAssumeCapacity(0, end + 4, &.{});
            c.upgraded = true;
            try session.initialize();
        }
        var consumed: usize = 0;
        while (try parseFrame(c.bytes.items[consumed..])) |f| {
            switch (f.op) {
                .ping => try c.send(io, gpa, .pong, f.payload),
                .pong => {},
                .connection_close => return error.Closed,
                .text, .continuation => {
                    if (c.fragmented != (f.op == .continuation)) return error.BadFrame;
                    if (f.fin and !c.fragmented) {
                        try session.handle(f.payload);
                    } else {
                        if (f.payload.len > limit - c.fragments.items.len) return error.TooLarge;
                        try c.fragments.appendSlice(gpa, f.payload);
                        c.fragmented = !f.fin;
                        if (f.fin) {
                            try session.handle(c.fragments.items);
                            c.fragments.clearRetainingCapacity();
                        }
                    }
                },
                else => return error.BadFrame,
            }
            consumed += f.size;
        }
        c.bytes.replaceRangeAssumeCapacity(0, consumed, &.{});
    }
};

fn checkUpgrade(headers: []const u8, expected: []const u8) !void {
    const head = try std.http.Client.Response.Head.parse(headers);
    if (head.status != .switching_protocols) return error.BadUpgrade;
    var lines = std.mem.tokenizeSequence(u8, headers, "\r\n");
    var accepted = false;
    var upgrade = false;
    var connection = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) accepted = std.mem.eql(u8, value, expected);
        if (std.ascii.eqlIgnoreCase(name, "Upgrade")) upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
        if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            var tokens = std.mem.tokenizeAny(u8, value, ", \t");
            while (tokens.next()) |t| if (std.ascii.eqlIgnoreCase(t, "upgrade")) {
                connection = true;
            };
        }
    }
    if (!accepted or !upgrade or !connection) return error.BadUpgrade;
}

const Frame = struct { op: Opcode, fin: bool, payload: []const u8, size: usize };

fn parseFrame(bytes: []const u8) !?Frame {
    if (bytes.len < 2) return null;
    if (bytes[0] & 0x70 != 0 or bytes[1] & 0x80 != 0) return error.BadFrame;
    const fin = bytes[0] & 0x80 != 0;
    var size: u64 = bytes[1];
    if (bytes[0] & 8 != 0 and (!fin or size > 125)) return error.BadFrame;
    var off: usize = 2;
    if (size == 126) {
        if (bytes.len < 4) return null;
        size = std.mem.readInt(u16, bytes[2..4], .big);
        off = 4;
    } else if (size == 127) {
        if (bytes.len < 10) return null;
        size = std.mem.readInt(u64, bytes[2..10], .big);
        off = 10;
    }
    if (size > limit) return error.TooLarge;
    const end = off + @as(usize, @intCast(size));
    if (bytes.len < end) return null;
    return .{ .op = @fromBackingInt(@intCast(@as(u4, @truncate(bytes[0])))), .fin = fin, .payload = bytes[off..end], .size = end };
}

test "shared socket validates the upgrade and waits for complete extended frames" {
    const hdr = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: test\r\n\r\n";
    try checkUpgrade(hdr, "test");
    try std.testing.expectError(error.BadUpgrade, checkUpgrade(hdr, "different"));
    var data: [132]u8 = @splat('Q');
    data[0..4].* = "\x81\x7e\x00\x80".*;
    for (0..data.len) |n| try std.testing.expect(try parseFrame(data[0..n]) == null);
    const frame = (try parseFrame(&data)).?;
    try std.testing.expectEqual(.text, frame.op);
    try std.testing.expectEqualStrings(data[4..], frame.payload);
    try std.testing.expectError(error.BadFrame, parseFrame("\x09\x00"));
}
