const std = @import("std");

const ws = @import("ws");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var message_count: usize = 1000;
    var payload_size: usize = 16;

    if (args.len >= 2) message_count = try std.fmt.parseUnsigned(usize, args[1], 10);
    if (args.len >= 3) payload_size = try std.fmt.parseUnsigned(usize, args[2], 10);

    // Build a text payload of the requested size.
    const payload = try allocator.alloc(u8, payload_size);
    defer allocator.free(payload);
    @memset(payload, 'x');

    var compressor = try ws.stream.Compressor.init(allocator);
    defer compressor.deinit(allocator);

    // Encode every frame into a single contiguous buffer.
    const max_per_frame = payload_size + 32;
    const frame_buf = try allocator.alloc(u8, max_per_frame * message_count);
    defer allocator.free(frame_buf);
    var offset: usize = 0;

    for (0..message_count) |_| {
        const compressed = try compressor.compress(payload);

        const frame = ws.stream.Frame{
            .fin = 1,
            .rsv1 = 1,
            .opcode = .text,
            .mask = 0,
            .payload = compressed,
        };

        const encoded_len = frame.encodedLen();
        _ = frame.encode(frame_buf[offset..][0..encoded_len], 0);
        offset += encoded_len;
    }

    var input = std.Io.Reader.fixed(frame_buf[0..offset]);
    const output_buf = try allocator.alloc(u8, frame_buf.len);
    defer allocator.free(output_buf);
    var output = std.Io.Writer.fixed(output_buf);

    var stm = try ws.stream.client(
        allocator,
        &input,
        &output,
        .{
            .per_message_deflate = true,
            .compress_threshold = 1,
        },
    );
    defer stm.deinit();

    const start = std.Io.Timestamp.now(io, std.Io.Clock.awake);
    var count: usize = 0;
    while (stm.nextMessage()) |msg| {
        defer msg.deinit();
        try stm.sendMessage(msg);
        count += 1;
    }
    const elapsed = start.untilNow(io, std.Io.Clock.awake).toMicroseconds();

    var summary_buf: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(
        &summary_buf,
        "benchmark: {d} messages (payload {d} bytes) in {d}us ({d}us/msg)\n",
        .{
            count,
            payload_size,
            elapsed,
            if (count > 0) @divFloor(elapsed, @as(i64, @intCast(count))) else 0,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, summary);
}
