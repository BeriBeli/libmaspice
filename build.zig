const std = @import("std");
const builtin = @import("builtin");
const apple = @import("src/build/apple.zig");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0"))
        @compileError("libmaspice requires Zig 0.17.0");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 26, .minor = 0, .patch = 0 } },
    } });
    if (target.result.cpu.arch != .aarch64 or target.result.os.tag != .macos)
        @panic("the current native backend supports arm64 macOS 26+ only");
    if (target.result.os.version_range.semver.min.order(.{ .major = 26, .minor = 0, .patch = 0 }) != .eq)
        @panic("the packaged ABI deployment target must remain macOS 26.0");
    const mode: std.builtin.OptimizeMode = .safe; // Zig 0.17 name for ReleaseSafe.
    _ = b.addModule("maspice", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = mode, .link_libc = true });
    const native = apple.build(b, target, mode);
    b.getInstallStep().dependOn(native.install);

    const package = b.addSystemCommand(&.{ "python3", "tools/package-apple.py" });
    package.setCwd(b.path("."));
    package.addFileArg(native.core);
    package.addFileArg(native.quic);
    // Packaging is a deliberate update to the owned SwiftPM artifacts.
    package.has_side_effects = true;
    const xc = b.step("xcframework", "Build source-bound CSpiceZig and CSpiceQUIC SwiftPM artifacts");
    xc.dependOn(&package.step);
    xc.dependOn(native.install);

    const verify = b.addSystemCommand(&.{ "bash", "tools/verify-native-closure.sh", "--artifacts-only" });
    verify.setCwd(b.path("."));
    verify.step.dependOn(&package.step);
    b.step("check-native", "Verify source hashes, ABI, architecture, deployment and native closure").dependOn(&verify.step);

    const test_step = b.step("test", "Run deterministic Zig, C ABI, Swift differential and boundary sanitizer gates");
    var previous: *std.Build.Step = &verify.step;
    for ([_][]const u8{ "tools/validate-zig.sh", "tools/validate-zig-graphics.sh" }) |script| {
        const run = b.addSystemCommand(&.{ "bash", script });
        run.setCwd(b.path("."));
        run.step.dependOn(previous);
        previous = &run.step;
    }
    test_step.dependOn(previous);
    const installed_test = b.addSystemCommand(&.{ "bash", "tools/validate-installed.sh" });
    installed_test.addDirectoryArg(.{ .relative = .{ .base = .install_prefix } });
    installed_test.setCwd(b.path("."));
    installed_test.step.dependOn(b.getInstallStep());
    b.step("test-installed", "Test C ABI consumers against the installed complete static archive").dependOn(&installed_test.step);
    test_step.dependOn(&installed_test.step);
    const package_test = b.addSystemCommand(&.{ "bash", "tools/validate-zig-package.sh" });
    package_test.setCwd(b.path("."));
    package_test.step.dependOn(&verify.step);
    b.step("test-package", "Test actual SwiftPM Release consumers and legacy-runtime absence").dependOn(&package_test.step);
    const quic_test = b.addSystemCommand(&.{ "bash", "tools/validate-quic.sh" });
    quic_test.setCwd(b.path("."));
    quic_test.step.dependOn(&verify.step);
    b.step("test-quic", "Compare QUIC against checksum-pinned independent upstream C (network on first run)").dependOn(&quic_test.step);
    const video_test = b.addSystemCommand(&.{ "bash", "tools/validate-zig-video.sh" });
    video_test.setCwd(b.path("."));
    video_test.step.dependOn(&verify.step);
    b.step("test-video", "Run native video checks; advanced hardware success remains a separate acceptance gate").dependOn(&video_test.step);
}
