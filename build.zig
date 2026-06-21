const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

const Board = enum {
    pico2,
    seed_xiao,
};

const Half = enum {
    left,
    right,
};

pub fn build(b: *std.Build) !void {
    const board = b.option(
        Board,
        "board",
        "target board",
    ) orelse .pico2;

    const optimize: std.builtin.OptimizeMode = switch (b.release_mode) {
        .off, .any => .Debug,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;
    try addHalf(b, mb, optimize, board, .right);
    try addHalf(b, mb, optimize, board, .left);
}

fn addHalf(b: *std.Build, mb: *MicroBuild, optimize: std.builtin.OptimizeMode, board: Board, half: Half) !void {
    const target: *const microzig.Target = if (board == .pico2) t: {
        break :t mb.ports.rp2xxx.boards.raspberrypi.pico2_arm;
    } else t: {
        break :t mb.ports.rp2xxx.boards.raspberrypi.pico;
    };
    const half_name = @tagName(half);
    const fw = mb.add_firmware(.{
        .name = try std.fmt.allocPrint(b.allocator, "zigmk_{s}", .{half_name}),
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    const build_opts = b.addOptions();
    build_opts.addOption(Board, "board", board);
    build_opts.addOption(Half, "half", half);
    fw.add_options("build_config", build_opts);
    mb.install_firmware(fw, .{});
    mb.install_firmware(fw, .{ .format = .elf });
}
