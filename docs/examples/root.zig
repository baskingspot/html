//! The guide's examples, compiled and run with the module's own test suite.
//! A guide page cannot show code that does not build.

const std = @import("std");
const testing = std.testing;

const html = @import("html");

/// The first element with this name, in document order.
fn find(doc: *const html.Document, parent: html.Node.Index, name: []const u8) ?html.Node.Index {
    var children = doc.children(parent);
    while (children.next()) |child| {
        if (doc.element(child)) |element| {
            if (std.mem.eql(u8, element.name, name)) return child;
        }
        if (find(doc, child, name)) |found| return found;
    }
    return null;
}

test "parse a document" {
    const gpa = testing.allocator;
    var doc = try html.parse(gpa, "<p class=intro>Hello, <b>world</b>", .{});
    defer doc.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    var children = doc.children(.root);
    while (children.next()) |child| {
        switch (doc.node(child).data) {
            .element => |element| try names.append(gpa, element.name),
            else => {},
        }
    }
    try testing.expectEqualSlices([]const u8, &.{"html"}, names.items);
    try testing.expect(find(&doc, .root, "head") != null);
    try testing.expect(find(&doc, .root, "b") != null);
}

test "stream the input" {
    const gpa = testing.allocator;
    var parser: html.Parser = try .init(gpa, .{});
    defer parser.deinit();
    try parser.feed("<ul><li>one<li>t");
    try parser.feed("wo</ul>");
    var doc = try parser.finish();
    defer doc.deinit();

    const ul = find(&doc, .root, "ul").?;
    const first = doc.node(ul).first_child;
    try testing.expect(doc.element(first) != null);
    try testing.expect(doc.node(first).first_child != .none);
}

test "parse a fragment" {
    const gpa = testing.allocator;
    var fragment = try html.parseFragment(gpa, "<td>cell", .{ .name = "tr" }, .{});
    defer fragment.deinit();

    var children = fragment.children(.root);
    const cell = children.next().?;
    try testing.expectEqualStrings("td", fragment.element(cell).?.name);
    try testing.expect(children.next() == null);
}

test "take tokens" {
    const gpa = testing.allocator;
    var tokenizer: html.Tokenizer = .init(gpa, .{ .errors = .collect });
    defer tokenizer.deinit();
    try tokenizer.feed("<p class=intro>Hello");
    tokenizer.finish();

    var tags: u32 = 0;
    var text: u32 = 0;
    while (try tokenizer.next()) |token| {
        switch (token) {
            .start_tag => tags += 1,
            .text => text += 1,
            .eof => break,
            else => {},
        }
    }
    try testing.expectEqual(@as(u32, 1), tags);
    try testing.expectEqual(@as(u32, 1), text);
}

test "scripting decides noscript" {
    const gpa = testing.allocator;

    var markup = try html.parse(gpa, "<noscript><p>x</p></noscript>", .{ .scripting = .disabled });
    defer markup.deinit();
    try testing.expect(find(&markup, .root, "p") != null);

    var raw = try html.parse(gpa, "<noscript><p>x</p></noscript>", .{ .scripting = .enabled });
    defer raw.deinit();
    try testing.expect(find(&raw, .root, "p") == null);
}
