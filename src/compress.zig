const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const DecompressorType = std.compress.flate.Decompress;

const vendoredCompress = @import("vendor/flate.Compress.zig");
const CompressorType = vendoredCompress;

pub const Compressor = struct {
    compressor: *CompressorType,
    buf: []u8,
    output: *std.Io.Writer.Allocating,

    pub fn init(allocator: Allocator) !Compressor {
        const buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(buf);

        const output = try allocator.create(std.Io.Writer.Allocating);
        errdefer allocator.destroy(output);
        output.* = try .initCapacity(allocator, 4096);

        const compressor = try allocator.create(CompressorType);
        errdefer allocator.destroy(compressor);
        compressor.* = try .init(&output.writer, buf, .raw, .default);
        return .{
            .compressor = compressor,
            .buf = buf,
            .output = output,
        };
    }
    pub fn deinit(self: *Compressor, allocator: Allocator) void {
        self.output.deinit();
        allocator.destroy(self.output);
        allocator.free(self.buf);
        allocator.destroy(self.compressor);
    }

    pub fn reset(self: *Compressor) void {
        self.compressor.* = CompressorType.init(
            &self.output.writer,
            self.buf,
            .raw,
            .default,
        ) catch unreachable;
    }

    pub fn compress(self: *Compressor, payload: []const u8) ![]const u8 {
        // send compressed
        var output = self.output;
        // Reset compressor sink
        output.writer.end = 0;

        try self.compressor.writer.writeAll(payload);
        try self.compressor.syncFlush();
        const compressed = output.written();
        var out: []u8 = undefined;
        if (std.mem.endsWith(u8, compressed, &[_]u8{ 0x00, 0x00, 0xff, 0xff })) {
            out = compressed[0 .. compressed.len - 4];
        } else {
            out = compressed[0..];
        }
        return out;
    }
};

pub const Decompressor = struct {
    decompressor: ?DecompressorType = null,
    buf: []u8,
    reader: ?Io.Reader = null,
    output: *Io.Writer.Allocating,

    pub fn init(allocator: Allocator) !Decompressor {
        const buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(buf);

        const output = try allocator.create(Io.Writer.Allocating);
        errdefer output.deinit();
        output.* = .init(allocator);
        return .{
            .buf = buf,
            .output = output,
        };
    }

    pub fn deinit(self: *Decompressor, allocator: Allocator) void {
        allocator.free(self.buf);
        self.output.deinit();
        allocator.destroy(self.output);
    }

    pub fn reset(self: *Decompressor) void {
        self.decompressor = null;
    }

    fn runDecompress(self: *Decompressor, allocator: Allocator, compressed: []const u8) !void {
        const input = try allocator.alloc(u8, compressed.len + 4);
        defer allocator.free(input);
        @memcpy(input[0..compressed.len], compressed);
        // Append the empty stored block tail (LEN + NLEN). The header bits are
        // already in the last byte(s) of the compressed payload from syncFlush.
        @memcpy(input[compressed.len..], &[_]u8{ 0x00, 0x00, 0xff, 0xff });

        var reader = Io.Reader.fixed(input);
        self.reader = reader;
        if (self.decompressor == null) {
            self.decompressor = .init(&reader, .raw, self.buf);
        }

        // Reset output sink
        var output = self.output;
        output.writer.end = 0;
        _ = self.decompressor.?.reader.streamRemaining(&output.writer) catch |err| switch (err) {
            error.ReadFailed => {
                // The stdlib decompressor treats a non-final EndOfStream as an error.
                // For per-message-deflate the empty stored block is non-final to allow
                // context takeover, so this is the expected termination path.
                const underlying = self.decompressor.?.err orelse return error.ReadFailed;
                if (underlying != error.EndOfStream) return error.ReadFailed;
            },
            else => |e| return e,
        };
    }

    pub fn decompress(
        self: *Decompressor,
        allocator: Allocator,
        compressed: []const u8,
    ) ![]u8 {
        try self.runDecompress(allocator, compressed);
        return self.output.written();
    }

    pub fn decompressAlloc(self: *Decompressor, allocator: Allocator, compressed: []const u8) ![]u8 {
        try self.runDecompress(allocator, compressed);
        return try self.output.toOwnedSlice();
    }
};

test "compressor/decompressor round trip" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit(allocator);
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit(allocator);

    const payload = "Hello";
    const compressed = try compressor.compress(payload);
    const decompressed = try decompressor.decompressAlloc(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(payload, decompressed);
}

test "compressor strips trailing empty stored block" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit(allocator);

    const compressed = try compressor.compress("Hello");
    try std.testing.expect(!std.mem.endsWith(u8, compressed, &[_]u8{ 0x00, 0x00, 0xff, 0xff }));
}

test "compressor/decompressor empty payload round trip" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit(allocator);
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit(allocator);

    const compressed = try compressor.compress("");
    const decompressed = try decompressor.decompressAlloc(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings("", decompressed);
}

test "compressor reset produces identical output" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit(allocator);

    const payload = "The quick brown fox jumps over the lazy dog";
    const first = try allocator.dupe(u8, try compressor.compress(payload));
    defer allocator.free(first);

    compressor.reset();
    const second = try compressor.compress(payload);

    try std.testing.expectEqualSlices(u8, first, second);
}

test "compressor/decompressor multiple messages with reset" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit(allocator);
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit(allocator);

    const messages = [_][]const u8{
        "First message",
        "Second message, a bit longer",
        "Third message: αβγ δεζ ηθι",
    };

    for (messages) |msg| {
        const compressed = try compressor.compress(msg);
        const decompressed = try decompressor.decompressAlloc(allocator, compressed);
        defer allocator.free(decompressed);
        try std.testing.expectEqualStrings(msg, decompressed);
        compressor.reset();
    }
}

test "decompress returns borrowed slice" {
    const allocator = std.testing.allocator;
    var compressor = try Compressor.init(allocator);
    defer compressor.deinit(allocator);
    var decompressor = try Decompressor.init(allocator);
    defer decompressor.deinit(allocator);

    const payload = "borrowed";
    const compressed = try compressor.compress(payload);
    const decompressed = try decompressor.decompress(allocator, compressed);
    // returned slice is owned by the decompressor's internal buffer
    try std.testing.expectEqualStrings(payload, decompressed);
}
