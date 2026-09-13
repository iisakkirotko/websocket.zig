const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectError = testing.expectError;

const Compressor = @import("compress.zig").Compressor;
const Decompressor = @import("compress.zig").Decompressor;
const Frame = @import("frame.zig").Frame;

pub const Message = struct {
    pub const Encoding = enum {
        text,
        binary,

        pub fn opcode(self: Encoding) Frame.Opcode {
            return if (self == .text) Frame.Opcode.text else Frame.Opcode.binary;
        }

        pub fn from(frame_opcode: Frame.Opcode) Encoding {
            return if (frame_opcode == .binary) .binary else .text;
        }
    };

    encoding: Encoding = .text,
    payload: []const u8,
    compressed: bool = false,
    allocator: ?Allocator = null,

    const Self = @This();

    pub fn init(allocator: Allocator, encoding: Encoding, payload: []const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .encoding = encoding,
            .payload = payload,
        };
        try self.validate();
        return self;
    }

    pub fn deinit(self: Self) void {
        if (self.allocator) |a| a.free(self.payload);
    }

    pub fn validate(self: Self) !void {
        if (self.encoding == .text)
            try Frame.assertValidUtf8(self.payload);
    }

    pub fn append(self: *Self, data: []const u8) !void {
        const old_len = self.payload.len;
        const payload = try self.allocator.?.realloc(@constCast(self.payload), old_len + data.len);
        @memcpy(payload[old_len..], data);
        self.payload = payload;
    }

    pub fn decompress(self: *Message, allocator: mem.Allocator, decompressor: *Decompressor) !void {
        if (!self.compressed) return;
        const old_payload = self.payload;
        self.payload = try decompressor.decompressAlloc(allocator, self.payload);
        if (self.allocator) |a| a.free(old_payload);
        self.allocator = allocator;
        self.compressed = false;
    }
};

pub const Options = struct {
    // is compression supported
    per_message_deflate: bool = false,

    // false indicates that the client can decompress a message that the server built using context takeover
    server_no_context_takeover: bool = false,

    // false indicates that the server can decompress messages built by the client using context takeover
    client_no_context_takeover: bool = false,

    // by including this extension parameter in an extension negotiation response, a server
    // limits the LZ77 sliding window size that the client uses to compress messages
    client_max_window_bits: u4 = 15,

    // limits the LZ77 sliding window size that the server will use to compress messages
    server_max_window_bits: u4 = 15,

    // don't compress payload smaller than threshold
    compress_threshold: usize = 126,
};

pub const Stream = struct {
    const CompressorType = Compressor;
    const Self = @This();

    reader: WebSocketReader,
    writer: WebSocketWriter,

    allocator: Allocator,
    err: ?anyerror = null,

    // used in validation
    last_frame_fragment: Frame.Fragment = .unfragmented,

    // message compression
    compressor: ?*CompressorType = null, //     not null if per_message_deflate is negotiated
    decompressor: ?*Decompressor = null,
    reset_compressor: bool = false, //          true if sliding window is not negotiated
    reset_decompressor: bool = false,
    compress_threshold: usize = 126, //         don't compress tiny payload

    fn resetCompressor(self: *Self) void {
        self.compressor.?.reset();
    }

    fn readDataFrame(self: *Self) !Frame {
        while (true) {
            var frame = try self.reader.frame(self.allocator);
            if (frame.isControl()) {
                defer frame.deinit();
                try self.handleControlFrame(&frame);
            } else {
                errdefer frame.deinit();
                try frame.assertValidContinuation(self.last_frame_fragment);
                self.last_frame_fragment = frame.fragment();
                return frame;
            }
        }
    }

    fn handleControlFrame(self: *Self, frame: *Frame) !void {
        switch (frame.opcode) {
            .ping => try self.writer.pong(frame.payload),
            .close => {
                try self.writer.close(frame.closeCode(), frame.closePayload());
                return error.EndOfStream;
            },
            .pong => {},
            else => unreachable,
        }
    }

    fn setErr(self: *Self, err: anyerror) void {
        if (err != error.EndOfStream) self.err = err;
    }

    pub fn nextMessage(self: *Self) ?Message {
        return self.readMessage() catch |err| {
            self.setErr(err);
            return null;
        };
    }

    fn decompress(self: *Self, msg: *Message) !void {
        if (msg.compressed) {
            const decompressor = self.decompressor orelse return error.DeflateNotSupported;
            try msg.decompress(self.allocator, decompressor);
            if (self.reset_decompressor) decompressor.reset();
        }
        try msg.validate();
    }

    fn readMessage(self: *Self) !Message {
        // read first frame
        var frame = try self.readDataFrame();

        if (frame.isFin()) {
            // if single frame return frame payload as message payload
            // message takes ownership of the allocated payload
            errdefer frame.deinit();
            var msg = Message{
                .encoding = Message.Encoding.from(frame.opcode),
                .compressed = frame.isCompressed(),
                .allocator = self.allocator,
                .payload = frame.payload,
            };
            try self.decompress(&msg);
            return msg;
        }

        // other frames payload will be collected into payload
        var msg = Message{
            .encoding = Message.Encoding.from(frame.opcode),
            .compressed = frame.isCompressed(),
            .allocator = self.allocator,
            .payload = try self.allocator.dupe(u8, frame.payload),
        };
        errdefer msg.deinit();
        frame.deinit();

        while (true) {
            frame = try self.readDataFrame();
            defer frame.deinit();
            try msg.append(frame.payload);
            if (frame.isFin()) break;
        }
        try self.decompress(&msg);
        return msg;
    }

    pub fn sendMessage(self: *Self, msg: Message) !void {
        try self.send(msg.encoding, msg.payload, false);
    }

    pub fn send(
        self: *Self,
        encoding: Message.Encoding,
        payload: []const u8,
        // prevent payload compression
        // useful if payload is of already compressed type, for example jpg
        no_compress: bool,
    ) !void {
        if (!no_compress and payload.len >= self.compress_threshold) {
            if (self.compressor) |compressor| {
                const out = try compressor.compress(payload);
                if (self.reset_compressor) self.resetCompressor();
                return try self.writer.message(encoding, out, true);
            }
        }
        try self.writer.message(encoding, payload, false);
        return;
    }

    pub fn deinit(self: *Self) void {
        if (self.compressor) |compressor| {
            compressor.deinit(self.allocator);
            self.allocator.destroy(compressor);
        }
        if (self.decompressor) |decompressor| {
            decompressor.deinit(self.allocator);
            self.allocator.destroy(decompressor);
        }
        self.writer.deinit();
    }
};

pub const WebSocketReader = struct {
    inner: *Io.Reader,
    deflate_supported: bool,

    const Self = @This();

    pub fn init(inner_reader: *Io.Reader, deflate_supported: bool) !Self {
        return .{
            .inner = inner_reader,
            .deflate_supported = deflate_supported,
        };
    }

    fn readPayloadLen(self: *Self, byte: u8) !u64 {
        return switch (byte) {
            126 => try self.inner.takeInt(u16, .big),
            127 => try self.inner.takeInt(u64, .big),
            else => byte,
        };
    }

    fn readAll(self: *Self, buffer: []u8) !void {
        try self.inner.readSliceAll(buffer);
    }

    fn readPayload(self: *Self, allocator: Allocator, payload_len: u64, masked: bool) ![]u8 {
        if (payload_len == 0) return &.{};
        var masking_key = [_]u8{0} ** 4;
        if (masked) try self.readAll(&masking_key);
        const payload = try allocator.alloc(u8, payload_len);
        try self.readAll(payload);
        if (masked) Frame.maskUnmask(&masking_key, payload);
        return payload;
    }

    pub fn frame(self: *Self, allocator: Allocator) !Frame {
        const b0 = try self.inner.takeByte();
        const fin: u1 = @intCast(b0 >> 7);
        const rsv1: u1 = @intCast((b0 >> 6) & 0x1);
        const rsv2: u1 = @intCast((b0 >> 5) & 0x1);
        const rsv3: u1 = @intCast((b0 >> 4) & 0x1);
        try Frame.assertRsvBits(rsv2, rsv3);

        const opcode = try Frame.Opcode.decode(@intCast(b0 & 0x0f));
        const b1 = try self.inner.takeByte();
        const mask: u1 = @intCast(b1 >> 7);
        const payload_len = try self.readPayloadLen(b1 & 0x7f);

        const payload = try self.readPayload(allocator, payload_len, mask == 1);

        var frm = Frame{
            .fin = fin,
            .rsv1 = rsv1,
            .mask = mask,
            .opcode = opcode,
            .payload = payload,
            .allocator = if (payload.len > 0) allocator else null,
        };
        errdefer frm.deinit();
        try frm.assertValid(self.deflate_supported);
        return frm;
    }
};

pub const WebSocketWriter = struct {
    inner: *Io.Writer,
    buf: []u8,
    allocator: Allocator,

    const Self = @This();

    const writer_buffer_len = 4096;

    pub fn init(allocator: Allocator, inner_writer: *Io.Writer) !Self {
        return .{
            .allocator = allocator,
            .buf = try allocator.alloc(u8, writer_buffer_len),
            .inner = inner_writer,
        };
    }

    pub fn pong(self: *Self, payload: []const u8) !void {
        assert(payload.len < 126);
        const frame = Frame{ .fin = 1, .opcode = .pong, .payload = payload, .mask = 1 };
        const bytes = frame.encode(self.buf, 0);
        try self.inner.writeAll(self.buf[0..bytes]);
        try self.inner.flush();
    }

    pub fn close(self: *Self, code: u16, payload: []const u8) !void {
        assert(payload.len < 124);
        const frame = Frame{ .fin = 1, .opcode = .close, .payload = payload, .mask = 1 };
        const bytes = frame.encode(self.buf, code);
        try self.inner.writeAll(self.buf[0..bytes]);
        try self.inner.flush();
    }

    pub fn message(self: *Self, encoding: Message.Encoding, payload: []const u8, compressed: bool) !void {
        var sent_payload: usize = 0;
        // send multiple frames if needed
        while (true) {
            const first_frame = sent_payload == 0;

            var fin: u1 = 1;
            const rsv1: u1 = if (compressed and first_frame) 1 else 0;

            // use frame payload that fits into write_buf
            var frame_payload = payload[sent_payload..];
            if (frame_payload.len + Frame.max_header > self.buf.len) {
                frame_payload = frame_payload[0 .. self.buf.len - Frame.max_header];
                fin = 0;
            }
            const opcode = if (first_frame) encoding.opcode() else Frame.Opcode.continuation;

            // create frame
            const frame = Frame{ .fin = fin, .rsv1 = rsv1, .opcode = opcode, .payload = frame_payload, .mask = 1 };
            // encode frame into write_buf and send it to stream
            const bytes = frame.encode(self.buf, 0);
            try self.inner.writeAll(self.buf[0..bytes]);
            try self.inner.flush();
            // loop if something is left
            sent_payload += frame_payload.len;
            if (sent_payload >= payload.len) {
                break;
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buf);
    }
};

fn reader(inner_reader: *Io.Reader, deflate_supported: bool) !WebSocketReader {
    return WebSocketReader.init(inner_reader, deflate_supported);
}

fn writer(allocator: Allocator, inner_writer: *Io.Writer) !WebSocketWriter {
    return try WebSocketWriter.init(allocator, inner_writer);
}

// create websocket client stream
pub fn client(
    allocator: Allocator,
    inner_reader: *Io.Reader,
    inner_writer: *Io.Writer,
    options: Options,
) !Stream {
    var stream = Stream{
        .allocator = allocator,
        .reader = try reader(inner_reader, options.per_message_deflate),
        .writer = try writer(allocator, inner_writer),
        .reset_compressor = options.client_no_context_takeover,
        .reset_decompressor = options.server_no_context_takeover,
        .compress_threshold = options.compress_threshold,
    };
    if (options.per_message_deflate) {
        // NOTE: options.server_max_window_bits not used because not supported by std lib

        const comp = try allocator.create(Compressor);
        comp.* = try Compressor.init(allocator);
        stream.compressor = comp;

        const decomp = try allocator.create(Decompressor);
        decomp.* = try Decompressor.init(allocator);
        stream.decompressor = decomp;
    }
    return stream;
}

test "reader read close frame" {
    const input_bytes = [_]u8{ 0x88, 0x02, 0x03, 0xe8 };
    var input = Io.Reader.fixed(&input_bytes);
    var rdr = try reader(&input, false);
    var frame = try rdr.frame(testing.allocator);
    defer frame.deinit();

    try expectEqual(frame.opcode, .close);
    try expectEqual(frame.fin, 1);
    try expectEqual(frame.payload.len, 2);
    try expectEqualSlices(u8, frame.payload, input_bytes[2..4]);
    try expectEqual(frame.closeCode(), 1000);
    try expectError(error.EndOfStream, rdr.frame(testing.allocator));
}

test "reader read masked close frame with payload" {
    const input_bytes = [_]u8{ 0x88, 0x87, 0xa, 0xb, 0xc, 0xd, 0x09, 0xe2, 0x0d, 0x0f, 0x09, 0x0f, 0x09 };
    var input = Io.Reader.fixed(&input_bytes);
    var rdr = try reader(&input, false);
    var frame = try rdr.frame(testing.allocator);
    defer frame.deinit();

    const expected_payload = [_]u8{ 0x3, 0xe9, 0x1, 0x2, 0x3, 0x4, 0x5 };

    try expectEqual(frame.opcode, .close);
    try expectEqual(frame.fin, 1);
    try expectEqual(frame.payload.len, 7);
    try expectEqualSlices(u8, frame.payload, &expected_payload);
    try expectEqual(frame.closeCode(), 1001);
    try expectError(error.EndOfStream, rdr.frame(testing.allocator));
}

const fixture_fragmented_message =
    [_]u8{ 0x01, 0x1, 0xa } ++ // first text frame
    [_]u8{ 0x89, 0x00 } ++ // ping in between
    [_]u8{ 0x00, 0x3, 0xb, 0xc, 0xd } ++ // continuation frame
    [_]u8{ 0x8a, 0x00 } ++ // pong
    [_]u8{ 0x80, 0x2, 0xe, 0xf };

test "read fragmented message" {
    var input = Io.Reader.fixed(&fixture_fragmented_message);
    var output: Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    var stm = try client(testing.allocator, &input, &output.writer, .{});
    defer stm.deinit();

    var msg = try stm.readMessage();
    defer msg.deinit();

    try testing.expectEqual(msg.encoding, .text);
    try testing.expectEqual(msg.payload.len, 6);
    try testing.expectEqualSlices(u8, msg.payload, &[_]u8{ 0xa, 0xb, 0xc, 0xd, 0xe, 0xf });

    // expect pong in the output
    const written = output.written();
    try expectEqual(written.len, 6); // pong header (2 bytes) + mask (4 bytes)
    try testing.expectEqualSlices(u8, written[0..2], &[_]u8{ 0x8a, 0x80 });
}

test "reader read frames" {
    var input = Io.Reader.fixed(&fixture_fragmented_message);
    var rdr = try reader(&input, false);

    const frames = [_]struct { Frame.Opcode, u1, usize }{
        // opcode, fin, payload_len
        .{ .text, 0, 1 },
        .{ .ping, 1, 0 },
        .{ .continuation, 0, 3 },
        .{ .pong, 1, 0 },
        .{ .continuation, 1, 2 },
    };

    for (frames) |expected| {
        var actual = try rdr.frame(testing.allocator);
        defer actual.deinit();
        try testing.expectEqual(actual.opcode, expected[0]);
        try testing.expectEqual(actual.fin, expected[1]);
        try testing.expectEqual(actual.payload.len, expected[2]);
    }
    try expectError(error.EndOfStream, rdr.frame(testing.allocator));
}

test "stream read frames" {
    var input = Io.Reader.fixed(&fixture_fragmented_message);
    var output: Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    var stm = try client(testing.allocator, &input, &output.writer, .{});
    defer stm.deinit();

    const frames = [_]struct { Frame.Opcode, u1, usize }{
        // opcode, fin, payload_len
        .{ .text, 0, 1 },
        .{ .ping, 1, 0 },
        .{ .continuation, 0, 3 },
        .{ .pong, 1, 0 },
        .{ .continuation, 1, 2 },
    };

    var rdr = stm.reader;
    for (frames) |expected| {
        var actual = try rdr.frame(testing.allocator);
        defer actual.deinit();
        try testing.expectEqual(actual.opcode, expected[0]);
        try testing.expectEqual(actual.fin, expected[1]);
        try testing.expectEqual(actual.payload.len, expected[2]);
    }
    try expectError(error.EndOfStream, rdr.frame(testing.allocator));
}

test "writer pong with payload" {
    var output_buf: [128]u8 = undefined;
    var output_writer = Io.Writer.fixed(&output_buf);
    var w = try writer(testing.allocator, &output_writer);
    defer w.deinit();
    const payload = "hello";
    try w.pong(payload);

    try expectEqual(output_writer.end, 11); // pong header (2 bytes) + mask (4 bytes) + payload (5 bytes)
    try testing.expectEqualSlices(u8, output_writer.buffer[0..2], &[_]u8{ 0x8a, 0x85 });
    Frame.maskUnmask(output_writer.buffer[2..6], output_writer.buffer[6 .. 6 + payload.len]);
    try testing.expectEqualSlices(u8, output_writer.buffer[6 .. 6 + payload.len], payload);
}

test "writer close with payload" {
    var output_buf: [128]u8 = undefined;
    var output_writer = Io.Writer.fixed(&output_buf);
    var w = try writer(testing.allocator, &output_writer);
    defer w.deinit();
    const payload = "hello";
    try w.close(1002, payload);

    try expectEqual(output_writer.end, 13); // pong header (2 bytes) + mask (4 bytes) + code (2 bytes) + payload (5 bytes)
    try testing.expectEqualSlices(u8, output_writer.buffer[0..2], &[_]u8{ 0x88, 0x87 });
    Frame.maskUnmask(output_writer.buffer[2..6], output_writer.buffer[6 .. 8 + payload.len]);
    try testing.expectEqualSlices(u8, output_writer.buffer[8 .. 8 + payload.len], payload);
}

test "writer message" {
    var output_buf: [128]u8 = undefined;
    var output_writer = Io.Writer.fixed(&output_buf);
    var w = try writer(testing.allocator, &output_writer);
    defer w.deinit();
    const payload = "hello world";
    try w.message(.text, payload, false);

    try expectEqual(output_writer.end, 17); // pong header (2 bytes) + mask (4 bytes) +  payload (11 bytes)
    try testing.expectEqualSlices(u8, output_writer.buffer[0..2], &[_]u8{ 0x81, 0x8B });
    Frame.maskUnmask(output_writer.buffer[2..6], output_writer.buffer[6 .. 6 + payload.len]);
    try testing.expectEqualSlices(u8, output_writer.buffer[6 .. 6 + payload.len], payload);
}

// debug helper
fn showBuf(buf: []const u8) void {
    std.debug.print("\n", .{});
    for (buf) |b|
        std.debug.print("0x{x:0>2}, ", .{b});
    std.debug.print("\n", .{});
}

test "deflate compress/decompress" {
    const allocator = testing.allocator;
    const text = "Hello";

    var compressor_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor_buf: [std.compress.flate.max_window_len]u8 = undefined;

    var output: Io.Writer.Allocating = try Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer output.deinit();

    for (0..128) |_| {
        output.writer.end = 0;
        var compressor = try std.compress.flate.Compress.init(&output.writer, &compressor_buf, .raw, .default);
        try compressor.writer.writeAll(text);
        try compressor.finish();
        const compressed = output.written();

        var input = Io.Reader.fixed(compressed);
        var decompressor = std.compress.flate.Decompress.init(&input, .raw, &decompressor_buf);

        var decompressed: Io.Writer.Allocating = .init(allocator);
        defer decompressed.deinit();
        _ = try decompressor.reader.streamRemaining(&decompressed.writer);

        try testing.expectEqualSlices(u8, text, decompressed.written());
    }
}

// Exercises the real Stream.send() compression path for per-message-deflate
// and round-trips the payload through the Decompressor wrapper.
test "per-message-deflate trailing block round trip via Stream.send" {
    const allocator = testing.allocator;

    const payloads = [_][]const u8{
        "Hello",
        "Hello world",
        "The quick brown fox jumps over the lazy dog",
        "aaaa",
        "aaaaaaaaaaaaaaaa",
        "abababababababab",
        &[_]u8{0} ** 100,
        &[_]u8{1} ** 500,
        &[_]u8{0x00} ** 1000,
        &[_]u8{0xff} ** 1000,
        "\x00\x00\x00\x00",
        "\xff\xff\xff\xff",
        "{\"type\":\"ping\"}",
        "<?xml version=\"1.0\"?><root></root>",
    };

    for (payloads) |payload| {
        const input_bytes = [_]u8{};
        var input = Io.Reader.fixed(&input_bytes);
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();

        var stm = try client(allocator, &input, &output.writer, .{
            .per_message_deflate = true,
            .compress_threshold = 1,
        });
        defer stm.deinit();

        try stm.send(.text, payload, false);

        const frame_data = output.written();
        const frame_buf = try allocator.dupe(u8, frame_data);
        defer allocator.free(frame_buf);

        const frame, _ = try Frame.parse(frame_buf);
        try testing.expect(frame.isCompressed());

        var decompressor = try Decompressor.init(allocator);
        defer decompressor.deinit(allocator);

        const decompressed = try decompressor.decompressAlloc(allocator, frame.payload);
        defer allocator.free(decompressed);

        errdefer std.debug.print("failed payload len={d} data={any}\n", .{ payload.len, payload });
        try testing.expectEqualSlices(u8, payload, decompressed);
    }
}
