const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("html", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    // Every step below needs testingx, which is lazy so a consumer never
    // fetches it. On the first configure pass it is not fetched yet, and the
    // build runner fetches it and reruns this script.
    const testingx = b.lazyDependency("testingx", .{ .target = target }) orelse return;
    const runner: std.Build.Step.Compile.TestRunner = .{
        .path = testingx.path("src/runner.zig"),
        .mode = .simple,
    };
    const test_step = b.step("test", "Run the unit tests and the tokenizer and tree construction corpora");

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    test_step.dependOn(&run_mod_tests.step);

    // The corpus tests read their corpora under `test/` at run time, so the
    // runner's working directory is the build root.
    for ([_][]const u8{ "test/tokenizer.zig", "test/tree.zig" }) |path| {
        const corpus_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "html", .module = mod }},
        });
        const corpus_tests = b.addTest(.{ .root_module = corpus_mod, .test_runner = runner });
        const run_corpus_tests = b.addRunArtifact(corpus_tests);
        run_corpus_tests.setCwd(b.path("."));
        run_corpus_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
        test_step.dependOn(&run_corpus_tests.step);
    }

    // The Zig arm of the parse benchmarks (bench/README.md). It is always
    // ReleaseFast, and it reads `bench/corpus-gen` from the build root.
    const bench_exe = b.addExecutable(.{
        .name = "parse-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/zig/parse.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "html", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                }) },
                .{ .name = "testingx", .module = testingx.module("testingx") },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.setCwd(b.path("."));
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run the parse benchmarks (ReleaseFast); the numbers are not claims")
        .dependOn(&run_bench.step);
    b.step("bench-install", "Install the parse benchmark driver (zig-out/bin/parse-zig)")
        .dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
}
