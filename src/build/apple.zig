const std = @import("std");
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct { core: LazyPath, quic: LazyPath, install: *std.Build.Step } {
    const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\r\n");
    var objects: std.ArrayList(LazyPath) = .empty;
    const lib = b.addLibrary(.{ .name = "maspice", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
    }) });
    lib.bundle_compiler_rt = true;
    objects.append(b.allocator, lib.getEmittedBin()) catch @panic("OOM");
    for ([_][]const u8{ "network_bridge.m", "security.c", "video_bridge.m", "graphics_bridge.m", "pasteboard_bridge.m", "audio_bridge.m", "webdav_bridge.m", "codec_bridge.c", "host_view_bridge.m" }) |source| {
        const cc = b.addSystemCommand(&.{ "xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror", "-arch", "arm64", "-isysroot", sdk, "-mmacosx-version-min=26.0", "-fobjc-arc", "-fblocks", "-I" });
        cc.addDirectoryArg(b.path("include"));
        cc.addArg("-I");
        cc.addDirectoryArg(b.path("pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers"));
        cc.addArg("-c");
        cc.addFileArg(b.path(b.fmt("src/platform/apple/{s}", .{source})));
        // Header changes also invalidate bridge objects.
        cc.addFileInput(b.path("include/audio_bridge.h"));
        cc.addFileInput(b.path("include/graphics_bridge.h"));
        cc.addFileInput(b.path("include/host_view_bridge.h"));
        cc.addFileInput(b.path("include/network_bridge.h"));
        cc.addFileInput(b.path("include/pasteboard_bridge.h"));
        cc.addFileInput(b.path("include/spice_zig.h"));
        cc.addFileInput(b.path("include/spice_zig_agent.h"));
        cc.addFileInput(b.path("include/spice_zig_audio.h"));
        cc.addFileInput(b.path("include/spice_zig_desktop.h"));
        cc.addFileInput(b.path("include/spice_zig_diagnostics.h"));
        cc.addFileInput(b.path("include/spice_zig_host_view.h"));
        cc.addFileInput(b.path("include/spice_zig_pipeline.h"));
        cc.addFileInput(b.path("include/spice_zig_source.h"));
        cc.addFileInput(b.path("include/spice_zig_usb.h"));
        cc.addFileInput(b.path("include/spice_zig_webdav.h"));
        cc.addFileInput(b.path("include/video_bridge.h"));
        cc.addFileInput(b.path("include/webdav_bridge.h"));
        cc.addArg("-o");
        objects.append(b.allocator, cc.addOutputFileArg(b.fmt("{s}.o", .{source}))) catch @panic("OOM");
    }
    const core = combine(b, "libmaspice-core.a", objects.items);
    const quic_zig = b.addLibrary(.{ .name = "quic-codec", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("pkg/quic/abi.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    }) });
    const qc = b.addSystemCommand(&.{ "xcrun", "clang", "-std=c17", "-O2", "-Wall", "-Wextra", "-Werror", "-arch", "arm64", "-isysroot", sdk, "-mmacosx-version-min=26.0", "-c" });
    qc.addFileArg(b.path("pkg/quic/adapter.c"));
    qc.addFileInput(b.path("pkg/quic/quic.h"));
    qc.addFileInput(b.path("pkg/quic/shim.h"));
    qc.addArg("-o");
    const quic = combine(b, "libmaspice-quic.a", &.{ quic_zig.getEmittedBin(), qc.addOutputFileArg("quic-adapter.o") });
    const all = combine(b, "libmaspice.a", &.{
        core,                                                                                                        quic,
        b.path("pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Versions/A/CTurboJPEG"), b.path("pkg/apple/artifacts/CUSBRedir.xcframework/macos-arm64/CUSBRedir.framework/Versions/A/CUSBRedir"),
    });
    const install = b.addInstallFileWithDir(all, .lib, "libmaspice.a");
    for ([_]struct { LazyPath, []const u8 }{ .{ core, "libmaspice-core.a" }, .{ quic, "libmaspice-quic.a" } }) |pair| {
        install.step.dependOn(&b.addInstallFileWithDir(pair[0], .lib, pair[1]).step);
    }
    install.step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("include"), .install_dir = .header, .install_subdir = "" }).step);
    install.step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("pkg/apple/artifacts/CTurboJPEG.xcframework/Licenses"), .install_dir = .prefix, .install_subdir = "share/libmaspice/licenses/jpeg" }).step);
    install.step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("pkg/apple/artifacts/CUSBRedir.xcframework/Licenses"), .install_dir = .prefix, .install_subdir = "share/libmaspice/licenses/usb" }).step);
    install.step.dependOn(&b.addInstallFileWithDir(b.path("pkg/quic/quic.h"), .header, "maspice/quic.h").step);
    for ([_][]const u8{ "LICENSE", "THIRD_PARTY_NOTICES.md", "pkg/quic/COPYING", "pkg/quic/ZIG-LICENSE" }) |license| {
        install.step.dependOn(&b.addInstallFileWithDir(b.path(license), .prefix, b.fmt("share/libmaspice/licenses/{s}", .{std.fs.path.basename(license)})).step);
    }
    for ([_]struct { []const u8, []const u8 }{ .{ "compositor", "SpiceZigCompositor" }, .{ "presentation", "SpiceZigPresentation" } }) |shader| {
        const metal = b.addSystemCommand(&.{"sh"});
        metal.addFileArg(b.path("bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh"));
        metal.addFileArg(b.path(b.fmt("resources/shaders/{s}.metal", .{shader[0]})));
        _ = metal.addOutputFileArg(b.fmt("{s}.air", .{shader[0]}));
        const output = metal.addOutputFileArg(b.fmt("{s}.metallib", .{shader[1]}));
        install.step.dependOn(&b.addInstallFileWithDir(output, .prefix, b.fmt("share/libmaspice/{s}.metallib", .{shader[1]})).step);
    }
    const pc = b.addWriteFiles();
    const pc_file = pc.add("libmaspice.pc",
        \\prefix=${pcfiledir}/../..
        \\libdir=${prefix}/lib
        \\includedir=${prefix}/include
        \\Name: libmaspice
        \\Description: Native SPICE library with Zig ReleaseSafe core
        \\Version: 0.1.0-dev
        \\Cflags: -I${includedir}
        \\Libs: -L${libdir} -lmaspice
        \\Libs.private: -lz -framework MetalKit -framework IOKit -framework AVFAudio -framework AudioToolbox -framework AppKit -framework Security -framework CoreFoundation -framework Foundation -framework Network -framework QuartzCore -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework IOSurface -framework Metal -framework MetalPerformanceShaders
        \\
    );
    install.step.dependOn(&b.addInstallFileWithDir(pc_file, .lib, "pkgconfig/libmaspice.pc").step);
    return .{ .core = core, .quic = quic, .install = &install.step };
}

fn combine(b: *std.Build, name: []const u8, inputs: []const LazyPath) LazyPath {
    const command = b.addSystemCommand(&.{ "/usr/bin/libtool", "-static", "-D", "-o" });
    command.setEnvironmentVariable("ZERO_AR_DATE", "1");
    const result = command.addOutputFileArg(name);
    for (inputs) |input| command.addFileArg(input);
    return result;
}
