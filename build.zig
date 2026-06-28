const std = @import("std");
const rlz = @import("raylib_zig");
// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) !void {
    const preferred_optimize_mode: std.builtin.OptimizeMode = .ReleaseFast;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = preferred_optimize_mode });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib"); // main raylib module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

    const exe_mod = b.createModule(.{
        // b.createModule defines a new module just like b.addModule but,
        // unlike b.addModule, it does not expose the module to consumers of
        // this package, which is why in this case we don't have to give it a name.
        .root_source_file = b.path("src/main.zig"),
        // Target and optimization levels must be explicitly wired in when
        // defining an executable or library (in the root module), and you
        // can also hardcode a specific target for an executable or library
        // definition if desireable (e.g. firmware for embedded devices).
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("raylib", raylib);
    const run_step = b.step("run", "Run the app");
    if (target.query.os_tag == .emscripten) {
        const emsdk = rlz.emsdk;
        const wasm = b.addLibrary(.{
            .name = "tetris",
            .root_module = exe_mod,
        });

        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{ .optimize = optimize });
        const emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize });

        const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .install_dir = install_dir,
            .embed_paths = &.{.{ .src_path = "resources/" }},
        });

        b.getInstallStep().dependOn(emcc_step);

        const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name});
        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, html_filename),
            &.{},
        );

        emrun_step.dependOn(emcc_step);
        run_step.dependOn(emrun_step);
    } else {
        const exe = b.addExecutable(.{
            .name = if (optimize == preferred_optimize_mode) "tetris" else "out",
            .root_module = exe_mod,
        });

        exe.root_module.linkLibrary(raylib_artifact);
        // This declares intent for the executable to be installed into the
        // install prefix when running `zig build` (i.e. when executing the default
        // step). By default the install prefix is `zig-out/` but can be overridden
        // by passing `--prefix` or `-p`.
        b.installArtifact(exe);

        // This creates a top level step. Top level steps have a name and can be
        // invoked by name when running `zig build` (e.g. `zig build run`).
        // This will evaluate the `run` step rather than the default step.
        // For a top level step to actually do something, it must depend on other
        // steps (e.g. a Run step, as we will see in a moment).

        // This creates a RunArtifact step in the build graph. A RunArtifact step
        // invokes an executable compiled by Zig. Steps will only be executed by the
        // runner if invoked directly by the user (in the case of top level steps)
        // or if another step depends on it, so it's up to you to define when and
        // how this Run step will be executed. In our case we want to run it when
        // the user runs `zig build run`, so we create a dependency link.
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        // By making the run step depend on the default step, it will be run from the
        // installation directory rather than directly from within the cache directory.
        run_cmd.step.dependOn(b.getInstallStep());

        // This allows the user to pass arguments to the application in the build
        // command itself, like this: `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }
}
