const std = @import("std");

// natyv-io/shared: a generic toolbox of code genuinely needed by more than
// one natyv-io repo -- not scoped to any one usecase. Exposed as plain Zig
// modules, the same `b.dependency(...).module(...)` mechanism already used
// for every other external dependency in the natyv-io repos (SDL3, Extism,
// etc.) -- nothing new to learn, just a dependency pointed at this repo
// instead of a third party's. Currently holds:
//
// - `Config`: the `conf.natyv.json` schema + parser -- both natyv-io/core
//   (the runtime, which loads its own bundled config at startup) and
//   natyv-io/cli (which reads config fields like `icon`/`compile_targets`
//   at build time) need the exact same schema, and duplicating it risks
//   real schema drift the way a hand-kept-in-sync copy already needed a
//   dedicated regression test for even a much smaller, rarely-touched file
//   (BindingsHostFnUtil.zig) elsewhere in this project.
// - `Parser`/`Expose`/`Codegen`/`Resolver`/`Stylesheet`: the `.ntx`
//   markup transpiler core (moved here 2026-09-01, out of natyv-io/cli),
//   needed by both natyv-io/cli (`natyv prepare`/`natyv build`) and
//   natyv-io/ntx-lsp (which re-runs the same real transpile per LSP
//   request, see `Expose.findComposers` + `Codegen.generateGo`) -- pulling
//   `ntx-lsp` out into its own repo meant this could no longer be `cli`'s
//   own private copy. `Codegen.zig` also carries `PositionMap.zig` as a
//   plain sibling file (a relative `@import`, not a separate named
//   module), same as it always has.
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

    const stylesheet_mod = b.addModule("Stylesheet", .{
        .root_source_file = b.path("src/styling/Stylesheet.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stylesheet_tests = b.addTest(.{ .root_module = stylesheet_mod });
    const run_stylesheet_tests = b.addRunArtifact(stylesheet_tests);

    const resolver_mod = b.addModule("Resolver", .{
        .root_source_file = b.path("src/styling/Resolver.zig"),
        .target = target,
        .optimize = optimize,
    });
    resolver_mod.addImport("Stylesheet", stylesheet_mod);
    const resolver_tests = b.addTest(.{ .root_module = resolver_mod });
    const run_resolver_tests = b.addRunArtifact(resolver_tests);

    const parser_mod = b.addModule("Parser", .{
        .root_source_file = b.path("src/ntx/Parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_tests = b.addTest(.{ .root_module = parser_mod });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    const expose_mod = b.addModule("Expose", .{
        .root_source_file = b.path("src/ntx/Expose.zig"),
        .target = target,
        .optimize = optimize,
    });
    expose_mod.addImport("Parser", parser_mod);
    const expose_tests = b.addTest(.{ .root_module = expose_mod });
    const run_expose_tests = b.addRunArtifact(expose_tests);

    const codegen_mod = b.addModule("Codegen", .{
        .root_source_file = b.path("src/ntx/Codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_mod.addImport("Resolver", resolver_mod);
    codegen_mod.addImport("Expose", expose_mod);
    codegen_mod.addImport("Parser", parser_mod);
    const codegen_tests = b.addTest(.{ .root_module = codegen_mod });
    const run_codegen_tests = b.addRunArtifact(codegen_tests);

    const test_step = b.step("test", "Run every shared module's own unit tests");
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_stylesheet_tests.step);
    test_step.dependOn(&run_resolver_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_expose_tests.step);
    test_step.dependOn(&run_codegen_tests.step);
}
