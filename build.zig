const std = @import("std");

// natyv-io/shared: code genuinely needed by more than one natyv-io repo.
// Today that's just `Config` (conf.natyv.json's schema + parser) -- both
// natyv-io/core (the runtime, which loads its own bundled config at
// startup) and natyv-io/cli (which reads config fields like `icon`/
// `compile_targets` at build time) need the exact same schema, and
// duplicating it risks real schema drift the way a hand-kept-in-sync copy
// already needed a dedicated regression test for even a much smaller,
// rarely-touched file (BindingsHostFnUtil.zig) elsewhere in this project.
// Exposed as a plain Zig module, the same `b.dependency(...).module(...)`
// mechanism already used for every other external dependency in the
// natyv-io repos (SDL3, Extism, etc.) -- nothing new to learn, just a
// dependency pointed at this repo instead of a third party's.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config_mod = b.addModule("Config", .{
        .root_source_file = b.path("src/Config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_tests = b.addTest(.{ .root_module = config_mod });
    const run_config_tests = b.addRunArtifact(config_tests);
    const test_step = b.step("test", "Run Config's own unit tests");
    test_step.dependOn(&run_config_tests.step);
}
