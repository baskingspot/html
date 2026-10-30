//! The web-platform-tests tree construction corpus, run against the public
//! API.
//!
//! `test/wpt-tree-construction/` holds the `.dat` files of WPT's
//! `html/syntax/parsing/resources`, whose format its `README.md` describes.
//! Every case runs in each scripting mode it allows, twice: with the whole
//! input fed at once and fed one byte at a time. Both runs must build the
//! expected tree, which also proves that splitting the input never changes
//! the result. Parse errors are not compared; the parser does not report the
//! tree construction stage's.
//!
//! The tests read the corpus from the build root, so `build.zig` sets the test
//! runner's working directory.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const html = @import("html");
const Document = html.Document;
const Node = html.Node;
const Parser = html.Parser;

const corpus = "test/wpt-tree-construction";
const max_file_size = 16 * 1024 * 1024;
const max_reports = 25;

/// Cases whose expected tree needs more than tree construction. Each must
/// still fail, so the list cannot outlive the problem.
const known_divergences = [_]struct { file: []const u8, data: []const u8, reason: []const u8 }{
    .{
        .file = "webkit02.dat",
        .data = "<select><button><selectedcontent></button><option>X",
        .reason = selectedcontent,
    },
    .{
        .file = "webkit02.dat",
        .data = "<select><button><selectedcontent></button><option>x<i>i<b>ib</i>b",
        .reason = selectedcontent,
    },
    .{
        .file = "webkit02.dat",
        .data = "<select><button><selectedcontent></button><option>X<option>Y",
        .reason = selectedcontent,
    },
    .{
        .file = "webkit02.dat",
        .data = "<select><button><selectedcontent></button><option>X<option selected>Y",
        .reason = selectedcontent,
    },
};

const selectedcontent = "expects the selected option's children cloned into `selectedcontent`, which " ++
    "§4.10 runs when the parser pops an `option` and which needs the DOM's option selectedness";

const Feed = enum { whole, bytewise };

const Stats = struct {
    runs: u32 = 0,
    tree_failures: u32 = 0,
    stream_failures: u32 = 0,
    known: u32 = 0,
    stale: u32 = 0,
    reports: u32 = 0,
};

const Case = struct {
    data: []const u8,
    /// The context element, as the corpus writes it: `td`, `svg path`.
    fragment: ?[]const u8,
    scripting: ?Parser.Scripting,
    expected: []const u8,
};

test "the web-platform-tests tree construction corpus" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stats: Stats = .{};
    for (try datFiles(a)) |file| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ corpus, file });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(max_file_size));
        var cases: Cases = .{ .rest = bytes };
        while (cases.next()) |case| try runCase(a, file, case, &stats);
    }
    std.debug.print(
        "wpt tree construction: {d} runs, {d} tree failures, {d} streaming differences, " ++
            "{d} known divergences, {d} stale divergences\n",
        .{ stats.runs, stats.tree_failures, stats.stream_failures, stats.known, stats.stale },
    );
    try testing.expect(stats.runs > 0);
    if (stats.tree_failures + stats.stream_failures + stats.stale != 0) return error.CorpusMismatch;
}

/// Every `.dat` file in the corpus, sorted so reports come in a stable order.
fn datFiles(a: Allocator) ![]const []const u8 {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, corpus, .{ .iterate = true });
    defer dir.close(io);
    var names: ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (mem.endsWith(u8, entry.name, ".dat")) try names.append(a, try a.dupe(u8, entry.name));
    }
    mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return mem.lessThan(u8, x, y);
}

/// The cases of one `.dat` file. A case starts at a `#data` or
/// `#description` line after a blank line, since a text node in a tree dump
/// can hold blank lines of its own.
const Cases = struct {
    rest: []const u8,

    fn next(self: *Cases) ?Case {
        if (self.rest.len == 0) return null;
        var chunk = self.rest;
        self.rest = "";
        for ([_][]const u8{ "\n\n#data\n", "\n\n#description\n" }) |sep| {
            if (mem.find(u8, chunk, sep)) |i| {
                self.rest = chunk[i + 2 ..];
                chunk = chunk[0..i];
            }
        }
        return parseCase(chunk);
    }
};

fn parseCase(chunk: []const u8) Case {
    const data_start = mem.find(u8, chunk, "#data\n").? + "#data\n".len;
    const after_data = chunk[data_start..];
    const data_len = if (mem.startsWith(u8, after_data, "#errors\n"))
        0
    else
        mem.find(u8, after_data, "\n#errors\n").?;
    const headers_start = data_start + data_len;
    const document = mem.findPos(u8, chunk, headers_start, "\n#document\n").?;

    var case: Case = .{
        .data = after_data[0..data_len],
        .fragment = null,
        .scripting = null,
        .expected = mem.trimEnd(u8, chunk[document + "\n#document\n".len ..], "\n"),
    };
    var lines = mem.splitScalar(u8, chunk[headers_start..document], '\n');
    while (lines.next()) |header| {
        if (mem.eql(u8, header, "#document-fragment")) case.fragment = lines.next().?;
        if (mem.eql(u8, header, "#script-off")) case.scripting = .disabled;
        if (mem.eql(u8, header, "#script-on")) case.scripting = .enabled;
    }
    return case;
}

fn runCase(a: Allocator, file: []const u8, case: Case, stats: *Stats) !void {
    const both = [_]Parser.Scripting{ .enabled, .disabled };
    const modes: []const Parser.Scripting = if (case.scripting) |s| &.{s} else &both;
    for (modes) |scripting| {
        stats.runs += 1;
        const whole = try build(a, case, scripting, .whole);
        const bytewise = try build(a, case, scripting, .bytewise);
        const matches = mem.eql(u8, whole, case.expected);
        if (isKnownDivergence(file, case.data)) {
            if (matches) {
                stats.stale += 1;
                report(stats, file, case, scripting, "stale divergence", whole);
            } else {
                stats.known += 1;
            }
        } else if (!matches) {
            stats.tree_failures += 1;
            report(stats, file, case, scripting, "tree", whole);
        }
        if (!mem.eql(u8, whole, bytewise)) {
            stats.stream_failures += 1;
            report(stats, file, case, scripting, "bytewise", bytewise);
        }
    }
}

fn isKnownDivergence(file: []const u8, data: []const u8) bool {
    for (known_divergences) |known| {
        if (mem.eql(u8, known.file, file) and mem.eql(u8, known.data, data)) return true;
    }
    return false;
}

fn report(
    stats: *Stats,
    file: []const u8,
    case: Case,
    scripting: Parser.Scripting,
    what: []const u8,
    actual: []const u8,
) void {
    stats.reports += 1;
    if (stats.reports > max_reports) return;
    std.debug.print(
        "\n{s}: {s} mismatch, scripting {t}, fragment {?s}\n#data\n{s}\n#expected\n{s}\n#actual\n{s}\n",
        .{ file, what, scripting, case.fragment, case.data, case.expected, actual },
    );
}

/// Parse the case and dump the tree the way the corpus writes it.
fn build(a: Allocator, case: Case, scripting: Parser.Scripting, feed: Feed) ![]const u8 {
    const options: Parser.Options = .{ .scripting = scripting };
    var parser: Parser = if (case.fragment) |context|
        try .initFragment(testing.allocator, parseContext(context), options)
    else
        try .init(testing.allocator, options);
    defer parser.deinit();
    switch (feed) {
        .whole => try parser.feed(case.data),
        .bytewise => for (0..case.data.len) |i| try parser.feed(case.data[i..][0..1]),
    }
    var doc = try parser.finish();
    defer doc.deinit();

    var out: ArrayList(u8) = .empty;
    try dump(a, &doc, .root, 0, &out);
    return mem.trimEnd(u8, out.items, "\n");
}

fn parseContext(context: []const u8) Parser.Context {
    if (mem.startsWith(u8, context, "svg ")) return .init(.svg, context[4..]);
    if (mem.startsWith(u8, context, "math ")) return .init(.mathml, context[5..]);
    return .init(.html, context);
}

fn dump(a: Allocator, doc: *const Document, parent: Node.Index, depth: u32, out: *ArrayList(u8)) !void {
    var it = doc.children(parent);
    while (it.next()) |child| {
        try line(a, out, depth);
        switch (doc.node(child).data) {
            .document, .fragment => unreachable,
            .doctype => |d| {
                try out.print(a, "<!DOCTYPE {s}", .{d.name});
                if (d.public_id.len != 0 or d.system_id.len != 0) {
                    try out.print(a, " \"{s}\" \"{s}\"", .{ d.public_id, d.system_id });
                }
                try out.appendSlice(a, ">\n");
            },
            .element => |*e| {
                try out.print(a, "<{s}{s}>\n", .{ namespacePrefix(e.namespace), e.name });
                try dumpAttributes(a, e, depth + 1, out);
                if (e.template_contents != .none) {
                    try line(a, out, depth + 1);
                    try out.appendSlice(a, "content\n");
                    try dump(a, doc, e.template_contents, depth + 2, out);
                }
                try dump(a, doc, child, depth + 1, out);
            },
            .text => |t| try out.print(a, "\"{s}\"\n", .{t.items}),
            .comment => |c| try out.print(a, "<!-- {s} -->\n", .{c}),
            .processing_instruction => |pi| try out.print(a, "<?{s} {s}?>\n", .{ pi.target, pi.data }),
        }
    }
}

fn line(a: Allocator, out: *ArrayList(u8), depth: u32) !void {
    try out.appendSlice(a, "| ");
    try out.appendNTimes(a, ' ', depth * 2);
}

fn namespacePrefix(namespace: Document.Namespace) []const u8 {
    return switch (namespace) {
        .html => "",
        .svg => "svg ",
        .mathml => "math ",
    };
}

fn dumpAttributes(a: Allocator, e: *const Document.Element, depth: u32, out: *ArrayList(u8)) !void {
    const Named = struct { name: []const u8, value: []const u8 };
    const sorted = try a.alloc(Named, e.attributes.len);
    for (e.attributes, sorted) |attr, *named| {
        const prefix = switch (attr.namespace) {
            .none => "",
            .xlink => "xlink ",
            .xml => "xml ",
            .xmlns => "xmlns ",
        };
        named.* = .{ .name = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, attr.name }), .value = attr.value };
    }
    mem.sort(Named, sorted, {}, struct {
        fn lessThan(_: void, x: Named, y: Named) bool {
            return mem.lessThan(u8, x.name, y.name);
        }
    }.lessThan);
    for (sorted) |named| {
        try line(a, out, depth);
        try out.print(a, "{s}=\"{s}\"\n", .{ named.name, named.value });
    }
}
