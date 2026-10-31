//! The Zig arm of `just bench-compare` (bench/README.md), and `just bench`:
//! `html.parse` building each corpus document's tree from memory.
//!
//! Usage, from the repository root:
//!
//!     parse-zig [testingx flags]   benchmark rows in the Go benchmark format
//!     parse-zig check              node counts per document, and one parse's allocations
//!
//! A row parses with `std.heap.smp_allocator` and frees the tree inside the
//! timed loop, as the Go and Rust arms do. testingx's own `b.allocator`
//! draws from an arena that never frees, which would hide that cost.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const html = @import("html");
const testingx = @import("testingx");

const corpus = "bench/corpus-gen";
const max_file_size = 64 * 1024 * 1024;
const gpa = std.heap.smp_allocator;

const Doc = struct { name: []const u8, data: []const u8 };

var docs: []const Doc = &.{};
/// The document `parseCurrent` parses. `b.run` runs its function before it
/// returns, so setting this first stands in for a closure.
var current: []const u8 = "";

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and mem.eql(u8, args[1], "check")) {
        try check(init.io, init.arena.allocator());
        return 0;
    }
    return testingx.benchMain(@This(), init);
}

pub fn benchmarkMain(b: *testingx.B) !void {
    docs = try load(b.io, gpa);
    try b.add("Parse", benchmarkParse);
}

fn benchmarkParse(b: *testingx.B) !void {
    for (docs) |doc| {
        current = doc.data;
        _ = try b.run(doc.name, parseCurrent);
    }
}

fn parseCurrent(b: *testingx.B) !void {
    const data = current;
    while (try b.loop()) {
        var doc = try html.parse(gpa, data, .{});
        doc.deinit();
    }
    b.setBytes(@intCast(data.len));
}

/// Every `.html` file in the corpus, sorted by name, which is the row name.
fn load(io: Io, allocator: Allocator) ![]const Doc {
    var dir = Io.Dir.cwd().openDir(io, corpus, .{ .iterate = true }) catch |err| {
        std.debug.print("parse-zig: open {s}: {t} (run `just bench-corpus`)\n", .{ corpus, err });
        return err;
    };
    defer dir.close(io);
    var list: std.ArrayList(Doc) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!mem.endsWith(u8, entry.name, ".html")) continue;
        const data = try dir.readFileAlloc(io, entry.name, allocator, .limited(max_file_size));
        const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".html".len]);
        try list.append(allocator, .{ .name = name, .data = data });
    }
    mem.sort(Doc, list.items, {}, struct {
        fn lessThan(_: void, x: Doc, y: Doc) bool {
            return mem.lessThan(u8, x.name, y.name);
        }
    }.lessThan);
    return list.items;
}

const Counts = struct {
    elements: u64 = 0,
    attributes: u64 = 0,
    texts: u64 = 0,
    text_bytes: u64 = 0,
    comments: u64 = 0,

    fn walk(c: *Counts, doc: *const html.Document, parent: html.Node.Index) void {
        var children = doc.children(parent);
        while (children.next()) |child| {
            switch (doc.node(child).data) {
                .element => |*e| {
                    c.elements += 1;
                    c.attributes += e.attributes.len;
                    if (e.template_contents != .none) c.walk(doc, e.template_contents);
                },
                .text => |t| {
                    c.texts += 1;
                    c.text_bytes += t.items.len;
                },
                .comment => c.comments += 1,
                else => {},
            }
            c.walk(doc, child);
        }
    }
};

fn check(io: Io, arena: Allocator) !void {
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    for (try load(io, arena)) |doc| {
        var counting: testingx.bench.CountingAllocator = .init(gpa);
        var parsed = try html.parse(counting.allocator(), doc.data, .{});
        defer parsed.deinit();
        var c: Counts = .{};
        c.walk(&parsed, .root);
        try out.print("{s} elements={d} attributes={d} texts={d} text_bytes={d} comments={d}", .{
            doc.name, c.elements, c.attributes, c.texts, c.text_bytes, c.comments,
        });
        try out.print("\tallocs={d} bytes={d}\n", .{ counting.allocs(), counting.bytes() });
    }
    try out.flush();
}
