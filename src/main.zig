pub fn client(
    allocator: std.mem.Allocator,
    inner_reader: *std.Io.Reader,
    inner_writer: *std.Io.Writer,
    uri: []const u8,
) !stream.Stream {
    const options = try handshake.client(allocator, inner_reader, inner_writer, uri);
    return try stream.client(allocator, inner_reader, inner_writer, options);
}

test {
    // Run tests in imported files in `zig build test`
    _ = @import("handshake.zig");
    _ = @import("stream.zig");
    _ = @import("frame.zig");
    _ = @import("async.zig");
}

pub const asyn = struct {
    pub const Server = asyn_.Server;
    pub const Client = asyn_.Client;
    pub const Conn = asyn_.Conn;
};

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const asyn_ = @import("async.zig");
pub const Msg = asyn_.Msg;
pub const handshake = @import("handshake.zig");
pub const stream = @import("stream.zig");
pub const Message = stream.Message;
