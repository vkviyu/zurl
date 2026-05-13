const std = @import("std");

const release_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_curl = b.dependency("curl", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zurl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("curl", dep_curl.module("curl"));
    exe.root_module.addImport("linenoise", b.dependency("linenoise", .{
        .target = target,
        .optimize = optimize,
    }).module("linenoise"));

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zurl");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("curl", dep_curl.module("curl"));
    unit_tests.root_module.addImport("linenoise", b.dependency("linenoise", .{
        .target = target,
        .optimize = optimize,
    }).module("linenoise"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Release-all step: build all platform binaries at once
    const release_step = b.step("release", "Build release binaries for all platforms");
    for (release_targets) |t| {
        const rel_target = b.resolveTargetQuery(t);
        const rel_optimize: std.builtin.OptimizeMode = .ReleaseFast;

        const rel_dep_curl = b.dependency("curl", .{
            .target = rel_target,
            .optimize = rel_optimize,
        });

        const rel_exe = b.addExecutable(.{
            .name = "zurl",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = rel_target,
                .optimize = rel_optimize,
                .link_libc = true,
            }),
        });
        rel_exe.root_module.addImport("curl", rel_dep_curl.module("curl"));
        rel_exe.root_module.addImport("linenoise", b.dependency("linenoise", .{
            .target = rel_target,
            .optimize = rel_optimize,
        }).module("linenoise"));

        const install = b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{
                .override = .{ .custom = b.fmt("{s}-{s}", .{
                    @tagName(t.cpu_arch.?),
                    @tagName(t.os_tag.?),
                }) },
            },
        });
        release_step.dependOn(&install.step);
    }
}
