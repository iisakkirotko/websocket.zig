const std = @import("std");
const Allocator = std.mem.Allocator;

const ws = @import("ws");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("Usage: autobahn_client <case_count>", .{});
        return error.InvalidArguments;
    }

    const cases_count = try std.fmt.parseUnsigned(usize, args[1], 10);
    const allocator = init.gpa;
    std.log.debug("number of test cases: {d}", .{cases_count});

    var case_no: usize = 1;
    while (case_no <= cases_count) : (case_no += 1) {
        const start = std.Io.Timestamp.now(init.io, std.Io.Clock.awake);

        try runTestCase(allocator, init.io, case_no);
        const durationMs = start.untilNow(init.io, std.Io.Clock.awake).toMilliseconds();
        if (durationMs > 100) {
            std.debug.print("{d}/{d} {d}ms\n", .{ case_no, cases_count, durationMs });
        }
    }
    std.debug.print("\n", .{});
}

fn runTestCase(allocator: Allocator, io: std.Io, no: usize) !void {
    var uri_buf: [128]u8 = undefined;
    const hostname = "localhost";
    const port = 9001;
    const uri = try std.fmt.bufPrint(&uri_buf, "ws://{s}:{d}/runCase?case={d}&agent=websocket_test.zig", .{ hostname, port, no });

    const host = try std.Io.net.HostName.init(hostname);
    var tcp = try host.connect(io, port, .{ .mode = .stream });
    defer tcp.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var tcp_reader = tcp.reader(io, &read_buf).interface;
    var tcp_writer = tcp.writer(io, &write_buf).interface;

    var cli = try ws.client(allocator, &tcp_reader, &tcp_writer, uri);
    defer cli.deinit();

    // echo loop read and send message
    while (cli.nextMessage()) |msg| {
        defer msg.deinit();
        try cli.sendMessage(msg);
    }
    if (cli.err) |_| {
        std.debug.print("e", .{});
        //std.log.err("case: {d} {}", .{ no, err });
    } else {
        std.debug.print(".", .{});
    }
}
