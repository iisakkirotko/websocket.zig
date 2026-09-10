const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ws_module = b.addModule("ws", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build test
    const test_compile = b.addTest(.{
        .root_module = ws_module,
        // .root_source_file = b.path("src/main.zig"),
        // .target = target,
        // .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(test_compile);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Build autobahn_client
    const autobahn_client_module = b.createModule(.{
        .root_source_file = b.path("examples/autobahn_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    autobahn_client_module.addImport("ws", ws_module);

    const autobahn_client = b.addExecutable(.{
        .name = "autobahn_client",
        .root_module = autobahn_client_module,
    });
    b.installArtifact(autobahn_client);
}
