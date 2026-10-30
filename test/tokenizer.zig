//! The html5lib-tests tokenizer corpus, run against the public API.
//!
//! `test/html5lib-tests/tokenizer/` holds the `.test` files of
//! github.com/html5lib/html5lib-tests. Every case runs once per initial
//! state, twice: with the whole input fed at once and fed one byte at a time.
//! Both runs must produce the expected tokens and parse errors, which also
//! proves that splitting the input never changes the result.
//!
//! The tests read the corpus from the build root, so `build.zig` sets the test
//! runner's working directory.

const std = @import("std");
const json = std.json;
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = mem.Allocator;
const Writer = std.Io.Writer;

const html = @import("html");
const Tokenizer = html.Tokenizer;

const corpus = "test/html5lib-tests/tokenizer";
const max_file_size = 16 * 1024 * 1024;
const max_reports = 25;

/// Every file but `xmlViolation.test`, whose expectations assume the
/// "coercing an HTML DOM into an infoset" tweaks, which are not tokenizing.
const files = [_][]const u8{
    "contentModelFlags.test",       "domjs.test",         "entities.test",
    "escapeFlag.test",              "namedEntities.test", "numericEntities.test",
    "pendingSpecChanges.test",      "test1.test",         "test2.test",
    "test3.test",                   "test4.test",         "unicodeChars.test",
    "unicodeCharsProblematic.test",
};

/// Cases whose expected parse errors contradict the current standard or the
/// rest of the corpus. Their tokens must still match. Their errors are
/// expected to differ, and an entry whose errors start matching fails the
/// test, so the list cannot outlive the problem.
const known_divergences = [_]struct { file: []const u8, description: []const u8, reason: []const u8 }{
    .{ .file = "domjs.test", .description = "CR in bogus comment state", .reason = unexpected_question_mark },
    .{ .file = "domjs.test", .description = "CRLF in bogus comment state", .reason = unexpected_question_mark },
    .{ .file = "domjs.test", .description = "CRLFLF in bogus comment state", .reason = unexpected_question_mark },
    .{
        .file = "test3.test",
        .description = "<?\\u000B",
        .reason = "puts the tokenizer error before the input stream error at the same position, " ++
            "where `<\\u000B`, `</\\u000B`, and `<!\\u000B` in the same file put it after",
    },
};

const unexpected_question_mark = "expects unexpected-question-mark-instead-of-tag-name, " ++
    "a code the standard dropped when `<?` began opening a processing instruction";

const Feed = enum { whole, bytewise };

const Stats = struct {
    runs: u32 = 0,
    skipped: u32 = 0,
    token_failures: u32 = 0,
    error_failures: u32 = 0,
    stream_failures: u32 = 0,
    known: u32 = 0,
    stale: u32 = 0,
    reports: u32 = 0,
};

/// One run's output in a canonical form: a line per token, in the
/// html5lib-tests JSON shape, and a line per parse error.
const Output = struct {
    tokens: []const []const u8,
    errors: []const []const u8,
};

test "the html5lib-tests tokenizer corpus" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stats: Stats = .{};
    for (files) |file| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ corpus, file });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(max_file_size));
        const root = try json.parseFromSliceLeaky(json.Value, a, bytes, .{});
        for (root.object.get("tests").?.array.items) |case| {
            try runCase(a, file, case.object, &stats);
        }
    }
    std.debug.print(
        "html5lib tokenizer: {d} runs, {d} skipped, {d} token failures, {d} error failures, " ++
            "{d} streaming differences, {d} known divergences, {d} stale divergences\n",
        .{
            stats.runs,            stats.skipped, stats.token_failures, stats.error_failures,
            stats.stream_failures, stats.known,   stats.stale,
        },
    );
    try testing.expect(stats.runs > 0);
    const failures = stats.token_failures + stats.error_failures + stats.stream_failures + stats.stale;
    if (failures != 0) return error.CorpusMismatch;
}

fn runCase(a: Allocator, file: []const u8, case: json.ObjectMap, stats: *Stats) !void {
    const description = case.get("description").?.string;
    const double_escaped = if (case.get("doubleEscaped")) |v| v.bool else false;
    const input = try decodeTestString(a, case.get("input").?.string, double_escaped) orelse {
        stats.skipped += 1; // A lone surrogate cannot be written as UTF-8.
        return;
    };
    const expected = try expectedOutput(a, case, double_escaped);
    const last_start_tag = if (case.get("lastStartTag")) |v| v.string else null;
    const default_states: []const json.Value = &.{.{ .string = "Data state" }};
    const states = if (case.get("initialStates")) |v| v.array.items else default_states;

    for (states) |state_name| {
        const state = textState(state_name.string);
        const name = state_name.string;
        stats.runs += 1;
        const whole = try tokenize(a, input, state, last_start_tag, .whole);
        const bytewise = try tokenize(a, input, state, last_start_tag, .bytewise);
        const errors_match = sameLines(whole.errors, expected.errors);
        if (!sameLines(whole.tokens, expected.tokens)) {
            stats.token_failures += 1;
            report(stats, file, description, name, "tokens", expected.tokens, whole.tokens);
        } else if (isKnownDivergence(file, description)) {
            if (errors_match) {
                stats.stale += 1;
                report(stats, file, description, name, "stale divergence", expected.errors, whole.errors);
            } else {
                stats.known += 1;
            }
        } else if (!errors_match) {
            stats.error_failures += 1;
            report(stats, file, description, name, "errors", expected.errors, whole.errors);
        }
        if (!sameLines(whole.tokens, bytewise.tokens) or !sameLines(whole.errors, bytewise.errors)) {
            stats.stream_failures += 1;
            report(stats, file, description, name, "bytewise", whole.tokens, bytewise.tokens);
        }
    }
}

fn tokenize(
    a: Allocator,
    input: []const u8,
    state: Tokenizer.TextState,
    last_start_tag: ?[]const u8,
    feed: Feed,
) !Output {
    var tokenizer: Tokenizer = .init(testing.allocator, .{ .errors = .collect });
    defer tokenizer.deinit();
    tokenizer.setState(state);
    if (last_start_tag) |name| try tokenizer.setLastStartTag(name);

    var tokens: std.ArrayList([]const u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    switch (feed) {
        .whole => {
            try tokenizer.feed(input);
            tokenizer.finish();
        },
        .bytewise => for (0..input.len) |i| {
            try tokenizer.feed(input[i..][0..1]);
            try drain(a, &tokenizer, &tokens, &text);
        },
    }
    tokenizer.finish();
    try drain(a, &tokenizer, &tokens, &text);

    var errors: std.ArrayList([]const u8) = .empty;
    for (tokenizer.errors.items) |err| {
        const code = try a.dupe(u8, @tagName(err.code));
        mem.replaceScalar(u8, code, '_', '-');
        try errors.append(a, try std.fmt.allocPrint(a, "{s} {d}:{d}", .{ code, err.line, err.column }));
    }
    return .{ .tokens = tokens.items, .errors = errors.items };
}

/// Pull tokens until the tokenizer wants input or reaches the end, writing
/// each in canonical form. Text runs are coalesced, as the corpus expects.
fn drain(
    a: Allocator,
    tokenizer: *Tokenizer,
    tokens: *std.ArrayList([]const u8),
    text: *std.ArrayList(u8),
) !void {
    while (try tokenizer.next()) |token| {
        switch (token) {
            .text => |data| {
                try text.appendSlice(a, data);
                continue;
            },
            .eof => {},
            else => {},
        }
        try flushText(a, tokens, text);
        if (token == .eof) return;
        try tokens.append(a, try canonicalToken(a, token));
    }
}

fn flushText(a: Allocator, tokens: *std.ArrayList([]const u8), text: *std.ArrayList(u8)) !void {
    if (text.items.len == 0) return;
    var out: Writer.Allocating = .init(a);
    try out.writer.writeAll("[\"Character\",");
    try writeString(&out.writer, text.items);
    try out.writer.writeAll("]");
    try tokens.append(a, out.written());
    text.clearRetainingCapacity();
}

fn canonicalToken(a: Allocator, token: html.Token) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    switch (token) {
        .doctype => |d| {
            try w.writeAll("[\"DOCTYPE\",");
            try writeOptional(w, d.name);
            try w.writeAll(",");
            try writeOptional(w, d.public_id);
            try w.writeAll(",");
            try writeOptional(w, d.system_id);
            try w.print(",{}]", .{!d.force_quirks});
        },
        .start_tag => |tag| {
            var names: std.ArrayList([]const u8) = .empty;
            var values: std.ArrayList([]const u8) = .empty;
            for (tag.attributes) |attr| {
                try names.append(a, attr.name);
                try values.append(a, attr.value);
            }
            try writeTag(a, w, tag.name, names.items, values.items, tag.self_closing);
        },
        .end_tag => |tag| {
            try w.writeAll("[\"EndTag\",");
            try writeString(w, tag.name);
            try w.writeAll("]");
        },
        .comment => |data| {
            try w.writeAll("[\"Comment\",");
            try writeString(w, data);
            try w.writeAll("]");
        },
        .processing_instruction => |pi| {
            try w.writeAll("[\"ProcessingInstruction\",");
            try writeString(w, pi.target);
            try w.writeAll(",");
            try writeString(w, pi.data);
            try w.writeAll("]");
        },
        .text, .eof => unreachable,
    }
    return out.written();
}

/// A start tag with its attributes sorted by name, so attribute order in
/// the corpus's JSON objects does not matter.
fn writeTag(
    a: Allocator,
    w: *Writer,
    name: []const u8,
    names: []const []const u8,
    values: []const []const u8,
    self_closing: bool,
) !void {
    const order = try a.alloc(usize, names.len);
    for (order, 0..) |*o, i| o.* = i;
    mem.sort(usize, order, names, struct {
        fn lessThan(keys: []const []const u8, l: usize, r: usize) bool {
            return mem.lessThan(u8, keys[l], keys[r]);
        }
    }.lessThan);
    try w.writeAll("[\"StartTag\",");
    try writeString(w, name);
    try w.writeAll(",{");
    for (order, 0..) |index, i| {
        if (i != 0) try w.writeAll(",");
        try writeString(w, names[index]);
        try w.writeAll(":");
        try writeString(w, values[index]);
    }
    try w.writeAll("}");
    if (self_closing) try w.writeAll(",true");
    try w.writeAll("]");
}

fn writeString(w: *Writer, s: []const u8) !void {
    try json.Stringify.value(s, .{}, w);
}

fn writeOptional(w: *Writer, s: ?[]const u8) !void {
    if (s) |v| try writeString(w, v) else try w.writeAll("null");
}

/// The expected tokens and errors of a case, in the same canonical form.
fn expectedOutput(a: Allocator, case: json.ObjectMap, double_escaped: bool) !Output {
    var tokens: std.ArrayList([]const u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    for (case.get("output").?.array.items) |item| {
        const parts = item.array.items;
        const kind = parts[0].string;
        if (mem.eql(u8, kind, "Character")) {
            const data = (try decodeTestString(a, parts[1].string, double_escaped)).?;
            try text.appendSlice(a, data);
            continue;
        }
        try flushText(a, &tokens, &text);
        try tokens.append(a, try expectedToken(a, kind, parts, double_escaped));
    }
    try flushText(a, &tokens, &text);

    var errors: std.ArrayList([]const u8) = .empty;
    if (case.get("errors")) |list| for (list.array.items) |err| {
        const o = err.object;
        try errors.append(a, try std.fmt.allocPrint(a, "{s} {d}:{d}", .{
            o.get("code").?.string, o.get("line").?.integer, o.get("col").?.integer,
        }));
    };
    return .{ .tokens = tokens.items, .errors = errors.items };
}

fn expectedToken(a: Allocator, kind: []const u8, parts: []const json.Value, double_escaped: bool) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    if (mem.eql(u8, kind, "StartTag")) {
        const attributes = parts[2].object;
        var names: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList([]const u8) = .empty;
        for (attributes.keys(), attributes.values()) |key, value| {
            try names.append(a, (try decodeTestString(a, key, double_escaped)).?);
            try values.append(a, (try decodeTestString(a, value.string, double_escaped)).?);
        }
        const self_closing = parts.len > 3 and parts[3].bool;
        const name = (try decodeTestString(a, parts[1].string, double_escaped)).?;
        try writeTag(a, w, name, names.items, values.items, self_closing);
        return out.written();
    }
    try w.writeAll("[");
    try writeString(w, kind);
    for (parts[1..]) |part| {
        try w.writeAll(",");
        switch (part) {
            .string => |s| try writeString(w, (try decodeTestString(a, s, double_escaped)).?),
            .null => try w.writeAll("null"),
            .bool => |b| try w.print("{}", .{b}),
            else => return error.UnexpectedTokenShape,
        }
    }
    try w.writeAll("]");
    return out.written();
}

/// A corpus string as UTF-8. With `double_escaped`, `\uHHHH` sequences are
/// unescaped first; null means one of them is a lone surrogate.
fn decodeTestString(a: Allocator, s: []const u8, double_escaped: bool) !?[]const u8 {
    if (!double_escaped) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (!mem.startsWith(u8, s[i..], "\\u") or i + 6 > s.len) {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        var cp: u21 = try std.fmt.parseInt(u16, s[i + 2 .. i + 6], 16);
        i += 6;
        if (cp >= 0xD800 and cp <= 0xDBFF and mem.startsWith(u8, s[i..], "\\u") and i + 6 <= s.len) {
            const low = try std.fmt.parseInt(u16, s[i + 2 .. i + 6], 16);
            if (low >= 0xDC00 and low <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                i += 6;
            }
        }
        if (cp >= 0xD800 and cp <= 0xDFFF) return null;
        var buf: [4]u8 = undefined;
        const n = try unicode.utf8Encode(cp, &buf);
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

fn textState(name: []const u8) Tokenizer.TextState {
    const names = [_]struct { []const u8, Tokenizer.TextState }{
        .{ "Data state", .data },
        .{ "PLAINTEXT state", .plaintext },
        .{ "RCDATA state", .rcdata },
        .{ "RAWTEXT state", .rawtext },
        .{ "Script data state", .script_data },
        .{ "CDATA section state", .cdata_section },
    };
    for (names) |entry| if (mem.eql(u8, entry[0], name)) return entry[1];
    std.debug.panic("unknown initial state {s}", .{name});
}

fn isKnownDivergence(file: []const u8, description: []const u8) bool {
    for (known_divergences) |entry| {
        if (mem.eql(u8, entry.file, file) and mem.eql(u8, entry.description, description)) return true;
    }
    return false;
}

fn sameLines(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |l, r| if (!mem.eql(u8, l, r)) return false;
    return true;
}

fn report(
    stats: *Stats,
    file: []const u8,
    description: []const u8,
    state: []const u8,
    what: []const u8,
    expected: []const []const u8,
    actual: []const []const u8,
) void {
    stats.reports += 1;
    if (stats.reports > max_reports) return;
    std.debug.print("\n{s}: {s} [{s}] {s} differ\n  expected:\n", .{ file, description, state, what });
    for (expected) |line| std.debug.print("    {s}\n", .{line});
    std.debug.print("  actual:\n", .{});
    for (actual) |line| std.debug.print("    {s}\n", .{line});
}
